import BreakpointCore
import BreakpointRuntime
import CBreakpointWin32
import Foundation
import WinSDK

/// The one-minute tour's coach (SPEC §3.12), the Windows counterpart of the macOS
/// `TourCoachController`. It draws only the coach: the sample nudge, break screen and resume
/// card are the real surfaces, shown by their own controllers from `AppState`.
///
/// - Offer, mark and farewell: a coach card hanging from the tray icon (above it, with the coach
///   dot on its bottom edge, over a bottom taskbar; below it under a top one; beside a side one).
///   When the icon is in the overflow (no `tray.iconFrame`) the card takes the pop-ups' place
///   through `PopupStack`. Not now's result always takes the nudge's place in the stack.
/// - The sample nudge and the sample resume card: `attachedCaption` draws the coach line inside
///   those pop-ups' own windows, under the card. The shell hands it to
///   `NudgeController.tourCaption` and `CardsController.tourCaption`.
/// - The sample break: the overlay draws its own coach lines and the rehearsal footer
///   (`OverlayView`), so nothing here.
/// - The popover step: `tray.tourStrip` draws the strip at the bottom of the flyout, and Enter
///   presses its Next. The flyout opens when the step begins; the coordinator asks for it too.
/// - Every coach window is a pop-up and never takes focus. While a standalone card shows and the
///   nudge hotkeys are on, Ctrl+Alt+Win+B presses its primary button and Ctrl+Alt+Win+. skips.
@MainActor
final class TourCoachController: SurfaceController {
    private let state: AppState
    private let actions: AppActions
    private let stack: PopupStack
    private let hotKeys: HotKeys
    private let tray: TrayController

    private var card: DrawnWindow?
    private var cardID = UUID()
    private var cardInStack = false
    private var cardTour: TourPresentation?
    private var cardPointer: TourPointer = .none
    private var cardFrame: RectF?
    private var lastStep: TourStep?
    private var tokens: [HotKeys.Token] = []

    init(state: AppState, actions: AppActions, stack: PopupStack, hotKeys: HotKeys, tray: TrayController) {
        self.state = state
        self.actions = actions
        self.stack = stack
        self.hotKeys = hotKeys
        self.tray = tray
        tray.tourStrip = { [weak self] canvas, controls, origin, width in
            guard let self, let tour = self.state.tour, tour.step == .popover else { return 0 }
            return TourCoachView.strip(canvas, controls, tour: tour, at: origin, width: width, handlers: self.handlers)
        }
    }

    /// The coach line under the sample nudge and the sample resume card, drawn in their windows
    /// at `origin`, `width` wide; returns its height (nil canvas: measure only; 0 outside those
    /// steps). For `NudgeController.tourCaption` and `CardsController.tourCaption`.
    var attachedCaption: (Canvas?, Controls?, PointF, Float) -> Float {
        { [weak self] canvas, controls, origin, width in
            guard let self, let tour = self.state.tour, tour.step == .nudge || tour.step == .resumeCard else { return 0 }
            return TourCoachView.attached(canvas, controls, tour: tour, at: origin, width: width, handlers: self.handlers)
        }
    }

    /// The steps whose coach card stands on its own.
    static func showsCard(for step: TourStep) -> Bool { [.offer, .mark, .declined, .farewell].contains(step) }

    /// The standalone coach card is on screen (development checks).
    var isCardVisible: Bool { card?.isVisible ?? false }

    private var handlers: TourCoachHandlers {
        let actions = self.actions
        return TourCoachHandlers(primary: { actions.tour(.next) }, secondary: { actions.tour(.skip) },
                                 skip: { actions.tour(.skip) })
    }

    // MARK: SurfaceController

    func sync() {
        guard let tour = state.tour else {
            lastStep = nil
            hideCard()
            unregisterHotKeys()
            return
        }
        if tour.step != lastStep {
            lastStep = tour.step
            stepBegan(tour.step)
        }
        if Self.showsCard(for: tour.step) {
            showStandalone(tour)
        } else {
            hideCard()
        }
        syncHotKeys(tour)
    }

    func tearDown() {
        unregisterHotKeys()
        if cardInStack { stack.dismiss(cardID) }
        cardInStack = false
        card?.destroy()
        card = nil
        tray.tourStrip = nil
    }

