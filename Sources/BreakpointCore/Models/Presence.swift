import Foundation

/// One reading of the input signals (SPEC §2.4), taken 1 Hz (10 Hz while a nudge or countdown
/// is visible). Produced by Kit's `ActivityMonitor`; consumed by `PresenceTracker`,
/// `ActivityClock`, `OpportunityDetector` and `BreakEngine`. No content, only timings.
public struct InputSample: Codable, Equatable, Hashable, Sendable {
    public var takenAt: Date
    /// Seconds since the last key press (`CGEventSource … .keyDown`).
    public var secondsSinceKey: TimeInterval
    /// Seconds since any input event (`kCGAnyInputEventType`).
    public var secondsSinceAnyInput: TimeInterval
    /// Seconds since the last `.leftMouseDragged` or `.leftMouseDown`.
    public var secondsSinceDrag: TimeInterval
    /// `NSEvent.pressedMouseButtons != 0`.
    public var mouseButtonDown: Bool
    /// Some process holds a `PreventUserIdleDisplaySleep` assertion (count only).
    public var displaySleepPrevented: Bool
    /// Seconds since the last scroll-wheel or trackpad scroll (`.scrollWheel`): reading, which
    /// cancels an eye-rest countdown (SPEC §3.1).
    public var secondsSinceScroll: TimeInterval
    /// Some display is in a mirror set (`CGDisplayIsInMirrorSet`): a projector or TV showing the
    /// same picture.
    public var displayMirrored: Bool

    public init(
        takenAt: Date,
        secondsSinceKey: TimeInterval = 600,
        secondsSinceAnyInput: TimeInterval = 0,
        secondsSinceDrag: TimeInterval = 600,
        mouseButtonDown: Bool = false,
        displaySleepPrevented: Bool = false,
        secondsSinceScroll: TimeInterval = 600,
        displayMirrored: Bool = false
    ) {
        self.takenAt = takenAt
        self.secondsSinceKey = secondsSinceKey
        self.secondsSinceAnyInput = secondsSinceAnyInput
        self.secondsSinceDrag = secondsSinceDrag
        self.mouseButtonDown = mouseButtonDown
        self.displaySleepPrevented = displaySleepPrevented
        self.secondsSinceScroll = secondsSinceScroll
        self.displayMirrored = displayMirrored
    }

    /// A quiet, present sample (input a moment ago, no typing): for previews and placeholders.
    public static func quiet(at date: Date) -> InputSample {
        InputSample(takenAt: date, secondsSinceKey: 30, secondsSinceAnyInput: 1, secondsSinceDrag: 30)
    }

    /// The typing guard (SPEC §2.4): a key < 2 s ago, a button down, or a drag < 1 s ago.
    public var isTyping: Bool { secondsSinceKey < Timing.typingGuardKey }
    public var isPointerBusy: Bool { mouseButtonDown || secondsSinceDrag < Timing.typingGuardDrag }
    public var isBusy: Bool { isTyping || isPointerBusy }
}

/// System presence events (SPEC §2.4), delivered by Kit's `ActivityMonitor`.
public enum PresenceEvent: String, Codable, Sendable, Hashable, CaseIterable {
    case locked
    case unlocked
    case displaysSlept
    case displaysWoke
    case systemWillSleep
    case systemDidWake
    case screensaverStarted
    case screensaverStopped
    case sessionResigned
    case sessionActivated

    /// True for events that start an away period at that moment.
    public var startsAway: Bool {
        switch self {
        case .locked, .displaysSlept, .systemWillSleep, .screensaverStarted, .sessionResigned: return true
        default: return false
        }
    }

    public var awayCause: AwayCause? {
        switch self {
        case .locked: return .locked
        case .displaysSlept: return .displaysAsleep
        case .systemWillSleep: return .systemAsleep
        case .screensaverStarted: return .screensaver
        case .sessionResigned: return .sessionSwitched
        default: return nil
        }
    }
}

/// Why the user is away (SPEC §2.3).
public enum AwayCause: String, Codable, Sendable, Hashable {
    /// No input for ≥ the away threshold (and no call or display-sleep assertion).
    case idle
    case locked
    case displaysAsleep
    case systemAsleep
    case screensaver
    case sessionSwitched
}

/// Present or away (SPEC §2.3).
public enum PresenceStatus: Codable, Equatable, Hashable, Sendable {
    case present
    /// Away since `since` (the last input for idle; the lock/sleep moment otherwise).
    case away(since: Date, cause: AwayCause)

    public var isAway: Bool {
        if case .away = self { return true }
        return false
    }
}

/// A finished away period (SPEC §2.3). Input to `AwayPolicy`.
public struct AwayPeriod: Codable, Equatable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var cause: AwayCause

    public init(start: Date, end: Date, cause: AwayCause) {
        self.start = start
        self.end = end
        self.cause = cause
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}
