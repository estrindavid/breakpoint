import Foundation

// The one-minute tour (SPEC §3.12): a rehearsal of one whole cycle with sample data, on the real
// surfaces in their real places. Pure data; the rules live in `TourPolicy` (Engine/), the words in
// `TourCopy` (Routines/).

/// Where the tour is. The order is the order of the cycle it rehearses.
public enum TourStep: String, Codable, Sendable, CaseIterable {
    /// "Take the one-minute tour?" under the menu-bar mark (after onboarding only).
    case offer
    /// The menu-bar mark: what it is, what its states mean.
    case mark
    /// A real nudge card in its real place, with sample data: Start or Not now.
    case nudge
    /// After Not now: what that did, and the offer to try again.
    case declined
    /// A short sample break on the real break screen, started by the user's own Start.
    case breakScreen
    /// The resume card that follows the sample break.
    case resumeCard
    /// The popover, opened for the user, its parts named one by one.
    case popover
    /// Where Settings and the tour live, and when the first real break comes.
    case farewell

    /// The step's place in the progress dots (1-based); `nil` for the offer, which is not a step
    /// of the tour yet. Not now shares the nudge's place.
    public var progressIndex: Int? {
        switch self {
        case .offer: return nil
        case .mark: return 1
        case .nudge, .declined: return 2
        case .breakScreen: return 3
        case .resumeCard: return 4
        case .popover: return 5
        case .farewell: return 6
        }
    }

    /// How many dots the progress shows.
    public static let progressCount = 6
}

/// The parts of the popover the tour names, top to bottom.
public enum TourPopoverPart: Int, Codable, Sendable, CaseIterable {
    /// The status block: the next break, and the "Why not now?" line.
    case status
    /// Take a break · Pause.
    case actions
    /// The all-time totals.
    case totals
    /// The gear: Settings, the popover shortcut, the tour.
    case gear
}

/// How the tour began.
public enum TourOrigin: String, Codable, Sendable {
    /// Onboarding finished: the tour is offered first.
    case onboarding
    /// Settings → General → Take the tour: it starts at once (the user asked).
    case replay
}

/// A real event that ends the rehearsal (SPEC §3.12).
public enum TourInterruption: String, Codable, Sendable, CaseIterable {
    /// A microphone or camera came on.
    case call
    /// A real break came due and was offered, or the user started a real one.
    case realBreak
    /// An agent needs the user.
    case needsYou
    /// Breaks were paused (by hand, or wrap-up) while the sample nudge showed.
    case paused
    /// The user became away (idle, locked, asleep).
    case away
    /// Breakpoint quit.
    case appQuit
}

/// How a tour ended.
public enum TourEnding: Equatable, Sendable {
    /// Not now on the offer.
    case declined
    /// Skip tour (or its key) at any step.
    case skipped
    /// Done on the last card.
    case finished
    case interrupted(TourInterruption)
}

/// What is remembered about the tour (`Settings.tourStatus`): only so it is offered once. It is
/// never started or offered again by itself; Settings → General replays it on request.
public enum TourStatus: String, Codable, Sendable, CaseIterable {
    /// Never offered: a version without the tour, or onboarding not finished yet.
    case notOffered
    /// Offered after onboarding, not answered (Breakpoint quit meanwhile).
    case offered
    case declined
    /// Under way (Breakpoint quit during it).
    case started
    case skipped
    case interrupted
    case finished
}

/// The tour in progress.
public struct TourState: Equatable, Sendable {
    public var step: TourStep
    /// The part of the popover being named (`popover` step only).
    public var popoverPart: TourPopoverPart
    public var origin: TourOrigin
    /// Times Not now was pressed on the sample nudge.
    public var declines: Int
    public var startedAt: Date

    public init(step: TourStep, popoverPart: TourPopoverPart = .status, origin: TourOrigin, declines: Int = 0,
                startedAt: Date) {
        self.step = step
        self.popoverPart = popoverPart
        self.origin = origin
        self.declines = declines
        self.startedAt = startedAt
    }
}

/// What the user (or the world) did. The policy decides what it means at each step.
public enum TourInput: Equatable, Sendable {
    /// The coach card's primary button (Take the tour, Next, Offer it again, Done), its key, or
    /// Return in the popover.
    case next
    /// Start on the sample nudge, or ⌃⌥⌘B.
    case accept
    /// Not now on the sample nudge, or ⌃⌥⌘.
    case decline
    /// The sample break ended: Skip or Done, Esc twice, or its timer.
    case breakEnded
    /// The sample resume card was clicked away.
    case cardDismissed
    /// The popover closed (a click elsewhere, Esc).
    case popoverClosed
    /// Skip tour, or Not now on the offer.
    case skip
    case interrupted(TourInterruption)
}

/// The result of an input.
public enum TourTransition: Equatable, Sendable {
    /// The tour moved on (to another step or another part of the popover).
    case moved(TourState)
    /// The input means nothing at this step.
    case ignored
    case ended(TourEnding)
}

/// One coach line: the caption attached to the surface it explains.
public struct TourCoach: Equatable, Sendable {
    /// Short, 13 pt semibold; `nil` for a single-sentence caption.
    public var title: String?
    /// One or two short sentences.
    public var text: String
    /// The primary button; `nil` when the surface's own controls move the tour on.
    public var primary: String?
    /// A second button on the offer ("Not now"); elsewhere "Skip tour" is always there instead.
    public var secondary: String?

    public init(title: String? = nil, text: String, primary: String? = nil, secondary: String? = nil) {
        self.title = title
        self.text = text
        self.primary = primary
        self.secondary = secondary
    }
}
