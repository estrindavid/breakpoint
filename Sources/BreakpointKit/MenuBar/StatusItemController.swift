import AppKit
import QuartzCore
import SwiftUI
import BreakpointCore
import os
import BreakpointRuntime

// SPEC §3.7, §3.8.

/// The menu-bar status item and its popover.
///
/// Contract (beyond `SurfaceController`):
/// - `install()` creates the `NSStatusItem` (variable length) with the template mark; call once.
/// - `sync()` updates the image from `state.menuBar` (mark layer + badge layer, template images
///   from `BrandMark.templateImage`), the optional text, the tooltip and the accessibility label.
///   The working badge breathes at 0.5 Hz (static under Reduce Motion).
/// - Left click toggles the popover; right click (or Control-click) opens the menu: Take a break ▸
///   (kinds), Pause ▸ (30 min / 1 h / until tomorrow) or Resume now, Settings…, Quit.
///   Option-click shows "Why not now?": one line naming what Breakpoint is waiting for.
/// - `state.menuBar.cue` plays the mark's one-shot movements (settle, lift, fold) once each, as
///   template-image frames; never under Reduce Motion, or while the screen is locked or asleep.
/// - `showPopover()` / `togglePopover()` / `closePopover()` for the coordinator (onboarding opens
///   it once; the optional global shortcut toggles it).
/// - The popover hangs from a fixed 1 pt anchor placed under the mark when it opens, so it never
///   moves while open (the mark itself moves with a menu bar that slides away). While it is open,
///   whatever may close it (a click outside it, Esc, another app, a Space or display change, the
///   menu bar sliding away) goes to `actions.popoverMayClose`, and the coordinator decides (§3.8).
///   AppKit's `.transient` behaviour stays on, but it is not relied on: its closing is
///   unspecified, and it fails for an accessory app that `activate()` did not make active.
/// - `statusItemFrame` gives the item's screen frame (onboarding's arrow points at it); `nil` when
///   macOS is hiding the item (a full menu bar, or under the notch).
/// - `hotKeys`: set it to the app's `HotKeyCenter` to enable the optional popover shortcut
///   (`Settings.popoverHotkey`); without it the shortcut is not registered.
/// - `tearDown()` closes the popover and removes the item.
@MainActor
public final class StatusItemController: NSObject, SurfaceController, NSPopoverDelegate {
    private let state: AppState
    private let actions: AppActions
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let commands: PopoverCommands
    private var hosting: NSHostingController<AnyView>?
    private var renderedMenuBar: MenuBarState?
    private var renderedPulseStep: Int?
    private var pulseTimer: Timer?
    private var keyMonitor: Any?
    /// While the popover is open: what may close it (SPEC §3.8).
    private var dismissMonitors: [Any] = []
    private var dismissObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var anchorTimer: Timer?
    /// The mark's screen frame when the popover opened (nil: it hung from the display's top right),
    /// the screens then, and the last menu-bar state reported (gone, pointer on the popover).
    private var openedUnder: CGRect?
    private var screensAtOpen: [CGRect] = []
    private var reportedAnchor: (gone: Bool, pointerOn: Bool)?
    private var popoverClosedAt: Date?
    /// The app that was frontmost before the popover activated Breakpoint, to hand the keyboard
    /// back to when the popover closes by Esc, the shortcut or one of its commands.
    private var appBeforePopover: NSRunningApplication?
    private var reduceMotionObserver: NSObjectProtocol?
    /// Nobody can see the menu bar: the breathing badge stops (agents often work for hours while
    /// the screen is locked or the displays sleep, and every step redraws the status item).
    private var displaysAsleep = false
    private var screenLocked = false
    private var visibilityObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// The app's hotkey centre, for the optional popover shortcut. Set by the coordinator.
    public var hotKeys: HotKeyCenter? {
        didSet { syncHotKey() }
    }
    private var registeredHotKey: (combo: HotKeyCombo, token: HotKeyToken)?
    /// A combination another app holds: not retried on every sync, only when the setting changes.
    private var refusedHotKey: HotKeyCombo?

    /// The installed controller, so onboarding can point at the item's real position.
    static weak var current: StatusItemController?

