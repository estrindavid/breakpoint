import Foundation

/// Something that may close the menu-bar popover without the mark being clicked (SPEC §3.8).
public enum PopoverCloseCause: String, Codable, Sendable, CaseIterable {
    /// A click outside the popover: in another app, on the desktop, elsewhere in the menu bar, or
    /// in another Breakpoint window.
    case clickOutside
    /// Esc while the popover has the keyboard.
    case escape
    /// Another app became active (⌘Tab, the Dock, a click that activated it).
    case otherAppActive
    /// The active Space changed.
    case spaceChanged
    /// A display was added, removed, rearranged or resized.
    case displayChanged
    /// The menu bar the popover hangs from slid away (a full-screen Space, or a menu bar set to
    /// hide itself).
    case menuBarHidden

    /// For the trace: "a click outside it", "Esc", ….
    public var phrase: String {
        switch self {
        case .clickOutside: return "a click outside it"
        case .escape: return "Esc"
        case .otherAppActive: return "another app becoming active"
        case .spaceChanged: return "a Space change"
        case .displayChanged: return "a display change"
        case .menuBarHidden: return "the menu bar sliding away"
        }
    }
}

/// When the popover closes by itself (SPEC §3.8). Pure: the status item reports what happened, the
/// coordinator asks and closes it.
///
/// - The person's own acts close it at once, always: a click anywhere outside it, Esc.
/// - So do another app becoming active, a Space change and a display change, except in the first
///   `Timing.popoverSettle` after it opened: opening it activates Breakpoint, and macOS may answer
///   that with a Space switch or a late activation of its own; those are not the person leaving.
/// - The menu bar it hangs from sliding away closes it, unless the pointer is on the popover (the
///   person is using it: in a full-screen Space the menu bar slides away as soon as the pointer
///   moves down into the popover), the tour is naming its parts, or it carries its first-use hint.
///   Those keep it open where it is, until a click outside, Esc or one of the changes above.
/// - It never moves while open: it hangs from where the mark was when it opened.
public enum PopoverPolicy {
    public struct Context: Equatable, Sendable {
        /// The one-minute tour is at its popover step (SPEC §3.12).
        public var tourStep: Bool
        /// The popover carries its first-use hint this time.
        public var showsHint: Bool
        /// The pointer is over the popover.
        public var pointerOnPopover: Bool
        /// How long the popover has been open.
        public var secondsOpen: TimeInterval

        public init(tourStep: Bool = false, showsHint: Bool = false, pointerOnPopover: Bool = false,
                    secondsOpen: TimeInterval = .infinity) {
            self.tourStep = tourStep
            self.showsHint = showsHint
            self.pointerOnPopover = pointerOnPopover
            self.secondsOpen = secondsOpen
        }
    }

    public static func closes(for cause: PopoverCloseCause, context: Context) -> Bool {
        switch cause {
        case .clickOutside, .escape:
            return true
        case .otherAppActive, .spaceChanged, .displayChanged:
            return context.secondsOpen >= Timing.popoverSettle
        case .menuBarHidden:
            return !(context.pointerOnPopover || context.tourStep || context.showsHint)
        }
    }
}
