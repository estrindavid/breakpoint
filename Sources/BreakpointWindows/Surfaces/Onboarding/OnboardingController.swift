import BreakpointCore
import BreakpointRuntime
import Foundation
import WinSDK

/// The first-launch window (SPEC §3.10), the Windows counterpart of the macOS
/// `OnboardingWindowController`: a fixed-size document window on Mica, light or dark with the
/// system's app mode, centred on the primary display.
///
/// Contract: `show()` opens it (the coordinator calls it while `settings.hasCompletedOnboarding`
/// is false). Finishing, Skip setup, or closing the window calls `actions.completeOnboarding()`
/// once (which registers the login item if on, then offers the tour or opens the flyout once).
/// Completable by keyboard alone: Enter = Continue, Esc = Back, Ctrl+] / Ctrl+[ the same, ← → pick
/// a pace, Tab moves through the controls (then Enter or Space presses the focused one). Nothing is
/// installed until the user presses Install.
@MainActor
final class OnboardingController: SurfaceController {
    private let state: AppState
    private let actions: AppActions
    private var window: DrawnWindow?
    private let model = OnboardingModel()
    private var completed = false
    private var shownOnce = false
    /// The install checks already answered with a hop (by their `connectedAt`).
    private var hopped: [IntegrationID: Date] = [:]

    /// The tray icon's frame, for the Done step's arrow and words (`TrayController.iconFrame`);
    /// `nil` result: the icon is in the overflow. Unset: assumed at the taskbar's usual corner.
    var trayIconFrame: (() -> (RectF, Monitor)?)?
    /// Whether "Open Breakpoint at login" can register this copy.
    var loginItemAvailability: () -> LoginItemAvailability = { WindowsLoginItem().availability() }

    init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
        model.onFinish = { [weak self] in self?.finish() }
        model.onStepChange = { [weak self] in self?.stepChanged() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The current step (development checks).
    var step: OnboardingStep { model.step }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.reduceMotion = Appearance.reduceMotion
        model.loginAvailability = loginItemAvailability()
        window.controls.look = Look.system
        if !shownOnce {
            shownOnce = true
            model.shownAt = Date()
            centre(window)
        }
        if model.step == .done { locateIcon() }
        window.window.show(activate: true)
        updateAnimating()
    }

    func sync() {
        guard let window, window.isVisible else { return }
        let now = Date()
        for row in state.integrations {
            guard case .connected = row.status, let at = row.connectedAt, hopped[row.id] != at else { continue }
            hopped[row.id] = at
            if now.timeIntervalSince(at) < 3 { model.hopStarts[row.id] = now }
        }
        window.setNeedsDisplay()
        updateAnimating()
    }

    func tearDown() {
        window?.destroy()
        window = nil
    }

    // MARK: The window

    private func makeWindow() -> DrawnWindow {
        let window = DrawnWindow(style: .document(title: "Breakpoint", resizable: false), look: Look.system)
        window.background = { [weak window] canvas in
            OnboardingView.background(canvas, look: window?.controls.look ?? .dark)
        }
        window.content = { [weak self] canvas, controls in
            guard let self else { return }
            OnboardingView.draw(canvas, controls, state: self.state, model: self.model, handlers: self.handlers)
            self.updateAnimating()
        }
        window.create(size: Theme.Size.onboardingSize)
        window.window.setContentSize(Theme.Size.onboardingSize)
        window.window.onClose = { [weak self] in
            self?.closed()
            return true
        }
        let original = window.window.onKeyDown
        window.window.onKeyDown = { [weak self, weak window] key in
            if let self, let window, self.handleKey(key, controls: window.controls) { return true }
            return original?(key) ?? false
        }
        SystemEvents.shared.on(UInt32(WM_SETTINGCHANGE)) { [weak self] _, _ in
            self?.appearanceChanged()
            return nil
        }
        return window
    }

