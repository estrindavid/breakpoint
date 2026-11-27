import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.12. The tour's coach cards that stand on their own: the offer, the mark, Not now's
// result and the farewell. The other steps' coach lines belong to the surface they explain (the
// nudge panel, the break screen, the resume card's panel, the popover).

/// Shows the coach card for the tour's `offer`, `mark`, `declined` and `farewell` steps.
///
/// Contract (beyond `SurfaceController`):
/// - The offer, the mark and the farewell hang from the menu-bar mark (`StatusItemController.current`)
///   with a pointer up to it, through `TransientPanelStack.presentHanging`; when macOS hides the
///   item (a full menu bar, the notch), they take the pop-ups' place without a pointer.
///   Not now's result takes the nudge's place in the stack.
/// - A non-activating panel: never takes focus. While it shows and the nudge hotkeys are on,
///   ⌃⌥⌘B presses its primary button and ⌃⌥⌘. skips the tour (on the offer: Not now).
/// - Arrives with a short fade and 6 pt drop (a fade under Reduce Motion); a change of step
///   cross-fades the words in place.
@MainActor
public final class TourCoachController: SurfaceController {
    private let state: AppState
    private let actions: AppActions
    private let stack: TransientPanelStack
    private let hotKeys: HotKeyCenter?
    private let model = TourCoachModel()
    private var panel: TransientPanel?
    private var shownID = UUID()
    private var hangs = false
    private var tokens: [HotKeyToken] = []

    public init(state: AppState, actions: AppActions, stack: TransientPanelStack, hotKeys: HotKeyCenter? = nil) {
        self.state = state
        self.actions = actions
        self.stack = stack
        self.hotKeys = hotKeys
    }

    /// The steps whose coach card stands on its own.
    public static func showsCard(for step: TourStep) -> Bool {
        [.offer, .mark, .declined, .farewell].contains(step)
    }

    /// The steps whose card hangs from the menu-bar mark.
    public static func hangsFromMark(_ step: TourStep) -> Bool { step != .declined }

    public func sync() {
        guard let tour = state.tour, Self.showsCard(for: tour.step) else {
            hide()
            return
        }
        let wantsHanging = Self.hangsFromMark(tour.step) && StatusItemController.current?.statusItemFrame != nil
        if panel != nil, wantsHanging != hangs { hide() }
        if model.tour != tour { model.tour = tour }
        if panel == nil { show(hanging: wantsHanging) }
        syncHotKeys(tour)
    }

    public func tearDown() {
        unregisterHotKeys()
        if panel != nil { stack.dismiss(id: shownID) }
        panel?.close()
        panel = nil
    }

    private func show(hanging: Bool) {
        let actions = self.actions
        let root = TourCoachHost(model: model, actions: actions)
        let panel = TransientPanel(rootView: root)
        self.panel = panel
        shownID = UUID()
        hangs = hanging
        model.arrived = false
        if hanging, let anchor = StatusItemController.current?.statusItemFrame,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }) {
            model.pointerX = TransientPanelStack.hangingPlacement(cardWidth: CoachCaption.width, anchor: anchor, on: screen).pointerX
            stack.presentHanging(panel, id: shownID, below: anchor)
        } else {
            model.pointerX = nil
            stack.present(panel, id: shownID, priority: .nudge)
        }
        DispatchQueue.main.async { [weak model] in model?.arrived = true }
        if let tour = model.tour {
            Announcer.announce([tour.coach.title, tour.coach.text].compactMap { $0 }.joined(separator: ". "))
        }
    }

    private func hide() {
        unregisterHotKeys()
        guard let panel else { return }
        self.panel = nil
        let id = shownID
        model.arrived = false
        stack.markLeaving(id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.reduceMotionFade + 0.03) { [weak self] in
            self?.stack.dismiss(id: id)
            panel.close()
        }
    }

    // MARK: Hotkeys

    private func syncHotKeys(_ tour: TourPresentation) {
        let wanted = tour.hotkeysEnabled && hotKeys != nil
        if wanted, tokens.isEmpty, let hotKeys {
            let next = hotKeys.register(.nudgeStart) { [weak self] in self?.actions.tour(.next) }
            let skip = hotKeys.register(.nudgeDismiss) { [weak self] in self?.actions.tour(.skip) }
            tokens = [next, skip].compactMap { $0 }
        } else if !wanted {
            unregisterHotKeys()
        }
    }

    private func unregisterHotKeys() {
        tokens.forEach { hotKeys?.unregister($0) }
        tokens.removeAll()
    }
}

@MainActor
final class TourCoachModel: ObservableObject {
    @Published var tour: TourPresentation?
    /// Where the pointer meets the mark, from the card's leading edge; `nil`: no pointer.
    @Published var pointerX: CGFloat?
    @Published var arrived = false
}

/// The standalone coach card: the step's caption (the mark's legend on the mark step), arriving
/// with a short fade and drop.
struct TourCoachHost: View {
    @ObservedObject var model: TourCoachModel
    let actions: AppActions
    private let traits = DesignTraits()

    var body: some View {
        if let tour = model.tour {
            TourCoachCard(tour: tour, pointerX: model.pointerX, actions: actions)
                // Faded as one picture: glass, rim and shadow never show through each other mid-fade.
                .compositingGroup()
                .opacity(model.arrived ? 1 : 0)
                .offset(y: model.arrived || traits.reduceMotion ? 0 : -6)
                .animation(traits.animation(.popupIn), value: model.arrived)
                .animation(traits.animation(.subtitleSwap), value: tour.step)
        }
    }
}

/// One standalone coach card as it looks at `tour.step` (also used by the snapshots and the film).
public struct TourCoachCard: View {
    let tour: TourPresentation
    let pointerX: CGFloat?
    let actions: AppActions

    public init(tour: TourPresentation, pointerX: CGFloat?, actions: AppActions) {
        self.tour = tour
        self.pointerX = pointerX
        self.actions = actions
    }

    public var body: some View {
        CoachCaption(tour, pointer: pointerX.map { .up(x: $0) } ?? .none,
                     accessory: tour.step == .mark ? AnyView(MarkLegend()) : nil, actions: actions)
            .id(tour.step)
            .transition(.opacity)
    }
}
