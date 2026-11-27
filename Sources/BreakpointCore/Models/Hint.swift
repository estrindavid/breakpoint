import Foundation

// First-use hints (SPEC §3.12): the first time a real surface appears it may carry one short line.
// Pure data; the rules live in `HintPolicy` (Engine/), the words in `HintCopy` (Routines/).

/// A real surface that carries at most one hint, once.
public enum HintSurface: String, Sendable, CaseIterable {
    case nudge
    case breakScreen = "break"
    case resumeCard
    case popover
    case callPause
}

/// One thing a hint teaches. A surface has one lesson, or two when it comes in two kinds that the
/// tour can tell apart: the tour's sample nudge never starts by itself, and its sample resume card
/// is never a needs-you card, so those two lessons are left for real use.
public enum HintLesson: String, Codable, Sendable, CaseIterable {
    /// An ordinary offer: Start, or carry on; it asks again later.
    case nudge
    /// An eye rest that starts by itself: any key keeps you working.
    case autoStart
    /// The break screen: the chip follows your agent; Esc twice skips.
    case breakScreen = "break"
    /// A resume card that sums up and goes by itself.
    case resumeCard
    /// A resume card that stays because an agent needs you: a key or a click dismisses it.
    case resumeNeedsYou
    /// The popover: Option-click the mark for "Why not now?".
    case popover
    /// The call-pause toast: breaks come back after the call.
    case callPause

    /// The surface that carries this lesson.
    public var surface: HintSurface {
        switch self {
        case .nudge, .autoStart: return .nudge
        case .breakScreen: return .breakScreen
        case .resumeCard, .resumeNeedsYou: return .resumeCard
        case .popover: return .popover
        case .callPause: return .callPause
        }
    }
}
