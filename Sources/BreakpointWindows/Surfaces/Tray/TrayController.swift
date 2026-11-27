import BreakpointCore
import BreakpointRuntime
import CBreakpointWin32
import Foundation
import WinSDK

/// The notification-area icon and its flyout: the Windows counterpart of the macOS
/// `StatusItemController` (SPEC §3.7, §3.8).
///
/// - The icon shows `state.menuBar`'s mark and badge; the working badge breathes at 0.5 Hz
///   (steady under "Animation effects" off, and while the session is locked); each mark cue
///   (settle, lift, fold) plays once. Windows has no text beside a tray icon: the menu-bar text
///   goes into the tooltip after the sentence.
/// - Left click (or Enter on the focused icon) toggles the flyout; right click opens the menu:
///   the tooltip sentence and "Why not now?" as greyed lines, Take a break ▸, Pause ▸ or Resume
///   now, Settings…, Quit Breakpoint.
/// - The flyout sits above the taskbar at the icon (12 DIPs from the taskbar and the screen edge,
///   as Windows' own flyouts do). Whatever may close it (a click elsewhere or another window
///   activating, Esc, a display change) goes to `actions.popoverMayClose`; the coordinator decides.
/// - The optional popover shortcut (`Settings.popoverHotkey`) toggles the flyout.
@MainActor
final class TrayController: SurfaceController {
    private let state: AppState
    private let actions: AppActions
    private let hotKeys: HotKeys
    private let icon = TrayIcon()
    private var flyout: DrawnWindow?
    private var flyoutOpen = false
    private var closedAt: Date?

    private var renderedMenuBar: MenuBarState?
    private var renderedPulseStep: Int?
    private var pulseTimer: Timer?
    private var lastCueID: Int?
    private var cue: (cue: MarkCue, startedAt: Date, variant: MarkVariant, badge: MarkBadge)?
    private var cueTimer: Timer?
    private var flyoutTimer: Timer?
    private var sessionLocked = false
    private var registeredHotKey: (combo: HotKeyCombo, token: HotKeys.Token)?
    private var refusedHotKey: HotKeyCombo?
    private static let pulseSteps = 8

    init(state: AppState, actions: AppActions, hotKeys: HotKeys) {
        self.state = state
        self.actions = actions
        self.hotKeys = hotKeys
        icon.onSelect = { [weak self] _ in self?.clicked() }
        icon.onKeySelect = { [weak self] in self?.toggleFlyout() }
        icon.onMenu = { [weak self] point in self?.showMenu(at: point) }
    }

    // MARK: Lifetime

    func install() {
        icon.install()
        SystemEvents.shared.on(UInt32(WM_WTSSESSION_CHANGE)) { [weak self] wParam, _ in
            // WTS_SESSION_LOCK 7, WTS_SESSION_UNLOCK 8.
            if wParam == 7 { self?.sessionLocked = true }
            if wParam == 8 { self?.sessionLocked = false }
            self?.sync()
            return nil
        }
        SystemEvents.shared.on(UInt32(WM_DISPLAYCHANGE)) { [weak self] _, _ in
            self?.report(.displayChanged)
            return nil
        }
        SystemEvents.shared.on(UInt32(WM_SETTINGCHANGE)) { [weak self] _, _ in
            // The taskbar went light or dark: the mark changes colour.
            self?.renderedMenuBar = nil
            self?.sync()
            return nil
        }
        renderedMenuBar = nil
        sync()
    }

    func remove() {
        tearDown()
        icon.remove()
    }

    /// "Installed" for `breakpoint doctor`, or why not.
    var diagnostics: String? {
        icon.isInstalled ? nil : "The notification-area icon could not be added (Explorer is not running?)."
    }

    /// The icon's rectangle in DIPs of its monitor, for the tour's pointer.
    var iconFrame: (RectF, Monitor)? {
        guard let rect = icon.rect, let monitor = Monitors.describe(MonitorFromRect([rect], DWORD(MONITOR_DEFAULTTONEAREST))) else { return nil }
        let s = monitor.scale
        return (RectF(x: Float(rect.left) / s, y: Float(rect.top) / s, width: Float(rect.right - rect.left) / s,
                      height: Float(rect.bottom - rect.top) / s), monitor)
    }

    func sync() {
        syncIcon()
        syncHotKey()
        if flyoutOpen { refreshFlyout() }
    }

