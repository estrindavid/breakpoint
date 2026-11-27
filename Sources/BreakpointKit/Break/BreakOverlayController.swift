import AppKit
import SwiftUI
import os
import BreakpointCore

// SPEC §3.3.

private let overlayLog = Logger(subsystem: BreakpointVersion.bundleIdentifier, category: "overlay")

/// Shows the break overlay while `state.activeBreak != nil`.
///
/// Contract (beyond `SurfaceController`):
/// - One borderless `NSPanel` per display at `.screenSaver` level, `[.canJoinAllSpaces,
///   .fullScreenAuxiliary]`, `.nonactivatingPanel`, `sharingType = .none`; the active display's
///   panel becomes key without activating the app. Rebuild on
///   `NSApplication.didChangeScreenParametersNotification`.
/// - Calls `focusRestorer.recordFrontmost()` before showing and `restore()` after the exit.
/// - Starts the watchdog while visible and stamps `watchdog.heartbeat()` every 0.5 s.
/// - Keyboard: Esc once pulses the hint; Esc twice within 1.2 s → `actions.skipBreak()` (after the
///   3 s guard); Return → the primary; → / ← → `actions.stepRoutine(±1)` on `move`.
/// - Exit when `activeBreak` becomes nil: content fades 0.2 s, then backdrop 0.4 s.
/// - `debugStallSeconds`: when set (launch argument `--debug-stall-main N`), blocks the main thread
///   for N seconds once, during the next overlay (watchdog test, SPEC §7.3).
///
/// Safety, in layers:
/// 1. Keys are handled by an event monitor owned by this controller, not by the SwiftUI content,
///    so Esc Esc works even if the content never renders.
/// 2. A backstop timer closes the windows `BreakTiming.ceilingBackstopGrace` after the hard
///    ceiling if the coordinator has not ended the break (it records the outcome itself).
/// 3. The watchdog exits the process if the main thread stops for 3 s; process exit removes
///    every window. A crash does the same.
/// 4. Display changes, wake, unlock and returning to the session rebuild or re-front the windows.
///
/// Keys while the overlay is up: Esc (single pulses the hint, double skips — or finishes when Skip
/// has become Done; a preview closes on one Esc), Return (the mint primary: Back to work /
/// I'm back; else Done once available), Tab / Shift-Tab (focus), ← / → (previous / next step on
/// `move`; focus elsewhere), Space (activate the focused control). Every other key is swallowed so
/// nothing beeps; ⌘-combinations pass through.
@MainActor
public final class BreakOverlayController: SurfaceController {
    private let state: AppState
    private let actions: AppActions
    private let focusRestorer: FocusRestorer
    private let watchdog: OverlayWatchdog
    public var debugStallSeconds: TimeInterval?

    let model = OverlayModel()
    private var panels: [OverlayPanel] = []
    private var activeDisplayID: CGDirectDisplayID?
    private var shownID: UUID?
    private var closedByBackstop: Set<UUID> = []
    private var keyMonitor: Any?
    private var heartbeatTimer: Timer?
    private var backstopTimer: Timer?
    private var exitWork: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var activity: NSObjectProtocol?
    private var lastEscape: Date?
    private var lastNeedsYou = false
    private var lastStepIndex: Int?

    public init(state: AppState, actions: AppActions, focusRestorer: FocusRestorer, watchdog: OverlayWatchdog) {
        self.state = state
        self.actions = actions
        self.focusRestorer = focusRestorer
        self.watchdog = watchdog
    }

    /// The overlay windows currently on screen (diagnostics and the demo).
    public var windowCount: Int { panels.count }
    /// True while the active display's overlay window is key.
    public var isKey: Bool { panels.contains { $0.isKeyWindow } }

    public func sync() {
        guard let active = state.activeBreak, !closedByBackstop.contains(active.id) else {
            if shownID != nil, model.exitStart == nil { beginExit() }
            return
        }
        if shownID != active.id {
            if shownID != nil { closeNow(restoreFocus: false) }
            begin(active)
            return
        }
        if model.exitStart != nil { return }
        let previous = model.display
        model.display = active
        reactToChanges(from: previous, to: active)
    }