    /// Opacity steps of the breathing badge (cached template images).
    private static let pulseSteps = 8
    private var imageCache: [String: NSImage] = [:]

    /// The mark's one-shot movements (§3.7): the id of the latest cue seen (played or not), and
    /// the one playing.
    private var lastCueID: Int?
    private var playingCue: (cue: MarkCue, startedAt: Date, frames: [NSImage])?
    private var cueTimer: Timer?
    /// The option-click menu's line, refreshed while the menu is open.
    private weak var whyNotNowItem: NSMenuItem?

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
        self.commands = PopoverCommands(state: state, actions: actions)
        super.init()
        commands.close = { [weak self] in self?.closePopover() }
    }

    public func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "BreakpointStatusItem"
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.wantsLayer = true
        }
        statusItem = item
        Self.current = self

        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        let root = PopoverView(state: state, actions: actions, commands: commands)
        let hosting = NSHostingController(rootView: AnyView(root))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.hosting = hosting
        commands.hostView = hosting.view

        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderedMenuBar = nil
                self?.sync()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let visibility: [(NotificationCenter, Notification.Name, (StatusItemController) -> Void)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, { $0.displaysAsleep = true }),
            (workspace, NSWorkspace.screensDidWakeNotification, { $0.displaysAsleep = false }),
            (distributed, Notification.Name("com.apple.screenIsLocked"), { $0.screenLocked = true }),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), { $0.screenLocked = false }),
        ]
        for (center, name, apply) in visibility {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                    self.sync()
                }
            }
            visibilityObservers.append((center, token))
        }
        renderedMenuBar = nil
        sync()
        DebugUIRunner.statusItemInstalled(self)
    }

    public var isPopoverShown: Bool { popover.isShown }

    /// The popover's window while shown, and its keyboard focus (development self-test).
    var popoverWindow: NSWindow? { popover.contentViewController?.view.window }
    var popoverFocus: PopoverFocusItem? { commands.focus }
    public var visibilityDiagnostics: String {
        guard let button = statusItem?.button, let window = button.window else { return "no window" }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screens = NSScreen.screens.map { "\($0.frame) inset \($0.safeAreaInsets.top) L\($0.auxiliaryTopLeftArea.map { "\($0)" } ?? "-") R\($0.auxiliaryTopRightArea.map { "\($0)" } ?? "-")" }
        return "frame \(frame) occlusion \(window.occlusionState.rawValue) visible \(window.isVisible) screens \(screens)"
    }

    /// The status item's frame in screen coordinates, if installed and visible.
    public var statusItemFrame: CGRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return Self.isVisible(frame, window: window) ? frame : nil
    }

    /// macOS hides status items that do not fit (a crowded menu bar, or under the camera notch):
    /// their window then sits off every screen, or inside the notch's dead zone. (Occlusion state
    /// is not used: on macOS 26 status-item windows belong to Control Center.)
    static func isVisible(_ frame: CGRect, window: NSWindow) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: 0, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY)) })
        else { return false }
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let midX = frame.midX
            return (midX >= left.minX && midX <= left.maxX) || (midX >= right.minX && midX <= right.maxX)
        }
        return true
    }

    public func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        commands.focus = nil
        let front = NSWorkspace.shared.frontmostApplication
        appBeforePopover = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
        // Never the button itself: NSPopover follows its anchor, and the mark moves (and leaves
        // the screen) with a menu bar that slides away. A fixed anchor where the mark is now keeps
        // the popover still; content changes only change its height, downward.
        openedUnder = statusItemFrame
        let anchor = fixedAnchor(under: openedUnder)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if openedUnder != nil { button.highlight(true) }
        popover.contentViewController?.view.window?.makeKey()
        installKeyMonitor()
        startWatchingForDismissal()
    }

    private var anchorPanel: NSPanel?

    /// A 1 pt transparent panel at the bottom of the mark (`itemFrame`), or, when macOS is hiding
    /// the item (a full menu bar, or under the notch), just under the menu bar 120 pt from the
    /// right edge of the display with the pointer. It ignores the mouse and is on every Space.
    private func fixedAnchor(under itemFrame: CGRect?) -> NSView {
        let frame: CGRect
        if let itemFrame {
            frame = CGRect(x: itemFrame.minX, y: itemFrame.minY, width: max(1, itemFrame.width), height: 1)
        } else {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
            let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
            frame = CGRect(x: screen.frame.maxX - 120, y: top - 2, width: 1, height: 1)
        }
        let panel = anchorPanel ?? {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
            return panel
        }()
        anchorPanel = panel
        panel.setFrame(frame, display: false)
        panel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
        panel.orderFrontRegardless()
        return panel.contentView!
    }

    // MARK: Closing (SPEC §3.8)

    /// Watches, while the popover is open, for everything that may close it. Nothing here needs a
    /// permission: a global monitor sees other apps' mouse clicks (only key events need
    /// Accessibility access), and the rest are workspace and application notifications.
    private func startWatchingForDismissal() {
        stopWatchingForDismissal()
        screensAtOpen = NSScreen.screens.map(\.frame)
        reportedAnchor = nil
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps, on the desktop and in the menu bar (other items, or the bar itself).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { self?.clicked(event) }
        }) {
            dismissMonitors.append(global)
        }
        // Clicks in Breakpoint's other windows (a pop-up card, Settings).
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { self?.clicked(event) }
            return event
        }) {
            dismissMonitors.append(local)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let own = ProcessInfo.processInfo.processIdentifier
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { controller, note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != own { controller.report(.otherAppActive) }
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { controller, _ in
            controller.report(.spaceChanged)
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { controller, _ in
            // Only a real change of displays; not the Dock or the menu bar changing the visible area.
            let screens = NSScreen.screens.map(\.frame)
            guard screens != controller.screensAtOpen else { return }
            controller.screensAtOpen = screens
            controller.report(.displayChanged)
        }
        let timer = Timer(timeInterval: Timing.popoverAnchorCheck, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAnchor() }
        }
        timer.tolerance = Timing.popoverAnchorCheck / 5
        RunLoop.main.add(timer, forMode: .common)
        anchorTimer = timer
    }

    private func stopWatchingForDismissal() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
        for (center, token) in dismissObservers { center.removeObserver(token) }
        dismissObservers.removeAll()
        anchorTimer?.invalidate()
        anchorTimer = nil
        reportedAnchor = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handle: @escaping @MainActor (StatusItemController, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                handle(self, note)
            }
        }
        dismissObservers.append((center, token))
    }

    private var popoverFrame: CGRect? { popoverWindow?.frame }

    private var pointerOnPopover: Bool {
        popoverFrame?.contains(NSEvent.mouseLocation) ?? false
    }

    private func report(_ cause: PopoverCloseCause) {
        guard popover.isShown else { return }
        actions.popoverMayClose(cause, pointerOnPopover)
    }

    /// A mouse-down anywhere. Inside the popover (or its menus) it is the person using it; on the
    /// mark, the mark's own action toggles the popover.
    private func clicked(_ event: NSEvent) {
        guard popover.isShown else { return }
        if let window = event.window {
            if window === popoverWindow || window === statusItem?.button?.window { return }
            // A menu opened from the popover runs its own loop; its windows never reach here.
        }
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        if let frame = popoverFrame, frame.contains(point) { return }
        if let mark = statusItemFrame, mark.insetBy(dx: -2, dy: -2).contains(point) { return }
        actions.popoverMayClose(.clickOutside, false)
    }

    /// The menu bar the popover hangs from slid away (a full-screen Space, or a menu bar that
    /// hides itself): the mark left the spot it was in when the popover opened. Reported when that,
    /// or the pointer's being on the popover, changes.
    private func checkAnchor() {
        guard popover.isShown, let opened = openedUnder else { return }
        let now = statusItemFrame
        let gone = now.map { abs($0.minY - opened.minY) > 2 } ?? true
        let pointerOn = pointerOnPopover
        defer { reportedAnchor = (gone, pointerOn) }
        guard gone, reportedAnchor.map({ !$0.gone || $0.pointerOn != pointerOn }) ?? true else { return }
        actions.popoverMayClose(.menuBarHidden, pointerOn)
    }

    public func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    public func togglePopover() { popover.isShown ? closePopover() : showPopover() }

    public func sync() {
        guard let button = statusItem?.button else { return }
        let menuBar = state.menuBar
        let pulses = menuBar.badge == .working && !reduceMotion && !displaysAsleep && !screenLocked
        if menuBar != renderedMenuBar {
            let previous = renderedMenuBar
            let stateChanged = previous.map { $0.mark != menuBar.mark || $0.badge != menuBar.badge } ?? false
            renderedMenuBar = menuBar
            renderedPulseStep = nil
            if let cue = newCue(menuBar), previous != nil, canMove {
                startCue(cue, menuBar: menuBar)
            } else if playingCue != nil, !stateChanged {
                // Only the text changed: let the movement finish.
            } else {
                stopCue()
                if stateChanged { fadeNextImage(button) }
                renderImage(pulseStep: pulses ? currentPulseStep() : nil)
            }
            button.attributedTitle = Self.title(menuBar.text)
            button.toolTip = menuBar.tooltip
            button.setAccessibilityLabel(Self.accessibilityLabel(menuBar))
        }
        updatePulseTimer(running: pulses && playingCue == nil)
        syncHotKey()
    }

    public func tearDown() {
        stopCue()
        pulseTimer?.invalidate()
        pulseTimer = nil
        removeKeyMonitor()
        stopWatchingForDismissal()
        popover.close()
        anchorPanel?.close()
        if let registeredHotKey { hotKeys?.unregister(registeredHotKey.token) }
        registeredHotKey = nil
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
        for (center, token) in visibilityObservers { center.removeObserver(token) }
        visibilityObservers.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    // MARK: Image, text and accessibility

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func renderImage(pulseStep: Int?) {
        guard let menuBar = renderedMenuBar, let button = statusItem?.button else { return }
        let opacity = pulseStep.map { Self.pulseOpacity(step: $0) } ?? 1
        let key = "\(menuBar.mark.rawValue)-\(menuBar.badge)-\(pulseStep ?? -1)"
        let image = imageCache[key] ?? {
            let image = BrandMark.templateImage(menuBar.mark.variant, badge: menuBar.badge, badgeOpacity: opacity)
            imageCache[key] = image
            return image
        }()
        button.image = image
        renderedPulseStep = pulseStep
    }

    /// A 0.2 s cross-fade for the next image change (state changes only, not the breathing badge).
    private func fadeNextImage(_ button: NSStatusBarButton) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = Theme.Motion.reduceMotionFade
        button.layer?.add(transition, forKey: "breakpoint.state")
    }

    static func title(_ text: String?) -> NSAttributedString {
        guard let text, !text.isEmpty else { return NSAttributedString(string: "") }
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        return NSAttributedString(string: " \(text)", attributes: [.font: font, .baselineOffset: 0])
    }

    static func accessibilityLabel(_ menuBar: MenuBarState) -> String {
        var sentence = "Breakpoint. \(menuBar.tooltip)"
        if menuBar.badge == .working, !menuBar.tooltip.localizedCaseInsensitiveContains("working") {
            sentence += ". An agent is working"
        }
        return sentence
    }

    // MARK: One-shot movements (§3.7)

    /// Nobody would see it, or the person asked for less motion: the mark changes without moving.
    private var canMove: Bool { !reduceMotion && !displaysAsleep && !screenLocked }

    /// The menu bar's cue if it was not seen before (each cue plays at most once). A cue older than
    /// a couple of seconds is stale: its moment has passed.
    private func newCue(_ menuBar: MenuBarState) -> MarkCue? {
        guard let event = menuBar.cue else { return nil }
        defer { lastCueID = event.id }
        guard event.id != lastCueID, state.now.timeIntervalSince(event.at) < 2 else { return nil }
        return event.cue
    }

    private func startCue(_ cue: MarkCue, menuBar: MenuBarState) {
        stopCue()
        let duration = Theme.Motion.markCueDuration(cue)
        let count = max(2, Int((duration * Theme.Motion.markFrameRate).rounded()) + 1)
        // Settle draws the dot on its way out; fold starts from the two eyes.
        let variant: BrandMark.Variant = cue == .fold ? .idle : menuBar.mark.variant
        let badge: BrandMark.Badge = cue == .settle ? .working : menuBar.badge
        let frames = MarkMotion.keyFrames(cue, count: count).enumerated().map { index, pose in
            cachedImage("\(cue.rawValue)-\(variant)-\(badge)-\(index)/\(count)") {
                BrandMark.templateImage(variant, badge: badge, pose: pose)
            }
        }
        playingCue = (cue, Date(), frames)
        updatePulseTimer(running: false)
        statusItem?.button?.image = frames[0]
        let timer = Timer(timeInterval: 1 / Theme.Motion.markFrameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cueTick() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        cueTimer = timer
    }

    private func cueTick() {
        guard let playing = playingCue else { return stopCue() }
        let duration = Theme.Motion.markCueDuration(playing.cue)
        let progress = Date().timeIntervalSince(playing.startedAt) / duration
        if progress >= 1 {
            stopCue()
            renderImage(pulseStep: nil)
            sync()
            return
        }
        let index = min(playing.frames.count - 1, Int(progress * Double(playing.frames.count - 1)))
        statusItem?.button?.image = playing.frames[index]
    }

    private func stopCue() {
        cueTimer?.invalidate()
        cueTimer = nil
        playingCue = nil
    }

    private func cachedImage(_ key: String, make: () -> NSImage) -> NSImage {
        if let image = imageCache[key] { return image }
        let image = make()
        imageCache[key] = image
        return image
    }

    // MARK: Breathing badge (0.5 Hz, static under Reduce Motion)

    private func updatePulseTimer(running: Bool) {
        if running, pulseTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pulseTick() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            pulseTimer = timer
        } else if !running, let timer = pulseTimer {
            timer.invalidate()
            pulseTimer = nil
            if renderedPulseStep != nil { renderImage(pulseStep: nil) }
        }
    }

    private func pulseTick() {
        let step = currentPulseStep()
        if step != renderedPulseStep { renderImage(pulseStep: step) }
    }

    private func currentPulseStep() -> Int {
        let opacity = StatusDot.pulseOpacity(at: Date())          // 0.4…1.0
        let fraction = (opacity - 0.4) / 0.6
        return min(Self.pulseSteps - 1, max(0, Int((fraction * Double(Self.pulseSteps - 1)).rounded())))
    }

    static func pulseOpacity(step: Int) -> Double {
        0.4 + 0.6 * Double(step) / Double(pulseSteps - 1)
    }

    // MARK: Popover shortcut

    private func syncHotKey() {
        guard let hotKeys else { return }
        let wanted = state.settings.popoverHotkey
        if registeredHotKey?.combo == wanted { return }
        if wanted == nil { refusedHotKey = nil }
        if let registered = registeredHotKey {
            hotKeys.unregister(registered.token)
            registeredHotKey = nil
        }
        guard let wanted, wanted != refusedHotKey else { return }
        if let token = hotKeys.register(wanted, handler: { [weak self] in self?.togglePopover() }) {
            registeredHotKey = (wanted, token)
            refusedHotKey = nil
        } else {
            refusedHotKey = wanted
        }
    }

    // MARK: Clicks and menu

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return togglePopover() }
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            closePopover()
            showMenu()
        } else if event.modifierFlags.contains(.option) {
            closePopover()
            showWhyNotNow()
        } else if let closedAt = popoverClosedAt, Date().timeIntervalSince(closedAt) < 0.25 {
            // This click already closed the transient popover; don't reopen it.
            popoverClosedAt = nil
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        let menu = makeMenu()
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Option-click (§3.7 "Why not now?"): one line saying what Breakpoint is waiting for, kept
    /// true while the menu is open (the coordinator re-derives it every tick).
    private func showWhyNotNow() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Why not now?", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let line = NSMenuItem(title: whyNotNowLine, action: nil, keyEquivalent: "")
        menu.addItem(line)
        whyNotNowItem = line
        let refresh = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let line = self.whyNotNowItem else { return }
                let text = self.whyNotNowLine
                if line.title != text { line.title = text }
            }
        }
        RunLoop.main.add(refresh, forMode: .common)
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
        refresh.invalidate()
    }

    private var whyNotNowLine: String {
        state.status.whyNotNow.map { Copy.whyNotNow($0, now: state.now) } ?? state.menuBar.tooltip
    }

    /// The right-click menu: the status sentence, Take a break ▸, Pause ▸ (or Resume now),
    /// Settings…, Quit.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: state.menuBar.tooltip, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let reason = state.status.whyNotNow, reason.explainsADueBreak {
            let why = NSMenuItem(title: Copy.whyNotNow(reason, now: state.now), action: nil, keyEquivalent: "")
            why.isEnabled = false
            menu.addItem(why)
        }
        menu.addItem(.separator())

        let breakItem = NSMenuItem(title: "Take a break", action: nil, keyEquivalent: "")
        breakItem.submenu = commands.breakMenu()
        menu.addItem(breakItem)
        if state.status.isPaused {
            menu.addItem(ClosureMenuItem(title: "Resume now") { [actions] in actions.resume() })
        } else {
            let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
            pauseItem.submenu = commands.pauseMenu()
            menu.addItem(pauseItem)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { [commands] in commands.openSettings() })
        menu.addItem(ClosureMenuItem(title: "Quit Breakpoint", keyEquivalent: "q") { [actions] in actions.quit() })
        return menu
    }

    // MARK: Keyboard (← → Tab move, Return / Space activate, ⌘, settings, ⌘Q quit)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.popover.isShown,
                      event.window === self.popover.contentViewController?.view.window else { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Handles a key press in the popover; returns true if it was used.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case ",": commands.openSettings(); return true
            case "q": commands.quit(); return true
            case "w": closePopover(); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 123, 126: commands.moveFocus(-1); return true                       // ← ↑
        case 124, 125: commands.moveFocus(1); return true                        // → ↓
        case 48: commands.moveFocus(modifiers.contains(.shift) ? -1 : 1); return true  // Tab
        case 36 where state.tour?.step == .popover && commands.focus == nil,         // the tour's Next
             76 where state.tour?.step == .popover && commands.focus == nil:
            actions.tour(.next); return true
        case 36, 76, 49: commands.activateFocused(); return true                 // Return, Enter, Space
        case 53: actions.popoverMayClose(.escape, true); return true              // Esc
        default: return false
        }
    }

    // MARK: NSPopoverDelegate

    public func popoverWillShow(_ notification: Notification) {
        // However it opens (a click, the shortcut, the coordinator): its first-use hint (SPEC §3.12).
        actions.popoverVisibilityChanged(true)
    }

    public func popoverWillClose(_ notification: Notification) {
        // At the start of the close, not its end: a click on the mark that AppKit's transient
        // behaviour turns into a close must not reopen it while the close animates.
        popoverClosedAt = Date()
    }

    public func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        // Its hint goes; during the tour's look at it, the tour moves on to its last card (§3.12).
        actions.popoverVisibilityChanged(false)
        commands.focus = nil
        removeKeyMonitor()
        stopWatchingForDismissal()
        openedUnder = nil
        statusItem?.button?.highlight(false)
        anchorPanel?.orderOut(nil)
        // Opening the popover activated Breakpoint. Closed by a click elsewhere, the clicked app
        // is already active; closed any other way, Breakpoint would stay active with no window
        // and every keystroke would go nowhere until the user clicked back into their editor.
        let previous = appBeforePopover
        appBeforePopover = nil
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.handBackKeyboard(to: previous) }
        }
    }

    private func handBackKeyboard(to app: NSRunningApplication?) {
        guard let app, !app.isTerminated, NSApp.isActive, !popover.isShown else { return }
        // A break that started from the popover hands focus back itself when it ends.
        guard state.activeBreak == nil else { return }
        // Settings, onboarding or an alert opened from the popover keep the keyboard.
        let ownWindowNeedsKeys = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeKey && !(window is NSPanel) && window.level == .normal
        }
        guard !ownWindowNeedsKeys, NSApp.modalWindow == nil else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }
}