    func tearDown() {
        closeFlyout()
        flyout?.destroy()
        flyout = nil
        stopCue()
        pulseTimer?.invalidate()
        pulseTimer = nil
        if let registeredHotKey { hotKeys.unregister(registeredHotKey.token) }
        registeredHotKey = nil
    }

    // MARK: The icon

    private var canMove: Bool { !Appearance.reduceMotion && !sessionLocked }

    private func syncIcon() {
        let menuBar = state.menuBar
        let pulses = menuBar.badge == .working && canMove
        if menuBar != renderedMenuBar {
            let previous = renderedMenuBar
            renderedMenuBar = menuBar
            renderedPulseStep = nil
            if let newCue = newCue(menuBar), previous != nil, canMove {
                startCue(newCue, menuBar: menuBar)
            } else if cue == nil || previous.map({ $0.mark != menuBar.mark || $0.badge != menuBar.badge }) ?? true {
                stopCue()
                render(pulseStep: pulses ? currentPulseStep() : nil)
            } else {
                // Only the text changed: let the movement finish.
                icon.update(tip: tooltip)
            }
        }
        updatePulseTimer(running: pulses && cue == nil)
    }

    private var tooltip: String {
        let menuBar = state.menuBar
        guard let text = menuBar.text, !text.isEmpty, !menuBar.tooltip.contains(text) else { return menuBar.tooltip }
        return "\(menuBar.tooltip) · \(text)"
    }

    private func render(pulseStep: Int?, pose: MarkPose = .rest, variant: MarkVariant? = nil, badge: MarkBadge? = nil) {
        let menuBar = state.menuBar
        let opacity = pulseStep.map { Float(0.4 + 0.6 * Double($0) / Double(Self.pulseSteps - 1)) } ?? 1
        let image = TrayIcon.makeIcon(variant: variant ?? menuBar.mark.variant, badge: badge ?? menuBar.badge,
                                      badgeOpacity: opacity, pose: pose)
        renderedPulseStep = pulseStep
        icon.update(icon: image, tip: tooltip)
    }

    private func newCue(_ menuBar: MenuBarState) -> MarkCue? {
        guard let event = menuBar.cue else { return nil }
        defer { lastCueID = event.id }
        guard event.id != lastCueID, state.now.timeIntervalSince(event.at) < 2 else { return nil }
        return event.cue
    }

    private static func duration(_ cue: MarkCue) -> TimeInterval {
        switch cue {
        case .settle: return 0.4
        case .lift: return 0.3
        case .fold: return 0.45
        }
    }

