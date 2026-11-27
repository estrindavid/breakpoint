import SwiftUI
import BreakpointCore

// SPEC §3.5.

/// Shows every `.resume` card in `state.cards` through the panel stack. Auto-hides after 10 s
/// (hover holds it, leaving resumes with at least 5 s; its lit edge is the timer); needs-you cards stay until dismissed (priority
/// `.needsYouResume`) or until the coordinator removes them because the agent is no longer waiting.
/// A click anywhere on the card, or its ×, dismisses it.
///
/// Keyboard: the card never takes focus, so it cannot receive Esc. While a resume card shows and
/// the nudge hotkeys are on, ⌃⌥⌘. (the nudge's "Not now") dismisses it, through `HotKeyCenter` at
/// a lower priority than the nudge: with a nudge on screen the key still declines the nudge.
/// The card shows the keycap on hover while the key would reach it.
@MainActor
public final class ResumeCardController: SurfaceController {
    private let state: AppState
    private let hotKeys: HotKeyCenter?
    private let keyModel = ResumeKeyModel()
    private var surface: CardPanelSurface!
    private var token: HotKeyToken?

    /// Below the nudge's default priority, so the nudge keeps ⌃⌥⌘. while both are visible.
    static let hotKeyPriority = -1

    public init(state: AppState, actions: AppActions, stack: TransientPanelStack, hotKeys: HotKeyCenter? = nil) {
        self.state = state
        self.hotKeys = hotKeys
        let keyModel = self.keyModel
        surface = CardPanelSurface(
            state: state, actions: actions, stack: stack,
            matches: { if case .resume = $0 { return true } else { return false } },
            // The tour's sample card carries its coach line underneath (SPEC §3.12).
            makeAccessory: { [weak state] card in
                guard card.isRehearsal, let tour = state?.tour, tour.step == .resumeCard else { return nil }
                return AnyView(TourAttachedCaptionInCard(tour: tour, actions: actions))
            },
            makeView: { card, context in
                guard case .resume(let content) = card.content else { return AnyView(EmptyView()) }
                return AnyView(ResumeCardHost(card: content, hovering: context.hovering, timeRim: context.timeRim, keys: keyModel, onDismiss: context.close))
            })
    }

    public func sync() {
        surface.sync()
        let resumeCards = state.cards.filter { if case .resume = $0.content { return true } else { return false } }
        let wanted = !resumeCards.isEmpty && state.settings.nudgeHotkeys
        if wanted, token == nil, let hotKeys {
            token = hotKeys.register(.nudgeDismiss, priority: Self.hotKeyPriority) { [weak self] in self?.dismissNewest() }
        } else if !wanted, let current = token {
            hotKeys?.unregister(current)
            token = nil
        }
        // The keycap only where the key reaches this card (a visible nudge takes it first).
        let key = token != nil && state.nudge == nil ? HotKeyCombo.nudgeDismiss.display : nil
        if keyModel.dismissKey != key { keyModel.dismissKey = key }
    }

    public func tearDown() {
        if let current = token { hotKeys?.unregister(current) }
        token = nil
        surface.tearDown()
    }

    private func dismissNewest() {
        guard let card = state.cards.last(where: { if case .resume = $0.content { return true } else { return false } }) else { return }
        surface.closeCard(card.id)
    }
}

/// Which keycap the resume card may show on hover (none while the key belongs to the nudge).
@MainActor
final class ResumeKeyModel: ObservableObject {
    @Published var dismissKey: String?
}

private struct ResumeCardHost: View {
    let card: ResumeCardContent
    let hovering: Bool
    let timeRim: TimeRimSource?
    @ObservedObject var keys: ResumeKeyModel
    let onDismiss: () -> Void

    var body: some View {
        ResumeCardView(card: card, hovering: hovering, dismissKey: keys.dismissKey, timeRim: timeRim, onDismiss: onDismiss)
    }
}
