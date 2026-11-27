import Foundation

/// The one-minute tour's rules (SPEC §3.12). Pure: the coordinator feeds it what the user did and
/// applies what comes back (which sample surface to show, what to remember).
///
/// Rules:
/// - The user drives the pace. Nothing moves on by itself, except the sample break ending by its
///   own timer, which is the real break's behaviour and is on screen while it happens.
/// - The sample nudge moves on only by Start or Not now; the sample break only by ending.
/// - Skip tour works at every step; any real event (a call, a real break, an agent needing you,
///   going away, quitting) ends the tour at once.
/// - It is offered once, when onboarding finishes, and only if it was never offered before
///   (`TourStatus.notOffered`). It never starts or is offered by itself after that, so people
///   who update from a version without it never see it unless they ask (Settings → General).
public enum TourPolicy {
    /// A new tour: from onboarding it starts with the offer; a replay starts at the mark.
    public static func start(_ origin: TourOrigin, now: Date) -> TourState {
        TourState(step: origin == .onboarding ? .offer : .mark, origin: origin, startedAt: now)
    }

    /// What `input` does at the current step.
    public static func apply(_ input: TourInput, to state: TourState) -> TourTransition {
        if case .interrupted(let reason) = input { return .ended(.interrupted(reason)) }
        if input == .skip { return .ended(state.step == .offer ? .declined : .skipped) }
        var next = state
        switch (state.step, input) {
        case (.offer, .next):
            next.step = .mark
        case (.mark, .next):
            next.step = .nudge
        case (.nudge, .accept):
            next.step = .breakScreen
        case (.nudge, .decline):
            next.step = .declined
            next.declines += 1
        case (.declined, .next):
            next.step = .nudge
        case (.breakScreen, .breakEnded):
            next.step = .resumeCard
        case (.resumeCard, .next), (.resumeCard, .cardDismissed):
            next.step = .popover
            next.popoverPart = .status
        case (.popover, .next):
            if let part = TourPopoverPart(rawValue: state.popoverPart.rawValue + 1) {
                next.popoverPart = part
            } else {
                next.step = .farewell
            }
        case (.popover, .popoverClosed):
            next.step = .farewell
        case (.farewell, .next):
            return .ended(.finished)
        default:
            return .ignored
        }
        return .moved(next)
    }

    /// What to remember while a tour is on screen.
    public static func status(during state: TourState) -> TourStatus {
        state.step == .offer ? .offered : .started
    }

    /// What to remember once it ended.
    public static func status(after ending: TourEnding) -> TourStatus {
        switch ending {
        case .declined: return .declined
        case .skipped: return .skipped
        case .finished: return .finished
        case .interrupted: return .interrupted
        }
    }

    /// Finishing onboarding offers the tour only if it was never offered.
    public static func offersAfterOnboarding(_ status: TourStatus) -> Bool {
        status == .notOffered
    }

    /// Declining the offer keeps what finishing onboarding did before the tour existed: the
    /// popover opens once, so the user sees where Breakpoint lives.
    public static func opensPopoverAfter(_ ending: TourEnding, origin: TourOrigin) -> Bool {
        origin == .onboarding && ending == .declined
    }

    /// A tour may start from Settings unless a real break is on screen.
    public static func canReplay(realBreakShowing: Bool) -> Bool { !realBreakShowing }

    // MARK: Sample data

    /// The agent the sample is about: the first connected tool's agent, else Claude.
    public static func sampleAgent(connected: [AgentSource]) -> String {
        (connected.first { $0 != .shell } ?? .claudeCode).displayName
    }

    /// The sample project folder.
    public static let sampleFolder = "my-app"
    /// How long the sample agent had been working when the sample break started.
    public static let sampleRunBeforeBreak: TimeInterval = 4 * 60 + 12
    /// How long the sample run lasts in all ("Claude finished · ran 6 min").
    public static let sampleRunLength: TimeInterval = 6 * 60

    /// The sample agent is still working this far into the sample break.
    public static func sampleAgentWorking(breakElapsed: TimeInterval) -> Bool {
        breakElapsed < Timing.tourAgentFinishesAfter
    }

    /// The working chip's clock this far into the sample break.
    public static func sampleRunElapsed(breakElapsed: TimeInterval) -> TimeInterval {
        sampleRunBeforeBreak + max(0, breakElapsed)
    }

    /// The sample resume card row.
    public static func sampleResume(agent: String) -> ResumeFacts {
        ResumeFacts(name: agent, folder: sampleFolder, outcome: .finished(duration: sampleRunLength),
                    message: TourCopy.sampleAgentMessage, edits: 7, commands: 12)
    }
}
