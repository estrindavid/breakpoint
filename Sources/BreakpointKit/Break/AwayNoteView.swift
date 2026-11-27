import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.5 away note.

/// A single-line glass capsule 44 pt high: kind badge 32 pt (inset 6, concentric) · "Counted your
/// 6 min away as a break" 13 pt · Undo (tertiary, 28 pt). Auto-hides after 10 s (hover holds it;
/// the lit edge is the timer, `timeRim`);
/// × on hover.
public struct AwayNoteView: View {
    private let note: AwayNoteContent
    private let hovering: Bool
    private let timeRim: TimeRimSource?
    private let onUndo: () -> Void
    private let onClose: (() -> Void)?

    public init(note: AwayNoteContent, hovering: Bool = false, timeRim: TimeRimSource? = nil,
                onUndo: @escaping () -> Void, onClose: (() -> Void)? = nil) {
        self.note = note
        self.hovering = hovering
        self.timeRim = timeRim
        self.onUndo = onUndo
        self.onClose = onClose
    }

    public var body: some View {
        ToastShell(text: note.text, badge: note.kind, actionTitle: "Undo", action: onUndo)
            .capsuleTimeRim(timeRim)
            .cornerCloseButton(visible: hovering, action: onClose)
    }
}
