import BreakpointCore
import BreakpointRuntime
import Foundation
import WinSDK

/// Shows the break overlay while `state.activeBreak != nil` (SPEC §3.3, §3.4): the Windows
/// counterpart of the Mac's `BreakOverlayController`.
///
/// - One full-screen, topmost `.overlay` window per display. The display under the pointer when
///   the break starts gets the break; the others the backdrop and a small timer, unless "Show the
///   full break on every display". A display change rebuilds the windows for the new set.
/// - The break's window takes the keyboard (`OverlayFocus.take`); when the break ends the window
///   that had it gets it back (`OverlayFocus.restore`), unless the person switched apps.
/// - Fades in and out over `Theme.Duration.overlayFade` (the window's opacity), the content first
///   on the way out; Reduce Motion: 0.25 s in, 0.2 s out.
/// - Redraws only on change: a state tick (once a second), hover, a key. It runs the 60 Hz clock
///   only while something moves (a fade, the Skip guard's 3 s, the breathing ring, a paced `move`
///   step, the closing moment, the Esc pulse, a step or chip transition); the working dot of the
///   agent chip pulses at 15 frames a second. Under Reduce Motion nothing moves continuously.
/// - Keys (handled before `Controls`, so Return means the primary as on the Mac): Esc once pulses
///   the hint, twice within 1.2 s skips (or finishes once Skip reads Done; a preview closes on one
///   Esc); Enter triggers the mint primary, else Done once available; Tab / Shift+Tab move the
///   focus; ← / → step the routine on `move` (else move the focus); Space activates the focused
///   control. Every other key is swallowed. Alt+F4 cannot close an overlay.
///
/// Safety: a backstop closes the windows 2 s after the hard ceiling if the coordinator has not
/// ended the break; `watchdog` ends the process if the main thread stops for 3 s while the
/// overlay is up; display changes, unlock and wake re-front the windows.
@MainActor
public final class OverlayController: SurfaceController {
    private let state: AppState
    private let actions: AppActions
    /// `--debug-stall-main N`: blocks the main thread for N seconds once, a second into the next
    /// overlay (the watchdog test, SPEC §7.3).
    public var debugStallSeconds: TimeInterval?
    /// The hang guard; the shell may set its `logURL` and `relaunchExecutable`.
    public let watchdog = OverlayWatchdog()

