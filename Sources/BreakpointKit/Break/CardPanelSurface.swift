import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// Shared plumbing for the card controllers.

/// What a card view gets from its surface besides the card itself.
struct CardContext {
    /// The pointer is over the card.
    var hovering: Bool
    /// The pointer has rested on the card for 300 ms.
    var revealed: Bool
    /// Close the card (×, click, Done): `actions.dismissCard(id)` with the action exit.
    var close: () -> Void
    /// The card's time rim (§3.5), while it hides itself; `nil` for cards that stay.
    var timeRim: TimeRimSource? = nil
}

/// Shows one `TransientPanel` per card of a given type from `AppState.cards`, through the shared
/// `TransientPanelStack`, with the pop-up motion of SPEC §4.6:
/// - arrival: the glass grows out of a point under the top edge on a soft spring (`PopupMotion`);
/// - auto-hide after `CardState.autoHideAfter` as a `CardCountdown`: held while hovered, resumed
///   when the pointer leaves with what it had left but at least half (§3.0); the card's time rim
///   draws the same countdown; the timeout exit folds the card back up into that point over
///   0.35 s and then calls `AppActions.dismissCard`;
/// - any other removal (an action, Undo, eviction, the coordinator) settles and fades 0.2 s.
@MainActor
final class CardPanelSurface {
    private let state: AppState
    private let actions: AppActions
    private let stack: TransientPanelStack
    private let matches: (CardContent) -> Bool
    private let makeView: (CardState, CardContext) -> AnyView
    /// Drawn under the card, outside its glass (the tour's coach line on its sample card).
    private let makeAccessory: ((CardState) -> AnyView?)?
    private let configure: ((TransientPanel, UUID) -> Void)?
    private var live: [UUID: LiveCard] = [:]

    @MainActor
    final class LiveCard: ObservableObject {
        let id: UUID
        @Published var card: CardState
        let popup = PopupModel()
        var panel: TransientPanel?
        var timer: Timer?
        /// The auto-hide countdown and its rim; `nil` while the card stays until dismissed.
        @Published var rim: TimeRimTimeline?
        var leaving = false

        init(card: CardState) {
            id = card.id
            self.card = card
        }
    }

    init(state: AppState, actions: AppActions, stack: TransientPanelStack,
         matches: @escaping (CardContent) -> Bool,
         configure: ((TransientPanel, UUID) -> Void)? = nil,
         makeAccessory: ((CardState) -> AnyView?)? = nil,
         makeView: @escaping (CardState, CardContext) -> AnyView) {
        self.state = state
        self.actions = actions
        self.stack = stack
        self.matches = matches
        self.configure = configure
        self.makeAccessory = makeAccessory
        self.makeView = makeView
    }

    func sync() {
        let cards = state.cards.filter { matches($0.content) }
        let ids = Set(cards.map(\.id))
        for (id, card) in live where !ids.contains(id) && !card.leaving {
            leave(card, exit: .action, thenDismiss: false)
        }
        for card in cards {
            if let existing = live[card.id] {
                if existing.card != card { existing.card = card }
                // A card that stayed until dismissed may start hiding itself (a resume card whose
                // needs-you row went away while finished rows remain).
                if existing.rim == nil, let full = card.autoHideAfter, !existing.leaving {
                    startCountdown(existing, full: full)
                }
            } else {
                show(card)
            }
        }
    }

    func tearDown() {
        for card in live.values {
            card.timer?.invalidate()
            stack.dismiss(id: card.id)
            card.panel?.close()
        }
        live.removeAll()
    }

    /// Closes the card as its × would (a keyboard dismiss): 0.2 s fade, then `dismissCard`.
    func closeCard(_ id: UUID) { close(id) }

    // MARK: Lifecycle

