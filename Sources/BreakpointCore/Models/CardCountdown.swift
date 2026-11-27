import Foundation

/// How long a self-dismissing pop-up has left (SPEC §3.0 Auto-hide), as a value.
///
/// It runs from its full time when the card appears, is **held** while the pointer is over the
/// card, and **resumes** when the pointer leaves with what it had left, topped up to at least
/// `Timing.cardHoverResumeFloor` of its full time. The card's surface fires its timeout at
/// `deadline` and its time rim (§3.5) draws `fraction(at:)`, so what the card shows and when it
/// goes are the same number.
public struct CardCountdown: Equatable, Sendable {
    /// The card's whole time (`CardState.autoHideAfter`).
    public let full: TimeInterval
    /// Time left at `runningSince` (running) or while held.
    public private(set) var remaining: TimeInterval
    /// When it last started running; `nil` while held.
    public private(set) var runningSince: Date?

    /// A countdown of `full` seconds, running from `start`.
    public init(full: TimeInterval, start: Date) {
        self.full = max(0, full)
        remaining = max(0, full)
        runningSince = start
    }

    /// A countdown with `remaining` of `full` left, running from `since`, or held (`nil`).
    public init(full: TimeInterval, remaining: TimeInterval, runningSince since: Date?) {
        self.full = max(0, full)
        self.remaining = min(max(0, remaining), max(0, full))
        runningSince = since
    }

    public var isHeld: Bool { runningSince == nil }

    /// When it reaches zero; `nil` while held.
    public var deadline: Date? { runningSince?.addingTimeInterval(remaining) }

    /// Seconds left at `date` (never below zero; unchanged while held).
    public func remaining(at date: Date) -> TimeInterval {
        guard let since = runningSince else { return remaining }
        return max(0, remaining - max(0, date.timeIntervalSince(since)))
    }

    /// Time left as a fraction of the full time, 1 → 0.
    public func fraction(at date: Date) -> Double {
        guard full > 0 else { return 0 }
        return min(1, max(0, remaining(at: date) / full))
    }

    public func isExpired(at date: Date) -> Bool { remaining(at: date) <= 0 }

    /// Held at `date` (the pointer is over the card). Holding a held countdown changes nothing.
    public func held(at date: Date) -> CardCountdown {
        guard !isHeld else { return self }
        return CardCountdown(full: full, remaining: remaining(at: date), runningSince: nil)
    }

    /// Running again from `date` (the pointer left), with at least the resume floor left.
    /// Resuming a running countdown changes nothing.
    public func resumed(at date: Date) -> CardCountdown {
        guard isHeld else { return self }
        let floor = full * Timing.cardHoverResumeFloor
        return CardCountdown(full: full, remaining: max(remaining, floor), runningSince: date)
    }
}