    private func startCue(_ newCue: MarkCue, menuBar: MenuBarState) {
        stopCue()
        // Settle draws the dot on its way out; fold starts from the two eyes.
        let variant: MarkVariant = newCue == .fold ? .idle : menuBar.mark.variant
        let badge: MarkBadge = newCue == .settle ? .working : menuBar.badge
        cue = (newCue, Date(), variant, badge)
        updatePulseTimer(running: false)
        cueTick()
        let timer = Timer.after(1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.cueTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cueTimer = timer
    }

    private func cueTick() {
        guard let playing = cue else { return stopCue() }
        let progress = Date().timeIntervalSince(playing.startedAt) / Self.duration(playing.cue)
        if progress >= 1 {
            stopCue()
            renderedMenuBar = nil
            sync()
            return
        }
        render(pulseStep: nil, pose: MarkMotion.pose(playing.cue, progress: progress), variant: playing.variant, badge: playing.badge)
    }

    private func stopCue() {
        cueTimer?.invalidate()
        cueTimer = nil
        cue = nil
    }

    private func updatePulseTimer(running: Bool) {
        if running, pulseTimer == nil {
            let timer = Timer.after(1.0 / 12, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    let step = self.currentPulseStep()
                    if step != self.renderedPulseStep { self.render(pulseStep: step) }
                }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            pulseTimer = timer
        } else if !running, let timer = pulseTimer {
            timer.invalidate()
            pulseTimer = nil
            if renderedPulseStep != nil { render(pulseStep: nil) }
        }
    }

    private func currentPulseStep() -> Int {
        let fraction = (StatusDot.pulseOpacity(at: Date()) - 0.4) / 0.6
        return min(Self.pulseSteps - 1, max(0, Int((fraction * Float(Self.pulseSteps - 1)).rounded())))
    }

    // MARK: Clicks and menu

    private func clicked() {
        // This click already closed the flyout (it deactivated first): don't reopen it.
        if let closedAt, Date().timeIntervalSince(closedAt) < 0.3 {
            self.closedAt = nil
            return
        }
        toggleFlyout()
    }

    private func showMenu(at point: POINT) {
        closeFlyout()
        guard let owner = SystemEvents.shared.hwnd else { return }
        var items: [NativeMenu.Item] = [.label(state.menuBar.tooltip)]
        if let reason = state.status.whyNotNow, reason.explainsADueBreak {
            items.append(.label("Why not now? " + Copy.whyNotNow(reason, now: state.now)))
        }
        items.append(.separator)
        items.append(.submenu("Take a break", breakItems()))
        if state.status.isPaused {
            items.append(.action("Resume now") { [actions] in actions.resume() })
        } else {
            items.append(.submenu("Pause", pauseItems()))
        }
        items.append(.separator)
        items.append(.action("Settings…") { [weak self] in self?.openSettings(nil) })
        items.append(.action("Quit Breakpoint") { [actions] in actions.quit() })
        NativeMenu.show(items, at: point, owner: owner, alignBottom: true)
    }

    private func breakItems() -> [NativeMenu.Item] {
        BreakKind.allCases.map { kind in
            .action("\(kind.menuTitle) · \(PopoverModel.lengthLabel(kind))") { [weak self] in
                self?.closeFlyout()
                self?.actions.startBreak(kind)
            }
        }
    }

    private func pauseItems() -> [NativeMenu.Item] {
        PauseDuration.allCases.map { duration in
            let title = duration == .untilTomorrow
                ? duration.menuTitle
                : "\(duration.menuTitle) · until \(TimeFormat.timeOfDay(duration.end(from: state.now)))"
            return .action(title) { [weak self] in self?.actions.pause(duration) }
        }
    }

    private func openSettings(_ pane: SettingsPane?) {
        closeFlyout()
        SettingsNavigator.pendingPane = pane
        actions.openSettings()
    }

    // MARK: The flyout

    var isFlyoutOpen: Bool { flyoutOpen }

    func toggleFlyout() { flyoutOpen ? closeFlyout() : showFlyout() }

    func showFlyout() {
        guard !flyoutOpen else { return }
        let window = flyout ?? makeFlyout()
        flyout = window
        flyoutOpen = true
        window.controls.focused = nil
        place(window)
        window.window.show(activate: true)
        actions.popoverVisibilityChanged(true)
        updateFlyoutTimer()
    }

    func closeFlyout() {
        guard flyoutOpen else { return }
        flyoutOpen = false
        closedAt = Date()
        flyout?.hide()
        flyoutTimer?.invalidate()
        flyoutTimer = nil
        actions.popoverVisibilityChanged(false)
    }

    private func makeFlyout() -> DrawnWindow {
        let window = DrawnWindow(style: .flyout)
        window.create(size: SizeF(width: FlyoutView.width, height: 400), owner: SystemEvents.shared.hwnd)
        window.content = { [weak self] canvas, controls in
            guard let self else { return }
            FlyoutView.draw(canvas, controls, self.state, handlers: self.handlers(window))
        }
        window.controls.onKey = { [weak self] key in
            guard let self else { return false }
            if Int32(key) == VK_ESCAPE {
                self.report(.escape)
                return true
            }
            return false
        }
        window.window.onActivate = { [weak self] active in
            guard let self, self.flyoutOpen, !active else { return }
            self.report(.clickOutside)
        }
        return window
    }

    private func handlers(_ window: DrawnWindow) -> FlyoutView.Handlers {
        var handlers = FlyoutView.Handlers()
        handlers.takeBreak = { [weak self, weak window] anchor in
            guard let self, let window else { return }
            self.menu(self.breakItems(), under: anchor, in: window)
        }
        handlers.pause = { [weak self, weak window] anchor in
            guard let self, let window else { return }
            self.menu(self.pauseItems(), under: anchor, in: window)
        }
        handlers.resume = { [actions] in actions.resume() }
        handlers.undo = { [actions] in actions.undoLastDecision() }
        handlers.connect = { [weak self] in self?.openSettings(.integrations) }
        handlers.menu = { [weak self, weak window] anchor in
            guard let self, let window else { return }
            self.menu([
                .action("Settings…") { [weak self] in self?.openSettings(nil) },
                .action("About Breakpoint") { [weak self] in self?.openSettings(.about) },
                .separator,
                .action("Quit Breakpoint") { [weak self] in
                    self?.closeFlyout()
                    self?.actions.quit()
                },
            ], under: anchor, in: window)
        }
        handlers.tourStrip = tourStrip
        return handlers
    }

    /// The tour's strip in the flyout (SPEC §3.12), set by the tour's coach.
    var tourStrip: ((Canvas?, Controls?, PointF, Float) -> Float)?

    private func menu(_ items: [NativeMenu.Item], under anchor: RectF, in window: DrawnWindow) {
        guard let hwnd = window.window.hwnd else { return }
        let s = window.window.scale
        var point = POINT(x: LONG(anchor.x * s), y: LONG(anchor.maxY * s + 4))
        ClientToScreen(hwnd, &point)
        NativeMenu.show(items, at: point, owner: hwnd)
    }

    private func refreshFlyout() {
        guard let window = flyout else { return }
        let height = FlyoutView.height(state, handlers: handlers(window))
        if abs(height - window.window.size.height) > 0.5 { place(window) }
        window.setNeedsDisplay()
        updateFlyoutTimer()
    }

    /// While an agent row's dot pulses, redraw at 15 frames a second (only while open).
    private func updateFlyoutTimer() {
        let pulsing = flyoutOpen && canMove && state.sessions.contains { $0.state == .working }
        if pulsing, flyoutTimer == nil {
            let timer = Timer.after(1.0 / 15, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.flyout?.setNeedsDisplay() }
            }
            RunLoop.main.add(timer, forMode: .common)
            flyoutTimer = timer
        } else if !pulsing {
            flyoutTimer?.invalidate()
            flyoutTimer = nil
        }
    }

