import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.5.

/// Shows `.toast` cards through the panel stack (3 s, hover holds, leaving resumes with at least 1.5 s; the lit edge is the timer).
/// Resume → `actions.resume()`, then the toast closes.
@MainActor
public final class ToastController: SurfaceController {
    private let surface: CardPanelSurface

    public init(state: AppState, actions: AppActions, stack: TransientPanelStack) {
        surface = CardPanelSurface(
            state: state, actions: actions, stack: stack,
            matches: { if case .toast = $0 { return true } else { return false } },
            makeView: { card, context in
                guard case .toast(let toast) = card.content else { return AnyView(EmptyView()) }
                return AnyView(ToastView(toast: toast, hovering: context.hovering, timeRim: context.timeRim, onAction: {
                    actions.resume()
                    context.close()
                }, onClose: context.close))
            })
    }

    public func sync() { surface.sync() }
    public func tearDown() { surface.tearDown() }
}
