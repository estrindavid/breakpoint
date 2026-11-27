import Foundation

/// Pause reasons and resume cool-downs (SPEC §2.4). Pure: every function maps a `PauseState` and
/// facts to a new `PauseState`.
///
/// Contract:
/// - `update`: drops `manual` / `windDownWrappedUp` reasons whose `until` has passed; adds, updates
///   or removes the `call` reason from `callSignals.filtered(by: settings)` (not while
///   `ignoringCurrentCall`; that flag resets once all call signals stop). Whenever the last reason
///   ends, sets `cooldownUntil = now + Timing.resumeCooldown`.
/// - `pause`: adds `.manual(until: duration.end(from: now))`, replacing an earlier manual reason.
/// - `wrapUp`: adds `.windDownWrappedUp(until: next 05:00)`.
/// - `resumeNow`: removes manual and wrap-up reasons; if a call reason is active, removes it and
///   sets `ignoringCurrentCall`. Starts the cool-down.
/// - `startCooldown`: after returning from away, unlock or wake: `cooldownUntil = now + 60 s`
///   (never shortens an existing later cool-down).
///
/// Reasons are kept in a stable order (call, wrap-up, manual) so equal states compare equal.
public enum PausePolicy {
    public static func update(_ state: PauseState, callSignals: CallSignals, settings: Settings, now: Date) -> PauseState {
        var next = state
        next.reasons.removeAll { reason in reason.until.map { now >= $0 } ?? false }

        let signals = callSignals.filtered(by: settings)
        if next.ignoringCurrentCall, signals.isEmpty {
            next.ignoringCurrentCall = false
        }
        next.reasons.removeAll { if case .call = $0 { return true } else { return false } }
        if !signals.isEmpty, !next.ignoringCurrentCall {
            next.reasons.append(.call(signals))
        }
        return finishing(state, next, now: now)
    }

    public static func pause(_ state: PauseState, for duration: PauseDuration, now: Date, calendar: Calendar = .current) -> PauseState {
        var next = state
        next.reasons.removeAll { if case .manual = $0 { return true } else { return false } }
        next.reasons.append(.manual(until: duration.end(from: now, calendar: calendar)))
        return finishing(state, next, now: now)
    }

    public static func wrapUp(_ state: PauseState, now: Date, calendar: Calendar = .current) -> PauseState {
        var next = state
        next.reasons.removeAll { if case .windDownWrappedUp = $0 { return true } else { return false } }
        next.reasons.append(.windDownWrappedUp(until: BreakpointDay.nextBoundary(after: now, calendar: calendar)))
        return finishing(state, next, now: now)
    }

    public static func resumeNow(_ state: PauseState, now: Date) -> PauseState {
        var next = state
        if next.callSignals != nil { next.ignoringCurrentCall = true }
        next.reasons = []
        return finishing(state, next, now: now)
    }

    public static func startCooldown(_ state: PauseState, now: Date) -> PauseState {
        var next = state
        next.cooldownUntil = laterCooldown(state.cooldownUntil, now: now)
        return next
    }

    /// Orders the reasons and starts the cool-down when the last reason ended.
    private static func finishing(_ before: PauseState, _ after: PauseState, now: Date) -> PauseState {
        var next = after
        next.reasons.sort { $0.displayPriority > $1.displayPriority }
        if before.isPaused, !next.isPaused {
            next.cooldownUntil = laterCooldown(next.cooldownUntil, now: now)
        }
        return next
    }

    private static func laterCooldown(_ existing: Date?, now: Date) -> Date {
        let candidate = now.addingTimeInterval(Timing.resumeCooldown)
        guard let existing else { return candidate }
        return max(existing, candidate)
    }
}