    private func show(_ card: CardState) {
        let model = LiveCard(card: card)
        live[card.id] = model
        let id = card.id
        let makeView = self.makeView
        let close: () -> Void = { [weak self] in self?.close(id) }
        let root = CardRoot(model: model, makeView: makeView, makeAccessory: makeAccessory, close: close)
        let panel = TransientPanel(rootView: root)
        panel.onHoverChange = { [weak self, weak model] inside in
            guard let self, let model else { return }
            model.popup.setHovering(inside)
            self.hoverChanged(model, inside: inside)
        }
        configure?(panel, id)
        model.panel = panel
        stack.present(panel, id: id, priority: card.priority)
        DispatchQueue.main.async { [weak model] in
            guard let model, !model.leaving else { return }
            model.popup.phase = .shown
        }
        if let full = card.autoHideAfter { startCountdown(model, full: full) }
    }

    private func close(_ id: UUID) {
        guard let model = live[id], !model.leaving else { return }
        leave(model, exit: .action, thenDismiss: true)
    }

    /// Starts the card's countdown (on arrival, or when a card that stayed starts hiding itself);
    /// the rim draws itself out from the top centre. A card that is hovered starts held.
    private func startCountdown(_ model: LiveCard, full: TimeInterval) {
        let now = Date()
        var rim = TimeRimTimeline.arriving(CardCountdown(full: full, start: now), at: now)
        if model.popup.hovering { rim = TimeRimTimeline(countdown: rim.countdown.held(at: now)) }
        model.rim = rim
        scheduleTimeout(model)
    }

    private func hoverChanged(_ model: LiveCard, inside: Bool) {
        guard let rim = model.rim, !model.leaving else { return }
        let now = Date()
        model.rim = inside ? rim.held(at: now) : rim.resumed(at: now, reduceMotion: SystemMotion.reduceMotion)
        scheduleTimeout(model)
    }

    /// One timer at the countdown's deadline (none while held).
    private func scheduleTimeout(_ model: LiveCard) {
        model.timer?.invalidate()
        model.timer = nil
        guard let deadline = model.rim?.countdown.deadline else { return }
        model.timer = Timer.scheduledTimer(withTimeInterval: max(0, deadline.timeIntervalSinceNow), repeats: false) { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                guard let self, let model, !model.popup.hovering, !model.leaving else { return }
                self.leave(model, exit: .timeout, thenDismiss: true)
            }
        }
    }

    /// Plays `exit`, then removes the panel; `thenDismiss` tells the coordinator (timeouts and
    /// closes start here; removals by the coordinator do not).
    private func leave(_ model: LiveCard, exit: PopupExit, thenDismiss: Bool) {
        model.leaving = true
        model.timer?.invalidate()
        model.timer = nil
        model.popup.phase = .leaving(exit)
        let id = model.id
        stack.markLeaving(id: id)
        let duration = exit.duration(reduceMotion: SystemMotion.reduceMotion)
        if thenDismiss && exit == .action { actions.dismissCard(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.03) { [weak self] in
            guard let self else { return }
            if thenDismiss && exit == .timeout { self.actions.dismissCard(id) }
            self.stack.dismiss(id: id)
            model.panel?.close()
            if self.live[id] === model { self.live[id] = nil }
        }
    }
}

/// Renders the current content of one card with its pop-up motion.
private struct CardRoot: View {
    @ObservedObject var model: CardPanelSurface.LiveCard
    @ObservedObject var popup: PopupModel
    let makeView: (CardState, CardContext) -> AnyView
    let makeAccessory: ((CardState) -> AnyView?)?
    let close: () -> Void

    init(model: CardPanelSurface.LiveCard, makeView: @escaping (CardState, CardContext) -> AnyView,
         makeAccessory: ((CardState) -> AnyView?)?, close: @escaping () -> Void) {
        self.model = model
        self.popup = model.popup
        self.makeView = makeView
        self.makeAccessory = makeAccessory
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            makeView(model.card, CardContext(hovering: popup.hovering, revealed: popup.revealed, close: close,
                                             timeRim: model.rim.map { .live($0) }))
                .popupMotion(popup.phase)
            if let accessory = makeAccessory?(model.card) {
                accessory.environment(\.popupPhase, popup.phase)
            }
        }
    }
}
