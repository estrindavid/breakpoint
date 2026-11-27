import SwiftUI
import BreakpointCore

// SPEC §3.5.

/// Shows the `.awayNote` card through the panel stack (10 s, hover holds it, its lit edge is the timer); Undo →
/// `actions.undoLastDecision()` (the coordinator replaces the note with "Timers restored").
@MainActor
public final class AwayNoteController: SurfaceController {
    private let surface: CardPanelSurface

    public init(state: AppState, actions: AppActions, stack: TransientPanelStack) {
        surface = CardPanelSurface(
            state: state, actions: actions, stack: stack,
            matches: { if case .awayNote = $0 { return true } else { return false } },
            makeView: { card, context in
                guard case .awayNote(let note) = card.content else { return AnyView(EmptyView()) }
                return AnyView(AwayNoteView(note: note, hovering: context.hovering, timeRim: context.timeRim,
                                            onUndo: { actions.undoLastDecision() }, onClose: context.close))
            })
    }

    public func sync() { surface.sync() }
    public func tearDown() { surface.tearDown() }
}
