import Foundation

/// Everything `BreakEngine.decide` and `OpportunityDetector` may look at, captured by the
/// coordinator for each decision (SPEC §2.5, §7.1). A plain value: the engine is a pure function of
/// a snapshot, an opportunity and a clock.
public struct EngineSnapshot: Equatable, Sendable {
    public var settings: Settings
    public var timers: TimerState
    public var presence: PresenceStatus
    public var input: InputSample
    public var pause: PauseState
    /// A break overlay, nudge or countdown chip is showing (step 1).
    public var surfaceVisible: Bool
    /// When the previous nudge appeared (nudge spacing).
    public var lastNudgeAt: Date?
    /// When the previous break ended (nudge spacing).
    public var lastBreakEndedAt: Date?
    /// Kind spacing: a kind is not offered before its date (10 min after a decline or ignore, or
    /// a whole cadence from the third refusal in a row: `BreakEngine.spacingAfterRefusal`).
    public var kindSpacedUntil: [BreakKind: Date]
    /// Still-time slot offers (`move`, `walk`, `breathe`) declined or ignored in a row (resets
    /// when a stretch, walk or breather is taken, or away time resets still time).
    /// At 2, `breathe` is offered instead of `move`.
    public var consecutiveMoveRefusals: Int
    /// After a breather the person started: the still-time slot (`move`, `walk`, `breathe`) is
    /// not offered before this date, one move cadence after the breather ended (SPEC §2.3). Still
    /// time keeps running; eye rests are not held.
    public var stretchHeldUntil: Date?
    public var sessions: [AgentSession]
    public var commands: [RunningCommand]
    /// Expected run length per source (median of recent runs, default 90 s).
    public var expectedRunLengths: [AgentSource: TimeInterval]
    /// A microphone is on (and "Pause during calls" is on) but not yet for long enough to count as
    /// a call (`MicrophoneCallGate`): opportunities are held while it lasts (SPEC §2.4).
    public var microphonePending: Bool

    public init(
        settings: Settings = .defaults,
        timers: TimerState = .zero,
        presence: PresenceStatus = .present,
        input: InputSample,
        pause: PauseState = .none,
        surfaceVisible: Bool = false,
        lastNudgeAt: Date? = nil,
        lastBreakEndedAt: Date? = nil,
        kindSpacedUntil: [BreakKind: Date] = [:],
        consecutiveMoveRefusals: Int = 0,
        stretchHeldUntil: Date? = nil,
        sessions: [AgentSession] = [],
        commands: [RunningCommand] = [],
        expectedRunLengths: [AgentSource: TimeInterval] = [:],
        microphonePending: Bool = false
    ) {
        self.settings = settings
        self.timers = timers
        self.presence = presence
        self.input = input
        self.pause = pause
        self.surfaceVisible = surfaceVisible
        self.lastNudgeAt = lastNudgeAt
        self.lastBreakEndedAt = lastBreakEndedAt
        self.kindSpacedUntil = kindSpacedUntil
        self.consecutiveMoveRefusals = consecutiveMoveRefusals
        self.stretchHeldUntil = stretchHeldUntil
        self.sessions = sessions
        self.commands = commands
        self.expectedRunLengths = expectedRunLengths
        self.microphonePending = microphonePending
    }

    /// Expected run length for `source`, defaulting to `Timing.defaultExpectedRun`.
    public func expectedRunLength(for source: AgentSource?) -> TimeInterval {
        source.flatMap { expectedRunLengths[$0] } ?? Timing.defaultExpectedRun
    }

    /// The session with `key`, if tracked.
    public func session(_ key: SessionKey?) -> AgentSession? {
        guard let key else { return nil }
        return sessions.first { $0.key == key }
    }
}