    /// Above the taskbar at the icon, inside the work area with 12 DIPs to spare (or below a top
    /// taskbar, beside a side one).
    private func place(_ window: DrawnWindow) {
        let height = FlyoutView.height(state, handlers: handlers(window))
        let size = SizeF(width: FlyoutView.width, height: height)
        let anchor = icon.rect
        let monitor = anchor.flatMap { Monitors.describe(MonitorFromRect([$0], DWORD(MONITOR_DEFAULTTONEAREST))) }
            ?? Monitors.underPointer() ?? Monitors.primary()
        guard let monitor else { return }
        let s = monitor.scale
        let area = monitor.workAreaDIPs
        let gap: Float = 12
        var left: Int32 = 0, top: Int32 = 0, right: Int32 = 0, bottom: Int32 = 0
        let edge = bp_taskbar_edge(&left, &top, &right, &bottom)
        let iconMid = anchor.map { PointF(x: Float($0.left + $0.right) / 2 / s, y: Float($0.top + $0.bottom) / 2 / s) }
            ?? PointF(x: area.maxX - 120, y: area.maxY)
        var frame = RectF(x: 0, y: 0, width: size.width, height: size.height)
        switch edge {
        case 1: // top
            frame.x = iconMid.x - size.width / 2
            frame.y = area.y + gap
        case 0: // left
            frame.x = area.x + gap
            frame.y = iconMid.y - size.height / 2
        case 2: // right
            frame.x = area.maxX - gap - size.width
            frame.y = iconMid.y - size.height / 2
        default: // bottom
            frame.x = iconMid.x - size.width / 2
            frame.y = area.maxY - gap - size.height
        }
        frame.x = min(max(frame.x, area.x + gap), area.maxX - gap - size.width)
        frame.y = min(max(frame.y, area.y + gap), area.maxY - gap - size.height)
        window.window.place(frame, on: monitor)
    }

    private func report(_ cause: PopoverCloseCause) {
        guard flyoutOpen else { return }
        actions.popoverMayClose(cause, pointerOnFlyout)
    }

    private var pointerOnFlyout: Bool {
        guard let hwnd = flyout?.window.hwnd else { return false }
        var cursor = POINT()
        GetCursorPos(&cursor)
        var rect = RECT()
        GetWindowRect(hwnd, &rect)
        return PtInRect(&rect, cursor)
    }

    // MARK: The popover shortcut

    private func syncHotKey() {
        let wanted = state.settings.popoverHotkey
        if registeredHotKey?.combo == wanted { return }
        if wanted == nil { refusedHotKey = nil }
        if let registered = registeredHotKey {
            hotKeys.unregister(registered.token)
            registeredHotKey = nil
        }
        guard let wanted, wanted != refusedHotKey else { return }
        if let token = hotKeys.register(wanted, action: { [weak self] in self?.toggleFlyout() }) {
            registeredHotKey = (wanted, token)
            refusedHotKey = nil
        } else {
            refusedHotKey = wanted
        }
    }
}