    public func tearDown() {
        closeNow(restoreFocus: false)
    }

    // MARK: Demo and review hooks

    /// Holds the staged entrance at `t` seconds (nil resumes normal playback). For reviewing the
    /// entrance step by step on real windows; while held, ← / → step by 0.05 s.
    public func holdEntrance(at t: TimeInterval?) {
        model.entranceHold = t.map { max(0, $0) }
    }

    // MARK: Show

    private func begin(_ active: ActiveBreakState) {
        exitWork?.cancel()
        focusRestorer.recordFrontmost()
        activeDisplayID = ActiveDisplay.screen().flatMap(ActiveDisplay.displayID)
        model.reset(active, now: Date())
        model.focused = defaultFocus(for: active)
        lastEscape = nil
        lastNeedsYou = active.needsYou
        lastStepIndex = active.step?.index
        shownID = active.id
        buildPanels()
        installKeyMonitor()
        installObservers()
        watchdog.start()
        let heartbeat = Timer(timeInterval: BreakTiming.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdog.heartbeat() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        heartbeatTimer = heartbeat
        let backstop = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCeiling() }
        }
        RunLoop.main.add(backstop, forMode: .common)
        backstopTimer = backstop
        // Keep the app out of App Nap while the overlay is up (timers must stay on time), without
        // holding off display or system sleep (SPEC §3.4: never blocks display sleep).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Break overlay on screen")
        Announcer.announce(Copy.breakStartedAnnouncement(title: active.title, length: active.plannedLength))
        if let stall = debugStallSeconds {
            debugStallSeconds = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                overlayLog.notice("Debug stall: blocking the main thread for \(stall, privacy: .public) s")
                Thread.sleep(forTimeInterval: stall)
            }
        }
    }

    private func buildPanels() {
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        let screens = NSScreen.screens
        if let id = activeDisplayID, ActiveDisplay.screen(withID: id) == nil {
            activeDisplayID = ActiveDisplay.screen().flatMap(ActiveDisplay.displayID)
        }
        for screen in screens {
            let isActive = ActiveDisplay.displayID(screen) == activeDisplayID
            let panel = OverlayPanel(screen: screen, isActive: isActive)
            let host = OverlayHost(model: model, actions: actions, displaySize: screen.frame.size,
                                   isActive: isActive, safeAreaTop: ActiveDisplay.safeAreaTop(of: screen))
            let hosting = OverlayHostingView(rootView: host)
            hosting.sizingOptions = []
            hosting.frame = CGRect(origin: .zero, size: screen.frame.size)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            panel.onKey = { [weak self] event in
                guard let self else { return false }
                return self.handleKey(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift),
                                      command: event.modifierFlags.contains(.command), isRepeat: event.isARepeat)
            }
            panel.setFrame(screen.frame, display: false)
            panels.append(panel)
        }
        for panel in panels { panel.orderFrontRegardless() }
        makeActiveKey()
    }

    private func makeActiveKey() {
        guard let panel = panels.first(where: \.isActiveDisplay) ?? panels.first else { return }
        panel.isActiveDisplay = true
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Changes while showing

    private func reactToChanges(from previous: ActiveBreakState?, to active: ActiveBreakState) {
        if active.needsYou && !lastNeedsYou {
            model.focused = .primary
            let agent: String
            if case .needsYou(let name) = active.agentChip { agent = name } else { agent = "Your agent" }
            Announcer.announce(Copy.needsYou(agent: agent))
        }
        lastNeedsYou = active.needsYou
        if let step = active.step, step.index != lastStepIndex {
            if lastStepIndex != nil {
                Announcer.announce("Step \(step.index + 1) of \(step.count): \(step.step.title)")
            }
            lastStepIndex = step.index
        }
        let controls = OverlayPresentation.controls(for: active)
        if let focused = model.focused, !controls.contains(focused) {
            model.focused = defaultFocus(for: active)
        }
        if previous?.ambient == true && !active.ambient, OverlayPresentation.hasPrimary(active) {
            model.focused = .primary
        }
    }

    private func defaultFocus(for active: ActiveBreakState) -> OverlayControl? {
        OverlayPresentation.hasPrimary(active) ? .primary : nil
    }

    // MARK: Keys

    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = event.keyCode
            let shift = event.modifierFlags.contains(.shift)
            let command = event.modifierFlags.contains(.command)
            let isRepeat = event.isARepeat
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.shownID != nil else { return false }
                // Keys aimed at another of our windows (Settings, a wind-down card) are theirs.
                if windowNumber > 0, let window = NSApp.window(withWindowNumber: windowNumber), !(window is OverlayPanel) {
                    return false
                }
                return self.handleKey(keyCode: keyCode, shift: shift, command: command, isRepeat: isRepeat)
            }
            return handled ? nil : event
        }
    }

    @discardableResult
    private func handleKey(keyCode: UInt16, shift: Bool, command: Bool, isRepeat: Bool) -> Bool {
        guard let active = model.display, model.exitStart == nil else { return false }
        if command { return false }
        if let held = model.entranceHold {
            switch keyCode {
            case KeyCode.rightArrow: model.entranceHold = held + 0.05; return true
            case KeyCode.leftArrow: model.entranceHold = max(0, held - 0.05); return true
            case KeyCode.escape: break
            default: return true
            }
        }
        if active.completion != nil {
            // The closing moment: Esc or Return ends it at once (the break is already recorded).
            if !isRepeat, [KeyCode.escape, KeyCode.returnKey, KeyCode.enter].contains(keyCode) {
                actions.finishBreak(.done)
            }
            return true
        }
        switch keyCode {
        case KeyCode.escape:
            if !isRepeat { escape(active) }
        case KeyCode.returnKey, KeyCode.enter:
            if !isRepeat { returnKey(active) }
        case KeyCode.tab:
            moveFocus(active, by: shift ? -1 : 1)
        case KeyCode.rightArrow:
            if active.kind == .move { actions.stepRoutine(1) } else { moveFocus(active, by: 1) }
        case KeyCode.leftArrow:
            if active.kind == .move { actions.stepRoutine(-1) } else { moveFocus(active, by: -1) }
        case KeyCode.space:
            if !isRepeat, let focused = model.focused { activate(focused, active) }
        default:
            break
        }
        return true
    }

    private func escape(_ active: ActiveBreakState) {
        let now = Date()
        if active.isPreview {
            actions.skipBreak()
            return
        }
        if let last = lastEscape, now.timeIntervalSince(last) <= Timing.doubleEscInterval {
            lastEscape = nil
            if active.doneAvailable {
                actions.finishBreak(.done)
            } else if model.liveElapsed(at: now) >= active.skipEnabledAt {
                actions.skipBreak()
            } else {
                model.escPulseStart = now
            }
            return
        }
        lastEscape = now
        model.escPulseStart = now
    }

    private func returnKey(_ active: ActiveBreakState) {
        if OverlayPresentation.hasPrimary(active) {
            activate(.primary, active)
        } else if active.doneAvailable {
            actions.finishBreak(.done)
        } else {
            model.escPulseStart = Date()
        }
    }

    private func moveFocus(_ active: ActiveBreakState, by delta: Int) {
        guard !active.ambient else { return }
        let controls = OverlayPresentation.controls(for: active)
        guard !controls.isEmpty else { return }
        guard let current = model.focused, let index = controls.firstIndex(of: current) else {
            model.focused = delta > 0 ? controls.first : controls.last
            return
        }
        model.focused = controls[(index + delta + controls.count) % controls.count]
    }

    private func activate(_ control: OverlayControl, _ active: ActiveBreakState) {
        switch control {
        case .skip:
            if active.doneAvailable {
                actions.finishBreak(.done)
            } else if model.liveElapsed(at: Date()) >= active.skipEnabledAt || active.isPreview {
                actions.skipBreak()
            }
        case .extend:
            if active.canExtend { actions.extendBreak() }
        case .primary:
            if active.needsYou {
                actions.finishBreak(.backToWork)
            } else if active.kind == .walk {
                actions.finishBreak(.imBack)
            }
        }
    }

    // MARK: Exit

    private func beginExit() {
        guard model.exitStart == nil else { return }
        let now = Date()
        model.exitStart = now
        model.focused = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let reduceMotion = SystemMotion.reduceMotion
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.closeNow(restoreFocus: true) }
        }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayFrame.exitDuration(reduceMotion: reduceMotion) + 0.05,
                                      execute: work)
    }

    private func closeNow(restoreFocus: Bool) {
        exitWork?.cancel()
        exitWork = nil
        let wasShowing = shownID != nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        backstopTimer?.invalidate()
        backstopTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        watchdog.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        shownID = nil
        model.clear()
        guard wasShowing else { return }
        if restoreFocus {
            focusRestorer.restore()
            Announcer.announce(Copy.breakOverAnnouncement)
        }
    }

    // MARK: Safety

    private func checkCeiling() {
        guard let active = model.display, model.exitStart == nil else { return }
        let age = Date().timeIntervalSince(active.startedAt)
        guard age > BreakTiming.ceiling(for: active) + BreakTiming.ceilingBackstopGrace else { return }
        overlayLog.error("Overlay passed its hard ceiling without the break ending; closing it")
        closedByBackstop.insert(active.id)
        beginExit()
    }

    private func installObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(app, NSApplication.didChangeScreenParametersNotification) { $0.screensChanged() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.reassert() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.reassert() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.reassert() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.reassert() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.reassert() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (BreakOverlayController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    /// Displays were connected, disconnected, rearranged or resized (also lid close): rebuild.
    private func screensChanged() {
        guard shownID != nil else { return }
        let current = Set(NSScreen.screens.compactMap(ActiveDisplay.displayID))
        let shown = Set(panels.compactMap(\.displayID))
        let framesMatch = panels.allSatisfy { panel in
            NSScreen.screens.first { ActiveDisplay.displayID($0) == panel.displayID }?.frame == panel.frame
        }
        if current != shown || !framesMatch {
            overlayLog.info("Displays changed during a break; rebuilding the overlay windows")
            buildPanels()
        }
    }

    /// After wake, unlock, a session switch back, or a Space change: windows to the front, the
    /// active one key again, and any display change picked up.
    private func reassert() {
        guard shownID != nil else { return }
        watchdog.heartbeat()
        screensChanged()
        for panel in panels { panel.orderFrontRegardless() }
        if model.exitStart == nil { makeActiveKey() }
    }
}

// MARK: - Model

/// The overlay's own state: what to draw (the last `ActiveBreakState`, kept through the exit),
/// the entrance / exit clock, focus and the Esc pulse.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var display: ActiveBreakState?
    @Published var entranceStart: Date?
    @Published var exitStart: Date?
    @Published var focused: OverlayControl?
    @Published var escPulseStart: Date?
    /// Entrance frozen at this time (review step-through).
    @Published var entranceHold: TimeInterval?
    /// Local clock reading when `display` was last set, against the coordinator's `elapsed`.
    private var elapsedAnchor: (elapsed: TimeInterval, at: Date)?

    func reset(_ active: ActiveBreakState, now: Date) {
        display = active
        entranceStart = now
        exitStart = nil
        escPulseStart = nil
        focused = nil
        elapsedAnchor = (active.elapsed, now)
    }

    func clear() {
        display = nil
        entranceStart = nil
        exitStart = nil
        escPulseStart = nil
        focused = nil
        entranceHold = nil
        elapsedAnchor = nil
    }

    /// Seconds since the break started, at frame precision. The coordinator's `startedAt` is on the
    /// same wall clock, so this is simply now − startedAt, never less than what the state says.
    func liveElapsed(at date: Date) -> TimeInterval {
        guard let display else { return 0 }
        return max(display.elapsed, date.timeIntervalSince(display.startedAt))
    }

    /// True while something on screen moves with the clock (entrance, exit, Skip guard, pulse).
    func needsLiveClock(at date: Date) -> Bool {
        guard let display else { return false }
        if entranceHold != nil { return false }
        if exitStart != nil { return true }
        // The closing moment of a completed break draws its ring and check from the clock.
        if display.completion != nil { return true }
        if let start = entranceStart, date.timeIntervalSince(start) < BreakTiming.overlayLiveClockWindow { return true }
        if date.timeIntervalSince(display.startedAt) < display.skipEnabledAt + 0.1 { return true }
        if let pulse = escPulseStart, date.timeIntervalSince(pulse) < Theme.Motion.escPulseDuration + 0.05 { return true }
        return false
    }

    func presentation(at date: Date, reduceMotion: Bool, safeAreaTop: CGFloat) -> OverlayPresentation {
        var frame = OverlayFrame.settled
        if let exitStart {
            frame = OverlayFrame.exit(at: date.timeIntervalSince(exitStart), reduceMotion: reduceMotion)
        } else if let hold = entranceHold {
            frame = OverlayFrame.entrance(at: hold, reduceMotion: reduceMotion)
        } else if let entranceStart {
            frame = OverlayFrame.entrance(at: date.timeIntervalSince(entranceStart), reduceMotion: reduceMotion)
        }
        var pulse = 1.0
        if let start = escPulseStart {
            let p = date.timeIntervalSince(start) / Theme.Motion.escPulseDuration
            if p >= 0 && p < 1 { pulse = 1 - 0.5 * sin(.pi * p) }
        }
        return OverlayPresentation(frame: frame, focused: focused, hintPulse: pulse, safeAreaTop: safeAreaTop,
                                   liveElapsed: liveElapsed(at: date))
    }
}