    /// Centred in the primary display's work area.
    private func centre(_ window: DrawnWindow) {
        guard let hwnd = window.window.hwnd, let monitor = Monitors.primary() else { return }
        let frame = window.window.pixelFrame
        let width = frame.right - frame.left, height = frame.bottom - frame.top
        let area = monitor.workArea
        SetWindowPos(hwnd, nil, area.left + (area.right - area.left - width) / 2, area.top + (area.bottom - area.top - height) / 2,
                     0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
    }

    /// The app mode or the motion setting changed: redraw in the new look.
    private func appearanceChanged() {
        guard let window, let hwnd = window.window.hwnd else { return }
        Appearance.refresh(hwnd)
        window.controls.look = Look.system
        model.reduceMotion = Appearance.reduceMotion
        window.setNeedsDisplay()
        updateAnimating()
    }

    private var handlers: OnboardingView.Handlers {
        var handlers = OnboardingView.Handlers()
        let actions = self.actions
        handlers.advance = { [weak self] in self?.model.advance() }
        handlers.back = { [weak self] in self?.model.back() }
        handlers.skip = { [weak self] in self?.model.skip() }
        handlers.install = { actions.install($0) }
        handlers.uninstall = { actions.uninstall($0) }
        handlers.choosePreset = { preset in actions.updateSettings { $0.applyPreset(preset) } }
        handlers.setLaunchAtLogin = { on in actions.updateSettings { $0.launchAtLogin = on } }
        return handlers
    }

    private func stepChanged() {
        guard let window else { return }
        window.controls.focused = nil
        if model.step == .done { locateIcon() }
        window.setNeedsDisplay()
        updateAnimating()
    }

    private func updateAnimating() {
        guard let window else { return }
        let wanted = window.isVisible && model.animates(state, at: Date())
        if window.animating != wanted { window.animating = wanted }
    }

    // MARK: Keys

    /// Enter continues and Esc goes back, unless the keyboard has put the focus on a control (then
    /// Enter presses it); Ctrl+] and Ctrl+[ do the same; ← → choose a pace.
    private func handleKey(_ key: UInt32, controls: Controls) -> Bool {
        let focusShown = controls.keyboardUsed && controls.focused != nil
        let ctrl = GetKeyState(Int32(VK_CONTROL)) < 0
        switch Int32(key) {
        case VK_RETURN where !focusShown:
            model.advance()
            return true
        case VK_ESCAPE:
            model.back()
            return true
        case VK_OEM_6 where ctrl:
            model.advance()
            return true
        case VK_OEM_4 where ctrl:
            model.back()
            return true
        case VK_LEFT where model.step == .pace && !focusShown, VK_RIGHT where model.step == .pace && !focusShown:
            movePreset(Int32(key) == VK_LEFT ? -1 : 1)
            return true
        default:
            return false
        }
    }

    private func movePreset(_ delta: Int) {
        let cards = CadencePreset.cards
        let index = cards.firstIndex(of: state.settings.preset) ?? 1
        let next = cards[min(max(index + delta, 0), cards.count - 1)]
        actions.updateSettings { $0.applyPreset(next) }
    }

    // MARK: The Done step's arrow

    /// Points the Done step's arrow at the tray icon and names where it is.
    private func locateIcon() {
        guard let provider = trayIconFrame else {
            model.iconVisible = true
            model.arrowAngle = nil
            return
        }
        guard let window, let (icon, monitor) = provider() else {
            model.iconVisible = false
            model.arrowAngle = nil
            return
        }
        model.iconVisible = true
        let s = monitor.scale
        let to = PointF(x: icon.midX * s, y: icon.midY * s)
        let frame = window.window.pixelFrame
        let from = PointF(x: Float(frame.left + frame.right) / 2, y: Float(frame.top + frame.bottom) / 2)
        // Screen y grows downward; the angle is clockwise from "up".
        model.arrowAngle = atan2(to.x - from.x, from.y - to.y) * 180 / .pi
        let display = monitor.frame
        let width = Float(display.right - display.left), height = Float(display.bottom - display.top)
        let x = to.x - Float(display.left), y = to.y - Float(display.top)
        let vertical = y < height / 2 ? "top" : "bottom"
        let horizontal = x > 2 * width / 3 ? " right" : (x < width / 3 ? " left" : "")
        model.iconPlace = "\(vertical)\(horizontal) of your screen"
    }

    // MARK: Finishing

    private func finish() {
        window?.animating = false
        window?.hide()
        complete()
    }

    private func closed() {
        window?.animating = false
        complete()
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        actions.completeOnboarding()
    }
}
