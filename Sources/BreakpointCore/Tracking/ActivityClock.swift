import Foundation

/// Advances the two counters of `TimerState` (SPEC §2.3). Pure.
///
/// Contract:
/// - `advance`: while `presence` is `.present`, add `dt` to both screen time and still time;
///   while away, add nothing. (Pauses do not stop accrual; the coordinator handles away-time
///   removal through `PresenceTracker`'s retroactive away start.)
/// - `afterBreak`: a break the person started counts however briefly it ran and however it ended
///   (`completed` or `endedEarly`; a started break is never `skipped`): it is just less time. A
///   `move` or `walk` resets both counters, so still time ("since you moved") counts from the end
///   of the stretch or walk and the time it was on screen never counts as sitting still; `eyes`
///   resets screen time. `breathe` resets nothing: it is done sitting down, so it is not moving
///   (the coordinator holds off the next stretch instead, SPEC §2.3). `credited` is handled by
///   `AwayPolicy`. Other outcomes (`declined`, `ignored`, and `skipped` from older history)
///   change nothing.
/// - `removingAccrual`: subtracts time accrued between the last input and away detection
///   (never below zero).
public enum ActivityClock {
    public static func advance(_ timers: TimerState, sample: InputSample, presence: PresenceStatus, dt: TimeInterval) -> TimerState {
        guard !presence.isAway, dt.isFinite, dt > 0 else { return timers }
        return timers.adding(dt)
    }

    public static func afterBreak(_ timers: TimerState, kind: BreakKind, outcome: BreakOutcome) -> TimerState {
        guard outcome == .completed || outcome == .endedEarly else { return timers }
        switch kind {
        case .move, .walk: return .zero
        case .eyes: return TimerState(screenTime: 0, stillTime: timers.stillTime)
        case .breathe: return timers
        }
    }

    public static func removingAccrual(_ timers: TimerState, seconds: TimeInterval) -> TimerState {
        TimerState(screenTime: max(0, timers.screenTime - seconds), stillTime: max(0, timers.stillTime - seconds))
    }
}

/// What `PresenceTracker` reports.
public enum PresenceChange: Equatable, Sendable {
    /// The user became away; `since` may be in the past (idle away starts at the last input).
    /// `retroactiveSeconds` is the time accrued since then, to remove from the timers.
    case becameAway(since: Date, cause: AwayCause, retroactiveSeconds: TimeInterval)
    /// The user is back; the finished period goes to `AwayPolicy`.
    case returned(AwayPeriod)
}

/// Turns input samples and presence events into present/away periods (SPEC §2.3). A value type
/// with no I/O.
///
/// Contract:
/// - Idle away: `sample.secondsSinceAnyInput ≥ settings.awayThreshold`, unless `callActive` or
///   `sample.displaySleepPrevented` (then idle never makes the user away). Away starts at the
///   last input (`takenAt − secondsSinceAnyInput`), but never before the end of the previous
///   away period, so periods never overlap and no time is removed twice.
/// - Event away: `PresenceEvent.startsAway` starts away at the event time (if not already away).
///   Each event cause is held until its counterpart arrives: `locked` until `unlocked` (or
///   `sessionActivated`), `displaysSlept` until `displaysWoke`, `systemWillSleep` until
///   `systemDidWake`, `screensaverStarted` until `screensaverStopped`, `sessionResigned` until
///   `sessionActivated`. Display sleep, system sleep and the screensaver are also cleared by input
///   that arrives after them (input wakes the displays and stops the screensaver); a lock is not,
///   because typing the password at the lock screen is input too.
/// - Away ends when no event cause is held and either the event that cleared the last cause
///   arrived (period end = the event time) or, for idle, input arrived after the away start
///   (period end = that input). Emits `.returned(period)`.
/// - `status` reflects the current state.
public struct PresenceTracker: Equatable, Sendable {
    public private(set) var status: PresenceStatus
    /// Event causes holding the user away, with when each began.
    public private(set) var heldCauses: [AwayCause: Date]
    /// When the user last returned (bounds the retroactive start of the next idle period).
    public private(set) var presentSince: Date?

    /// Sampling jitter tolerance when comparing input times derived from "seconds since".
    static let inputTolerance: TimeInterval = 0.5

    public init(status: PresenceStatus = .present) {
        self.status = status
        self.heldCauses = [:]
        self.presentSince = nil
    }

    public mutating func ingest(_ sample: InputSample, callActive: Bool, settings: Settings) -> [PresenceChange] {
        let now = sample.takenAt
        let idle = max(0, sample.secondsSinceAnyInput)
        let lastInput = now.addingTimeInterval(-idle)

        switch status {
        case .present:
            guard !callActive, !sample.displaySleepPrevented, idle >= settings.awayThreshold else { return [] }
            let since = max(lastInput, presentSince ?? .distantPast)
            status = .away(since: since, cause: .idle)
            return [.becameAway(since: since, cause: .idle, retroactiveSeconds: max(0, now.timeIntervalSince(since)))]

        case .away(let since, let cause):
            // Input wakes the displays and stops the screensaver; any sample means the system runs.
            for (held, start) in heldCauses where held.clearedByInput && lastInput > start.addingTimeInterval(Self.inputTolerance) {
                heldCauses[held] = nil
            }
            guard heldCauses.isEmpty else { return [] }
            guard lastInput > since.addingTimeInterval(Self.inputTolerance) else { return [] }
            return [returned(since: since, cause: cause, at: min(lastInput, now))]
        }
    }

    public mutating func ingest(_ event: PresenceEvent, at now: Date) -> [PresenceChange] {
        if event.startsAway, let cause = event.awayCause {
            if heldCauses[cause] == nil { heldCauses[cause] = now }
            guard case .present = status else { return [] }
            status = .away(since: now, cause: cause)
            return [.becameAway(since: now, cause: cause, retroactiveSeconds: 0)]
        }
        var cleared = false
        for cause in event.clearedCauses where heldCauses[cause] != nil {
            heldCauses[cause] = nil
            cleared = true
        }
        guard cleared, heldCauses.isEmpty, case .away(let since, let cause) = status else { return [] }
        return [returned(since: since, cause: cause, at: now)]
    }

    private mutating func returned(since: Date, cause: AwayCause, at end: Date) -> PresenceChange {
        status = .present
        heldCauses = [:]
        presentSince = max(end, since)
        return .returned(AwayPeriod(start: since, end: max(end, since), cause: cause))
    }
}

extension AwayCause {
    /// Causes that input after their start ends (input wakes displays, stops the screensaver,
    /// and proves the system is awake). Locks and session switches need their own event.
    var clearedByInput: Bool {
        switch self {
        case .displaysAsleep, .systemAsleep, .screensaver: return true
        case .idle, .locked, .sessionSwitched: return false
        }
    }
}

extension PresenceEvent {
    /// The away causes this event ends.
    var clearedCauses: [AwayCause] {
        switch self {
        case .unlocked: return [.locked]
        case .displaysWoke: return [.displaysAsleep]
        case .systemDidWake: return [.systemAsleep]
        case .screensaverStopped: return [.screensaver]
        // Returning to the session needs authentication, so it also ends a lock.
        case .sessionActivated: return [.sessionSwitched, .locked]
        case .locked, .displaysSlept, .systemWillSleep, .screensaverStarted, .sessionResigned: return []
        }
    }
}