    private let focus = OverlayFocus()
    private var screens: [OverlayScreen] = []
    /// What is drawn: the last `ActiveBreakState`, kept through the exit.
    private var display: ActiveBreakState?
    private var shownID: UUID?
    private var closedByBackstop: Set<UUID> = []
    private var exitStart: Date?
    private var fade: Tween?
    private var focused: OverlayControl?
    private var lastEscape: Date?
    private var escPulseStart: Date?
    private var stepChange: (text: OverlayStepText, start: Date)?
    private var chipChange: (chip: AgentChipState, start: Date)?
    private var ambient: (from: Float, to: Float, start: Date) = (0, 0, .distantPast)
    private var heartbeatTimer: Timer?
    private var backstopTimer: Timer?
    private var pulseTimer: Timer?
    private var clockRunning = false
    private var reduceMotion = false
    private var highContrast = false

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
        // SystemEvents has no unsubscribe: these are registered once and ignore messages while
        // no overlay shows.
        SystemEvents.shared.on(UInt32(WM_DISPLAYCHANGE)) { [weak self] _, _ in
            self?.displaysChanged()
            return nil
        }
        SystemEvents.shared.on(UInt32(WM_WTSSESSION_CHANGE)) { [weak self] wParam, _ in
            if wParam == 8 { self?.reassert() }  // WTS_SESSION_UNLOCK
            return nil
        }
        SystemEvents.shared.on(UInt32(WM_POWERBROADCAST)) { [weak self] wParam, _ in
            if wParam == 0x12 { self?.reassert() }  // PBT_APMRESUMEAUTOMATIC
            return nil
        }
    }

    /// The overlay windows on screen (diagnostics).
    public var windowCount: Int { screens.count }
    /// True from the entrance until the exit has finished.
    public var isShowing: Bool { shownID != nil }

    // MARK: SurfaceController

    public func sync() {
        guard let active = state.activeBreak, !closedByBackstop.contains(active.id) else {
            if shownID != nil, exitStart == nil { beginExit() }
            return
        }
        if shownID != active.id {
            if shownID != nil { closeNow(restoreFocus: false) }
            begin(active)
            return
        }
        guard exitStart == nil, let previous = display, previous != active else { return }
        display = active
        react(from: previous, to: active)
        redraw(timerChanged: timerText(previous) != timerText(active) || previous.ambient != active.ambient
               || previous.fullOnAllDisplays != active.fullOnAllDisplays)
        updateClock()
    }

    public func tearDown() {
        closeNow(restoreFocus: false)
    }

    // MARK: Show

    private func begin(_ active: ActiveBreakState) {
        reduceMotion = Appearance.reduceMotion
        highContrast = Appearance.highContrast
        focus.record()
        let now = Date()
        display = active
        shownID = active.id
        exitStart = nil
        lastEscape = nil
        escPulseStart = nil
        stepChange = nil
        chipChange = nil
        let ambientValue: Float = OverlayView.isAmbient(active) ? 1 : 0
        ambient = (ambientValue, ambientValue, .distantPast)
        focused = OverlayControls.hasPrimary(active) ? .primary : nil
        fade = Tween(from: 0, to: 1, duration: reduceMotion ? 0.25 : Theme.Duration.overlayFade, start: now)
        buildWindows()
        watchdog.start()
        let heartbeat = Timer(timeInterval: OverlayMetrics.heartbeatInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.watchdog.heartbeat() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        heartbeatTimer = heartbeat
        let backstop = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.checkCeiling() }
        }
        RunLoop.main.add(backstop, forMode: .common)
        backstopTimer = backstop
        if let stall = debugStallSeconds {
            debugStallSeconds = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                FileHandle.standardError.write(Data("Debug stall: blocking the main thread for \(stall) s\n".utf8))
                Thread.sleep(forTimeInterval: stall)
            }
        }
        updateClock()
    }

    /// One window per display; the break's display last, so it ends up with the keyboard.
    private func buildWindows() {
        for screen in screens { screen.window.destroy() }
        screens.removeAll()
        let monitors = Monitors.all()
        guard !monitors.isEmpty else { return }
        let pointer = Monitors.underPointer()
        let mainHandle = monitors.first { $0 == pointer }?.handle ?? monitors[0].handle
        let ordered = monitors.filter { $0.handle != mainHandle } + monitors.filter { $0.handle == mainHandle }
        for monitor in ordered {
            let screen = OverlayScreen(monitor: monitor, isMain: monitor.handle == mainHandle)
            configure(screen)
            screens.append(screen)
        }
        let opacity = fade?.value() ?? 1
        for screen in screens {
            screen.window.opacity = opacity
            screen.place()
            screen.window.window.show(activate: screen.isMain)
            screen.place()
        }
        if let main = mainScreen, let hwnd = main.window.window.hwnd {
            if let active = display {
                SetWindowTextW(hwnd, Copy.breakStartedAnnouncement(title: active.title, length: active.plannedLength).wide)
            }
            if focused != nil { main.window.controls.debugShowFocus() }
            OverlayFocus.take(hwnd)
        }
    }

    private var mainScreen: OverlayScreen? { screens.first { $0.isMain } }

    private func configure(_ screen: OverlayScreen) {
        let drawn = screen.window
        drawn.background = nil
        drawn.content = { [weak self, weak screen] canvas, controls in
            guard let self, let screen else { return }
            self.draw(screen, canvas, controls)
        }
        let window = drawn.window
        window.onClose = { false }
        window.onDPIChange = { [weak screen] in screen?.place() }
        window.onMessage = { [weak self] message, wParam, lParam in
            guard let self else { return nil }
            switch Int32(message) {
            case WM_KEYDOWN:
                let isRepeat = (lParam >> 30) & 1 == 1
                return self.handleKey(UInt32(wParam), isRepeat: isRepeat) ? 0 : nil
            case WM_TIMER where wParam == Self.heartbeatTimerID:
                self.watchdog.heartbeat()
                return 0
            default:
                return nil
            }
        }
        // The watchdog's heartbeat also comes from a Win32 timer: Foundation timers only run in
        // `MessageLoop`, not inside a modal loop (a native menu, a window being dragged), while
        // WM_TIMER is dispatched there too, so a menu held open is never taken for a hang. The
        // timer goes with the window.
        if let hwnd = window.hwnd {
            SetTimer(hwnd, Self.heartbeatTimerID, UINT(OverlayMetrics.heartbeatInterval * 1000), nil)
        }
    }

    private static let heartbeatTimerID: WPARAM = 0xB0B

    private func draw(_ screen: OverlayScreen, _ canvas: Canvas, _ controls: Controls) {
        guard let active = display else { return }
        let now = Date()
        var p = OverlayPresentation(liveElapsed: liveElapsed(active, at: now))
        p.showsContent = screen.isMain || active.fullOnAllDisplays
        p.focused = focused
        p.reduceMotion = reduceMotion
        p.highContrast = highContrast
        p.dotOpacity = reduceMotion ? 1 : StatusDot.pulseOpacity(at: now)
        if let start = escPulseStart {
            let t = now.timeIntervalSince(start) / OverlayMetrics.escPulseDuration
            if t >= 0, t < 1 { p.hintPulse = Float(1 - 0.5 * sin(.pi * t)) }
        }
        if let exitStart {
            let t = now.timeIntervalSince(exitStart)
            p.contentOpacity = reduceMotion ? 1 : Float(1 - OverlayCurve.easeOut(t / OverlayMetrics.overlayExitContent))
        }
        p.ambient = ambientValue(at: now)
        let transition = reduceMotion ? OverlayMetrics.reduceMotionFade : OverlayMetrics.moveStepDuration
        if let change = stepChange {
            p.stepChange = (change.text, Float(OverlayCurve.easeInOut(now.timeIntervalSince(change.start) / transition)))
        }
        if let change = chipChange {
            let duration = reduceMotion ? OverlayMetrics.reduceMotionFade : OverlayMetrics.agentChipColour
            p.chipChange = (change.chip, Float(OverlayCurve.easeInOut(now.timeIntervalSince(change.start) / duration)))
        }
        controls.focused = focused.map(OverlayView.controlID)
        OverlayView.draw(canvas, controls, active, p, handlers: handlers())
    }

    private func handlers() -> OverlayView.Handlers {
        var handlers = OverlayView.Handlers()
        handlers.skip = { [weak self] in self?.activate(.skip) }
        handlers.done = { [weak self] in self?.activate(.skip) }
        handlers.extend = { [weak self] in self?.activate(.extend) }
        handlers.primary = { [weak self] in self?.activate(.primary) }
        handlers.skipTour = { [actions] in actions.tour(.skip) }
        return handlers
    }

    /// Seconds since the break started at frame precision: the coordinator's `startedAt` is on the
    /// same wall clock, never less than what the state says.
    private func liveElapsed(_ active: ActiveBreakState, at date: Date) -> TimeInterval {
        max(active.elapsed, date.timeIntervalSince(active.startedAt))
    }

    private func ambientValue(at date: Date) -> Float {
        let duration = reduceMotion ? OverlayMetrics.reduceMotionFade : OverlayMetrics.ambientWake
        let t = Float(OverlayCurve.easeOut(date.timeIntervalSince(ambient.start) / duration))
        return ambient.from + (ambient.to - ambient.from) * t
    }

    /// The other displays' timer text (they redraw only when it changes).
    private func timerText(_ active: ActiveBreakState) -> String {
        active.kind == .walk ? DurationFormat.clock(active.elapsed, rounding: .down) : DurationFormat.clock(active.remaining)
    }

    private func redraw(timerChanged: Bool = true) {
        for screen in screens where screen.isMain || timerChanged || (display?.fullOnAllDisplays ?? false) {
            screen.window.setNeedsDisplay()
        }
    }

    // MARK: Changes while showing

    private func react(from previous: ActiveBreakState, to active: ActiveBreakState) {
        let now = Date()
        if active.needsYou, !previous.needsYou {
            focused = .primary
            mainScreen?.window.controls.debugShowFocus()
        }
        if let step = active.step, let before = previous.step, step.index != before.index {
            stepChange = (OverlayStepText(previous), now)
        }
        if active.agentChip.tone != previous.agentChip.tone {
            chipChange = (previous.agentChip, now)
        }
        let target: Float = OverlayView.isAmbient(active) ? 1 : 0
        if target != ambient.to {
            ambient = (ambientValue(at: now), target, now)
        }
        let controls = OverlayControls.controls(for: active)
        if let current = focused, !controls.contains(current) {
            focused = OverlayControls.hasPrimary(active) ? .primary : nil
        }
        if previous.ambient, !active.ambient, OverlayControls.hasPrimary(active) {
            focused = .primary
        }
        if let hwnd = mainScreen?.window.window.hwnd, active.title != previous.title {
            SetWindowTextW(hwnd, active.title.wide)
        }
    }

    // MARK: Keys

    /// True when the key was used (or swallowed).
    private func handleKey(_ key: UInt32, isRepeat: Bool) -> Bool {
        guard let active = display, exitStart == nil else { return true }
        let code = Int32(key)
        if active.completion != nil {
            // The closing moment: Esc or Enter ends it at once (the break is already recorded).
            if !isRepeat, code == VK_ESCAPE || code == VK_RETURN { actions.finishBreak(.done) }
            return true
        }
        switch code {
        case VK_ESCAPE:
            if !isRepeat { escape(active) }
        case VK_RETURN:
            if !isRepeat { enter(active) }
        case VK_TAB:
            moveFocus(active, by: GetKeyState(Int32(VK_SHIFT)) < 0 ? -1 : 1)
        case VK_RIGHT:
            if active.kind == .move { actions.stepRoutine(1) } else { moveFocus(active, by: 1) }
        case VK_LEFT:
            if active.kind == .move { actions.stepRoutine(-1) } else { moveFocus(active, by: -1) }
        case VK_SPACE:
            if !isRepeat, let focused { activate(focused) }
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
            } else if liveElapsed(active, at: now) >= active.skipEnabledAt {
                actions.skipBreak()
            } else {
                pulseHint()
            }
            return
        }
        lastEscape = now
        pulseHint()
    }

    private func enter(_ active: ActiveBreakState) {
        if OverlayControls.hasPrimary(active) {
            activate(.primary)
        } else if active.doneAvailable {
            actions.finishBreak(.done)
        } else {
            pulseHint()
        }
    }

    private func pulseHint() {
        escPulseStart = Date()
        updateClock()
    }

    private func moveFocus(_ active: ActiveBreakState, by delta: Int) {
        guard !OverlayView.isAmbient(active) else { return }
        let controls = OverlayControls.controls(for: active)
        guard !controls.isEmpty else { return }
        if let current = focused, let index = controls.firstIndex(of: current) {
            focused = controls[(index + delta + controls.count) % controls.count]
        } else {
            focused = delta > 0 ? controls.first : controls.last
        }
        mainScreen?.window.controls.debugShowFocus()
        mainScreen?.window.setNeedsDisplay()
    }

    private func activate(_ control: OverlayControl) {
        guard let active = display, exitStart == nil else { return }
        switch control {
        case .skip:
            if active.doneAvailable {
                actions.finishBreak(.done)
            } else if liveElapsed(active, at: Date()) >= active.skipEnabledAt || active.isPreview {
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

    // MARK: The clock

    /// Something on screen moves with the clock at `date` (60 Hz while true).
    private func needsLiveClock(at date: Date) -> Bool {
        guard let active = display else { return false }
        if let fade, !fade.isDone(at: date) { return true }
        if exitStart != nil { return true }
        if let completion = active.completion {
            return !OverlayCompletionFrame.isSettled(liveElapsed(active, at: date) - completion.at, reduceMotion: reduceMotion)
        }
        if let start = escPulseStart, date.timeIntervalSince(start) < OverlayMetrics.escPulseDuration + 0.05 { return true }
        let transition = reduceMotion ? OverlayMetrics.reduceMotionFade : OverlayMetrics.moveStepDuration
        if let change = stepChange, date.timeIntervalSince(change.start) < transition + 0.05 { return true }
        if let change = chipChange, date.timeIntervalSince(change.start) < OverlayMetrics.agentChipColour + 0.05 { return true }
        if date.timeIntervalSince(ambient.start) < OverlayMetrics.ambientWake + 0.05 { return true }
        if !active.isPreview, liveElapsed(active, at: date) < active.skipEnabledAt + 0.1 { return true }
        guard !reduceMotion else { return false }
        let ownsMain = mainScreen != nil
        if ownsMain, active.kind == .breathe { return true }
        if ownsMain, active.kind == .move, let step = active.step, !step.step.tempo.isEmpty { return true }
        return false
    }

    /// Starts or stops the 60 Hz clock and the dot's slower pulse to match what moves.
    private func updateClock() {
        let now = Date()
        if needsLiveClock(at: now) {
            if !clockRunning {
                clockRunning = true
                FrameClock.shared.run(self) { [weak self] in self?.tick() ?? false }
            }
        }
        let pulses = !reduceMotion && !clockRunning && exitStart == nil && (display?.agentChip.isWorking ?? false)
        if pulses, pulseTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.mainScreen?.window.setNeedsDisplay() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pulseTimer = timer
        } else if !pulses {
            pulseTimer?.invalidate()
            pulseTimer = nil
        }
    }

    /// One frame: the fade, then a redraw of what moves. False stops the clock.
    private func tick() -> Bool {
        let now = Date()
        if let fade {
            let value = fade.value(at: now)
            for screen in screens { screen.window.opacity = value }
            if fade.isDone(at: now) { self.fade = nil }
        }
        if let exitStart {
            let duration = reduceMotion ? OverlayMetrics.reduceMotionFade : Theme.Duration.overlayFade
            if now.timeIntervalSince(exitStart) >= duration + 0.05 {
                clockRunning = false
                closeNow(restoreFocus: true)
                return false
            }
        }
        let moving = needsLiveClock(at: now)
        if exitStart != nil || display?.fullOnAllDisplays == true {
            for screen in screens { screen.window.setNeedsDisplay() }
        } else {
            mainScreen?.window.setNeedsDisplay()
        }
        if !moving {
            clockRunning = false
            // The last frame settles everything; the slower dot pulse may take over.
            updateClock()
        }
        return moving
    }

    // MARK: Exit

    private func beginExit() {
        guard exitStart == nil else { return }
        let now = Date()
        exitStart = now
        focused = nil
        let from = fade?.value(at: now) ?? 1
        fade = Tween(from: from, to: 0, duration: reduceMotion ? OverlayMetrics.reduceMotionFade : Theme.Duration.overlayFade,
                     start: now)
        pulseTimer?.invalidate()
        pulseTimer = nil
        if !clockRunning {
            clockRunning = true
            FrameClock.shared.run(self) { [weak self] in self?.tick() ?? false }
        }
    }

    private func closeNow(restoreFocus: Bool) {
        let wasShowing = shownID != nil
        FrameClock.shared.cancel(self)
        clockRunning = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        backstopTimer?.invalidate()
        backstopTimer = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        watchdog.stop()
        // Give the keyboard back while the overlay still has it (Windows lets the foreground
        // process choose), then remove the windows.
        if wasShowing, restoreFocus { focus.restore() } else { focus.forget() }
        for screen in screens { screen.window.destroy() }
        screens.removeAll()
        shownID = nil
        display = nil
        exitStart = nil
        fade = nil
        focused = nil
        stepChange = nil
        chipChange = nil
        escPulseStart = nil
        lastEscape = nil
    }

    // MARK: Safety

    private func checkCeiling() {
        guard let active = display, exitStart == nil else { return }
        guard Date().timeIntervalSince(active.startedAt) > OverlayMetrics.ceiling(for: active) + OverlayMetrics.ceilingBackstopGrace else {
            return
        }
        FileHandle.standardError.write(Data("Overlay passed its hard ceiling without the break ending; closing it\n".utf8))
        closedByBackstop.insert(active.id)
        beginExit()
    }

    /// Displays were connected, removed, rearranged or resized: rebuild when the set changed.
    private func displaysChanged() {
        guard shownID != nil, exitStart == nil else { return }
        if !sameDisplays(Monitors.all(), screens.map { $0.monitor }) { buildWindows() }
        // Monitor details can settle a moment after the broadcast: look once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.recheckDisplays() }
        }
    }

    private func recheckDisplays() {
        guard shownID != nil, exitStart == nil else { return }
        if !sameDisplays(Monitors.all(), screens.map { $0.monitor }) { buildWindows() }
    }

    /// After unlock or wake: the windows to the front, the break's window focused again.
    private func reassert() {
        guard shownID != nil else { return }
        watchdog.heartbeat()
        recheckDisplays()
        for screen in screens { screen.place() }
        if exitStart == nil, let hwnd = mainScreen?.window.window.hwnd { OverlayFocus.take(hwnd) }
    }
}

