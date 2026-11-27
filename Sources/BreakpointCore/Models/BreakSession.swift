import Foundation

/// A break in progress (overlay showing), as the coordinator tracks it. Pure data; the rules that
/// act on it (Done threshold, extensions, ceiling, outcome) live in `BreakSessionRules` (Engine/).
public struct BreakSession: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: BreakKind
    public var startedAt: Date
    /// Planned length before extensions (walk: the walk target).
    public var plannedLength: TimeInterval
    /// "1 more minute" presses so far (≤ `Timing.maxExtensions`).
    public var extensionsUsed: Int
    /// The routine being played (`move` only; includes the steps "1 more minute" replays).
    public var routine: Routine?
    /// Current step index (`move` only). Advanced by time or by ← / →.
    public var stepIndex: Int
    /// When the current step started (steps can be changed by hand, so this is not derived).
    public var stepStartedAt: Date
    /// The rotating copy chosen for this break.
    public var copy: BreakCopy.Variant
    /// A second line under the instruction (`walk`: an idea for the walk), or nil.
    public var detail: String?
    /// What led to the break (`manual` for Take a break).
    public var opportunity: Opportunity?
    /// An agent needed the user during the break (SPEC §3.3).
    public var needsYou: Bool
    /// Sessions that finished or needed the user during the break: they get the resume card.
    public var sessionsToResume: [SessionKey]
    /// A Settings preview: records nothing, ends after 5 s or Esc.
    public var isPreview: Bool
    /// AirPods movement check result so far.
    public var movementDetected: Bool

    public init(
        id: UUID = UUID(),
        kind: BreakKind,
        startedAt: Date,
        plannedLength: TimeInterval,
        extensionsUsed: Int = 0,
        routine: Routine? = nil,
        stepIndex: Int = 0,
        stepStartedAt: Date? = nil,
        copy: BreakCopy.Variant,
        detail: String? = nil,
        opportunity: Opportunity? = nil,
        needsYou: Bool = false,
        sessionsToResume: [SessionKey] = [],
        isPreview: Bool = false,
        movementDetected: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.plannedLength = plannedLength
        self.extensionsUsed = extensionsUsed
        self.routine = routine
        self.stepIndex = stepIndex
        self.stepStartedAt = stepStartedAt ?? startedAt
        self.copy = copy
        self.detail = detail
        self.opportunity = opportunity
        self.needsYou = needsYou
        self.sessionsToResume = sessionsToResume
        self.isPreview = isPreview
        self.movementDetected = movementDetected
    }

    /// Planned length including extensions.
    public var totalLength: TimeInterval {
        plannedLength + TimeInterval(extensionsUsed) * Timing.extensionLength
    }

    public func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(startedAt)) }

    /// Seconds left (0 when over). For `walk`, time left to the target.
    public func remaining(at now: Date) -> TimeInterval { max(0, totalLength - elapsed(at: now)) }

    /// Fraction of the total length elapsed, 0…1.
    public func progress(at now: Date) -> Double {
        totalLength > 0 ? min(1, elapsed(at: now) / totalLength) : 1
    }

    /// The step currently playing (`move` only).
    public var currentStep: RoutineStep? {
        guard let routine, routine.steps.indices.contains(stepIndex) else { return nil }
        return routine.steps[stepIndex]
    }
}

/// Wind-down state for one night (SPEC §2.8). Reset at 05:00.
public struct WindDownState: Codable, Equatable, Hashable, Sendable {
    /// Start of the Breakpoint day this state belongs to.
    public var dayStart: Date
    /// "15 more minutes" choices so far tonight (selects the 3 / 6 / 10 s hold).
    public var extensionsTonight: Int
    /// The card is not shown again before this time.
    public var snoozedUntil: Date?
    /// The user chose Wrap up tonight.
    public var wrappedUp: Bool
    /// The card is showing.
    public var cardVisible: Bool

    public init(dayStart: Date, extensionsTonight: Int = 0, snoozedUntil: Date? = nil,
                wrappedUp: Bool = false, cardVisible: Bool = false) {
        self.dayStart = dayStart
        self.extensionsTonight = extensionsTonight
        self.snoozedUntil = snoozedUntil
        self.wrappedUp = wrappedUp
        self.cardVisible = cardVisible
    }
}
