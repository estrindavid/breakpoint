import Foundation

/// The outcome of resolving an away period (SPEC §2.3).
public struct AwayResolution: Equatable, Sendable {
    /// Timers after the reset (unchanged if nothing was reset).
    public var timers: TimerState
    /// Set when any timer was reset; holds the previous timers for Undo.
    public var decision: AutoDecision?
    /// `credited` entries to append to history (their ids are in `decision.historyEntryIDs`).
    public var creditedEntries: [HistoryEntry]

    public init(timers: TimerState, decision: AutoDecision? = nil, creditedEntries: [HistoryEntry] = []) {
        self.timers = timers
        self.decision = decision
        self.creditedEntries = creditedEntries
    }

    /// Show the away note (only when a due break was credited).
    public var showsAwayNote: Bool { !creditedEntries.isEmpty }
}

/// Natural breaks (SPEC §2.3). Pure. Never asks a question: it decides, says so in one sentence,
/// and offers Undo.
///
/// Contract for `resolve` (away period of duration D):
/// - For `eyes` (20 s) and `move` (120 s): if D ≥ that break's length, reset its timer (screen time
///   for eyes, still time for move); if that timer was ≥ its cadence, create a `credited`
///   `HistoryEntry` (start = period.start, duration = D).
/// - If any timer was reset, return an `AutoDecision` with `previous` = the input timers, kind
///   `.creditedAway(kinds, D)` when something was credited else `.timersReset(D)`, the sentence
///   from `Copy`, `historyEntryIDs` = the credited entries' ids.
/// - A reset of a timer that is already zero changes nothing, so it makes no decision (nothing to
///   explain or undo).
/// - Otherwise return the timers unchanged and no decision.
///
/// Contract for `undo`: previous timers + D on both counters (as if present). The caller deletes
/// the history entries and shows the "Timers restored" toast. `undo(_:current:)` also keeps the
/// time accrued since the decision.
public enum AwayPolicy {
    /// The breaks an away period can stand in for, with the timer each one resets.
    static let creditableKinds: [BreakKind] = [.eyes, .move]

    public static func resolve(_ period: AwayPeriod, timers: TimerState, settings: Settings, now: Date) -> AwayResolution {
        let duration = period.duration
        let cadence = settings.cadence
        var after = timers
        var credited: [HistoryEntry] = []
        var changed = false

        for kind in creditableKinds where duration >= kind.defaultLength {
            let value = timers.value(for: kind)
            guard value > 0 else { continue }
            changed = true
            if kind == .eyes { after.screenTime = 0 } else { after.stillTime = 0 }
            if value >= cadence.interval(for: kind) {
                credited.append(HistoryEntry(kind: kind, outcome: .credited, opportunityKind: nil, source: nil,
                                             start: period.start, duration: duration))
            }
        }

        guard changed else { return AwayResolution(timers: timers) }
        let kinds = credited.map(\.kind)
        let decision = AutoDecision(
            kind: kinds.isEmpty ? .timersReset(duration: duration) : .creditedAway(kinds, duration: duration),
            madeAt: now,
            sentence: kinds.isEmpty ? Copy.timersReset(duration: duration) : Copy.creditedAway(duration: duration),
            previous: timers,
            historyEntryIDs: credited.map(\.id))
        return AwayResolution(timers: after, decision: decision, creditedEntries: credited)
    }

    /// The timers as if the user had been present: the previous timers plus the away time.
    public static func undo(_ decision: AutoDecision) -> TimerState {
        decision.previous.adding(decision.kind.awayDuration)
    }

    /// Like `undo(_:)`, but keeps what accrued between the decision and now: each counter the
    /// decision reset gets back its previous value plus the away time on top of its current value;
    /// a counter it did not reset just gains the away time.
    public static func undo(_ decision: AutoDecision, current: TimerState) -> TimerState {
        let duration = decision.kind.awayDuration
        func restored(_ kind: BreakKind) -> TimeInterval {
            let now = current.value(for: kind)
            let wasReset = duration >= (kind == .eyes ? BreakKind.eyes.defaultLength : BreakKind.move.defaultLength)
            return (wasReset ? decision.previous.value(for: kind) : 0) + now + duration
        }
        return TimerState(screenTime: restored(.eyes), stillTime: restored(.move))
    }
}