/// The overlay for one display, bound to the controller's model and clock.
struct OverlayHost: View {
    @ObservedObject var model: OverlayModel
    let actions: AppActions
    let displaySize: CGSize
    let isActive: Bool
    let safeAreaTop: CGFloat
    private let traits = DesignTraits()

    var body: some View {
        if let active = model.display {
            TimelineView(.animation(minimumInterval: nil, paused: !model.needsLiveClock(at: Date()))) { context in
                BreakOverlayView(activeBreak: active, actions: actions, displaySize: displaySize,
                                 showsContent: isActive || active.fullOnAllDisplays, now: active.startedAt.addingTimeInterval(active.elapsed),
                                 presentation: model.presentation(at: context.date, reduceMotion: traits.reduceMotion,
                                                                  safeAreaTop: safeAreaTop))
            }
        }
    }
}

/// Clicks anywhere make the overlay key (useful after the user clicked another app's window
/// through Mission Control or a notification).
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let window, !window.isKeyWindow, window.canBecomeKey { window.makeKey() }
        super.mouseDown(with: event)
    }
}

/// One display's overlay window.
final class OverlayPanel: NSPanel {
    var isActiveDisplay: Bool
    let displayID: CGDirectDisplayID?
    /// Key presses that reach the window without passing the event monitor.
    var onKey: ((NSEvent) -> Bool)?

    init(screen: NSScreen, isActive: Bool) {
        isActiveDisplay = isActive
        displayID = ActiveDisplay.displayID(screen)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        // Esc Esc, Skip and the primary must work even while an app-modal alert is open (the
        // overlay covers it; without this the break could not be dismissed until its timer ran out).
        worksWhenModal = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { isActiveDisplay }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc that reached the responder chain (the monitor normally consumes it first).
        if let event = NSApp.currentEvent, event.type == .keyDown { _ = onKey?(event) }
    }

    /// Never let the system move the overlay off its display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