    private func stepBegan(_ step: TourStep) {
        // A new step's card is a new pop-up (the stack places it afresh).
        if cardInStack {
            stack.dismiss(cardID)
            cardInStack = false
        }
        cardID = UUID()
        if step == .popover, !tray.isFlyoutOpen { tray.showFlyout() }
    }

    // MARK: The coach card

    private func makeCard() -> DrawnWindow {
        if let card { return card }
        let window = DrawnWindow(style: .popup)
        window.create(size: SizeF(width: TourCoachView.width, height: 160), owner: SystemEvents.shared.hwnd)
        window.content = { [weak self] canvas, controls in
            guard let self, let tour = self.cardTour else { return }
            TourCoachView.card(canvas, controls, tour: tour, width: canvas.size.width, pointer: self.cardPointer, handlers: self.handlers)
        }
        card = window
        return window
    }

    /// Offer, mark, Not now's result and the farewell.
    private func showStandalone(_ tour: TourPresentation) {
        let window = makeCard()
        cardTour = tour
        let width = TourCoachView.width
        if tour.step != .declined, let hanging = hangingPlacement(tour) {
            if cardInStack {
                stack.dismiss(cardID)
                cardInStack = false
            }
            cardPointer = hanging.pointer
            if hanging.frame != cardFrame || !window.isVisible {
                window.window.place(hanging.frame, on: hanging.monitor)
                cardFrame = hanging.frame
            }
            if !window.isVisible { window.window.show(activate: false) }
        } else {
            cardPointer = .none
            cardFrame = nil
            let height = TourCoachView.card(nil, nil, tour: tour, width: width, pointer: .none, handlers: handlers)
            stack.present(window.window, id: cardID, size: SizeF(width: width, height: height), priority: .nudge)
            cardInStack = true
        }
        window.setNeedsDisplay()
    }

    /// Above the tray icon (below it under a top taskbar, beside a side one), 12 DIPs from the
    /// taskbar and the screen's edges, where the flyout sits.
    private func hangingPlacement(_ tour: TourPresentation) -> (frame: RectF, monitor: Monitor, pointer: TourPointer)? {
        guard let (icon, monitor) = tray.iconFrame else { return nil }
        let area = monitor.workAreaDIPs
        let gap: Float = 12
        var left: Int32 = 0, top: Int32 = 0, right: Int32 = 0, bottom: Int32 = 0
        let edge = bp_taskbar_edge(&left, &top, &right, &bottom)
        let width = TourCoachView.width
        let pointing: TourPointer
        switch edge {
        case 1: pointing = .up(x: nil)
        case 0, 2: pointing = .none
        default: pointing = .down(x: nil)
        }
        let height = TourCoachView.card(nil, nil, tour: tour, width: width, pointer: pointing, handlers: handlers)
        var frame = RectF(x: icon.midX - width / 2, y: 0, width: width, height: height)
        switch edge {
        case 1: frame.y = area.y + gap
        case 0: frame.x = area.x + gap; frame.y = icon.midY - height / 2
        case 2: frame.x = area.maxX - gap - width; frame.y = icon.midY - height / 2
        default: frame.y = area.maxY - gap - height
        }
        frame.x = min(max(frame.x, area.x + gap), area.maxX - gap - width)
        frame.y = min(max(frame.y, area.y + gap), area.maxY - gap - height)
        let pointerX = icon.midX - frame.x
        let pointer: TourPointer
        switch pointing {
        case .up: pointer = .up(x: pointerX)
        case .down: pointer = .down(x: pointerX)
        case .none: pointer = .none
        }
        return (frame, monitor, pointer)
    }

    private func hideCard() {
        if cardInStack {
            stack.dismiss(cardID)
            cardInStack = false
        }
        card?.hide()
        cardFrame = nil
    }

    // MARK: Hotkeys

    private func syncHotKeys(_ tour: TourPresentation) {
        let wanted = tour.hotkeysEnabled && Self.showsCard(for: tour.step)
        if wanted, tokens.isEmpty {
            let next = hotKeys.register(.nudgeStart) { [weak self] in self?.actions.tour(.next) }
            let skip = hotKeys.register(.nudgeDismiss) { [weak self] in self?.actions.tour(.skip) }
            tokens = [next, skip].compactMap { $0 }
        } else if !wanted {
            unregisterHotKeys()
        }
    }

    private func unregisterHotKeys() {
        for token in tokens { hotKeys.unregister(token) }
        tokens.removeAll()
    }
}