/// Two monitor lists describe the same displays at the same places and scales.
private func sameDisplays(_ a: [Monitor], _ b: [Monitor]) -> Bool {
    a.count == b.count && a.allSatisfy { m in
        b.contains { $0.handle == m.handle && $0.scale == m.scale && $0.frame.left == m.frame.left && $0.frame.top == m.frame.top
            && $0.frame.right == m.frame.right && $0.frame.bottom == m.frame.bottom }
    }
}

/// One display's overlay window.
@MainActor
final class OverlayScreen {
    let monitor: Monitor
    let isMain: Bool
    let window: DrawnWindow

    init(monitor: Monitor, isMain: Bool) {
        self.monitor = monitor
        self.isMain = isMain
        window = DrawnWindow(style: .overlay)
        // Created on its own display, so the window starts at that display's scale.
        let system = Float(GetDpiForSystem()) / 96
        let f = monitor.frame
        window.window.create(frame: RectF(x: Float(f.left) / system, y: Float(f.top) / system,
                                          width: Float(f.right - f.left) / system, height: Float(f.bottom - f.top) / system))
    }

    /// Covers the whole display (taskbar included), topmost, in physical pixels.
    func place() {
        guard let hwnd = window.window.hwnd else { return }
        let f = monitor.frame
        SetWindowPos(hwnd, HWNDInsert.topmost, f.left, f.top, f.right - f.left, f.bottom - f.top, UINT(SWP_NOACTIVATE))
    }
}
