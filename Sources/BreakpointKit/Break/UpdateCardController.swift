import SwiftUI
import BreakpointCore

// SPEC §2.11, §3.5 update prompt.

/// Shows the `.update` card through the panel stack (20 s, hover holds it, its lit edge is the
/// timer while it is an offer). Update → `actions.installUpdate()`; Download page / Open download
/// page → `actions.openUpdate()`; Later, Close, × and the timeout → `dismissCard`, which the
/// coordinator turns into "ask again in three days". Never takes focus.
@MainActor
public final class UpdateCardController: SurfaceController {
    private let surface: CardPanelSurface

    public init(state: AppState, actions: AppActions, stack: TransientPanelStack) {
        surface = CardPanelSurface(
            state: state, actions: actions, stack: stack,
            matches: { if case .update = $0 { return true } else { return false } },
            makeView: { card, context in
                guard case .update(let content) = card.content else { return AnyView(EmptyView()) }
                return AnyView(UpdateCardView(card: content, hovering: context.hovering, timeRim: context.timeRim,
                                              onUpdate: { actions.installUpdate() }, onOpenPage: { actions.openUpdate() },
                                              onLater: context.close))
            })
    }

    public func sync() { surface.sync() }
    public func tearDown() { surface.tearDown() }
}
