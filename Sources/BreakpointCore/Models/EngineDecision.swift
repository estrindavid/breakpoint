import Foundation

/// A break the engine decided to offer (SPEC §2.5): what, how long, why now.
public struct BreakOffer: Codable, Equatable, Hashable, Sendable {
    public var kind: BreakKind
    /// Planned length in seconds (walk: the walk target).
    public var length: TimeInterval
    public var opportunity: Opportunity
    /// How far past its cadence the triggering timer is (0 when just due). Drives
    /// "18 min overdue".
    public var overdueBy: TimeInterval
    /// The relevant timer's value: screen time for `eyes`, still time otherwise. Drives
    /// "52 min at the screen".
    public var timerValue: TimeInterval
    /// The opportunity's agent's usual run length (median), when the opportunity came from an
    /// agent. Drives "Claude usually takes 4 min".
    public var expectedRunLength: TimeInterval?

    public init(
        kind: BreakKind,
        length: TimeInterval,
        opportunity: Opportunity,
        overdueBy: TimeInterval = 0,
        timerValue: TimeInterval = 0,
        expectedRunLength: TimeInterval? = nil
    ) {
        self.kind = kind
        self.length = length
        self.opportunity = opportunity
        self.overdueBy = overdueBy
        self.timerValue = timerValue
        self.expectedRunLength = expectedRunLength
    }
}

/// Why an opportunity is held (kept and re-evaluated every tick until it expires) (SPEC §2.4).
public enum HoldReason: String, Codable, Sendable, Hashable {
    /// A key was pressed < 2 s ago.
    case typing
    /// A mouse button is down, or a drag happened < 1 s ago.
    case pointer
    /// A microphone is on but not (yet) for long enough to count as a call: dictation, or the
    /// first minute of a call (`MicrophoneCallGate`, SPEC §2.4).
    case microphone
}

/// Why an opportunity is dropped (SPEC §2.5, steps 1–5).
public enum SuppressReason: Codable, Equatable, Hashable, Sendable {
    /// A break overlay, nudge or countdown is showing.
    case surfaceVisible
    case paused(PauseReason)
    case away
    /// Resume cool-down (60 s after a pause ends, return from away, unlock or wake).
    case cooldown(until: Date)
    /// Nudge spacing (10 min after the previous nudge or the end of any break).
    case spacing(until: Date)
    /// Strict mode is on and the opportunity is `typingPause`.
    case strictMode
    /// A display is mirrored or kept awake and the opportunity is `typingPause` (SPEC §2.4).
    case presenting(PresentingCause)
}

/// The result of `BreakEngine.decide` (SPEC §2.5).
public enum EngineDecision: Codable, Equatable, Hashable, Sendable {
    case offer(BreakOffer)
    case hold(HoldReason)
    case suppress(SuppressReason)
    case nothing

    public var offer: BreakOffer? {
        if case .offer(let offer) = self { return offer }
        return nil
    }
}
