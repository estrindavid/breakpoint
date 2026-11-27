import BreakpointCore
import BreakpointRuntime
import Foundation
import WinSDK

/// Shows the nudge card while `state.nudge` is in phase `.offer` or `.autoStartCard` (SPEC §3.1):
/// the Windows counterpart of the macOS `NudgePanelController`.
///
/// - Presents through `PopupStack` with priority `.nudge`; never takes focus.
/// - The ignore timer: 10 s without interaction → `actions.ignoreNudge()` (hover holds it;
///   leaving restarts it at 5 s). Not during auto-start (the coordinator runs that countdown);
///   when auto-start is cancelled back to an offer, the 10 s start afresh. Never for the tour's
///   sample nudge, which waits for Start or Not now.
/// - Hovering during auto-start calls `actions.cancelAutoStart()`.
/// - While the card shows and `nudge.hotkeysEnabled`, registers Ctrl+Alt+Win+B (Start) and
///   Ctrl+Alt+Win+. (Not now) with `HotKeys`; releases them when it goes.
/// - Start → `acceptNudge`; Not now (and the ×) → `declineNudge`, after `cancelAutoStart` during
///   auto-start.
/// - When the phase becomes `.countdownChip` the card goes and `CountdownChipController` takes
///   over at the pointer (no morph on Windows: the card leaves with DWM's own transition).
@MainActor
final class NudgeController: SurfaceController {
    private let state: AppState
    private let actions: AppActions
    private let stack: PopupStack
    private let hotKeys: HotKeys
    private var window: DrawnWindow?
    private var hover: PopupHover?
    private var shown: NudgeState?
    private var ignoreTimer: Timer?
    private var hotKeyTokens: [HotKeys.Token] = []
    private var hotKeysWanted = false
    private var evicted = false
    /// The ring as drawn: eases over each 0.1 s engine step (`BreakTiming.autoStartRingStep`).
    private var ring: (from: Double, to: Double, at: Date)?
    /// The subtitle ↔ why-now cross-fade (0.2 s).
    private var fade: (from: Float, to: Float, at: Date)?
    private var size = SizeF(width: 0, height: 0)
    private var shownTour: TourPresentation?

    /// The tour's coach line under its sample nudge (SPEC §3.12), set by the tour: draws at the
    /// origin and width given and returns its height (nil canvas: measure only).
    var tourCaption: ((Canvas?, Controls?, PointF, Float) -> Float)?

    init(state: AppState, actions: AppActions, stack: PopupStack, hotKeys: HotKeys) {
        self.state = state
        self.actions = actions
        self.stack = stack
        self.hotKeys = hotKeys
    }

    func sync() {
        guard let nudge = state.nudge, nudge.phase != .countdownChip else {
            if shown != nil { hide() }
            return
        }
        if shown?.id != nudge.id {
            if shown != nil { hide() }
            show(nudge)
            return
        }
        guard let previous = shown, !evicted else { return }
        if previous != nudge {
            shown = nudge
            if previous.autoStartProgress != nudge.autoStartProgress { stepRing(to: nudge.autoStartProgress) }
            // The shortcut setting changed while the card shows: follow it now.
            if nudge.hotkeysEnabled != hotKeysWanted {
                if nudge.hotkeysEnabled { registerHotKeys() } else { unregisterHotKeys() }
            }
            if previous.phase != nudge.phase {
                // Auto-start cancelled back to an ordinary offer: it stays its full 10 s.
                if previous.phase == .autoStartCard, nudge.phase == .offer, !(hover?.inside ?? false) {
                    restartIgnoreTimer(after: Timing.nudgeIgnoreAfter)
                }
            }
            refresh()
        } else if nudge.isRehearsal, state.tour != shownTour {
            shownTour = state.tour
            refresh()
        }
    }

    func tearDown() {
        hide()
    }

    // MARK: Show and hide

    private func show(_ nudge: NudgeState) {
        shown = nudge
        shownTour = state.tour
        evicted = false
        ring = nudge.autoStartProgress.map { ($0, $0, Date()) }
        fade = nil
        let window = DrawnWindow(style: .popup)
        let hover = PopupHover(window)
        hover.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        hover.onChange = { [weak self] in self?.revealChanged() }
        self.hover = hover
        self.window = window
        window.content = { [weak self] canvas, controls in
            guard let self, let nudge = self.shown else { return }
            PopupNudgeView.draw(canvas, controls, nudge, look: self.look(), handlers: self.handlers(nudge))
            self.updateAnimating()
        }
        size = SizeF(width: PopupNudgeView.width, height: PopupNudgeView.height(nudge, look: look(), handlers: handlers(nudge)))
        window.create(size: size, owner: SystemEvents.shared.hwnd)
        stack.present(window.window, id: nudge.id, size: size, priority: .nudge)
        // A nudge can lose its place at once to two higher-priority cards (SPEC §3.0).
        hover.park()
        if !stack.ids.contains(nudge.id) {
            evicted = true
            return
        }
        // The tour's sample nudge waits for Start or Not now (SPEC §3.12).
        if nudge.phase == .offer, !nudge.isRehearsal { restartIgnoreTimer(after: Timing.nudgeIgnoreAfter) }
        if nudge.hotkeysEnabled { registerHotKeys() }
        updateAnimating()
    }

    private func hide() {
        ignoreTimer?.invalidate()
        ignoreTimer = nil
        unregisterHotKeys()
        hover?.cancel()
        hover = nil
        if let id = shown?.id { stack.dismiss(id) }
        window?.destroy()
        window = nil
        shown = nil
        ring = nil
        fade = nil
    }

    private func refresh() {
        guard let window, let nudge = shown else { return }
        let height = PopupNudgeView.height(nudge, look: look(), handlers: handlers(nudge))
        if abs(height - size.height) > 0.5 {
            size = SizeF(width: PopupNudgeView.width, height: height)
            stack.resize(nudge.id, to: size)
        }
        window.setNeedsDisplay()
        updateAnimating()
    }

    // MARK: Drawing state

    private func look(at date: Date = Date()) -> PopupNudgeView.Look {
        var look = PopupNudgeView.Look()
        look.revealed = hover?.revealed ?? false
        look.whyNow = fadeValue(at: date)
        look.ring = ringValue(at: date)
        return look
    }

    private func handlers(_ nudge: NudgeState) -> PopupNudgeView.Handlers {
        var handlers = PopupNudgeView.Handlers()
        handlers.start = { [actions] in actions.acceptNudge() }
        handlers.notNow = { [weak self] in self?.notNow() }
        handlers.close = { [weak self] in self?.notNow() }
        if nudge.isRehearsal { handlers.tourCaption = tourCaption }
        return handlers
    }

    private func notNow() {
        if state.nudge?.phase == .autoStartCard { actions.cancelAutoStart() }
        actions.declineNudge()
    }

    private func stepRing(to progress: Double?) {
        guard let progress else { return ring = nil }
        let current = ringValue(at: Date()) ?? progress
        ring = (current, progress, Date())
    }

    private func ringValue(at date: Date) -> Double? {
        guard let ring else { return nil }
        if Appearance.reduceMotion { return ring.to }
        let t = min(1, max(0, date.timeIntervalSince(ring.at) / 0.1))
        return ring.from + (ring.to - ring.from) * t
    }

    private func fadeValue(at date: Date) -> Float {
        guard let fade else { return (hover?.revealed ?? false) ? 1 : 0 }
        return Tween(from: fade.from, to: fade.to, duration: 0.2, start: fade.at).value(at: date)
    }

    private func revealChanged() {
        let target: Float = (hover?.revealed ?? false) ? 1 : 0
        let current = fadeValue(at: Date())
        if current != target { fade = (current, target, Date()) }
        refresh()
    }

    /// Redraws every frame only while something moves: the ring easing to its next step, the
    /// subtitle cross-fade.
    private func updateAnimating() {
        guard let window else { return }
        let now = Date()
        let ringMoving = ring.map { !Appearance.reduceMotion && now.timeIntervalSince($0.at) < 0.1 && $0.from != $0.to } ?? false
        let fading = fade.map { now.timeIntervalSince($0.at) < 0.2 } ?? false
        if !fading { fade = nil }
        window.animating = ringMoving || fading
    }

    // MARK: Ignore timer and hover

    private func restartIgnoreTimer(after delay: TimeInterval) {
        ignoreTimer?.invalidate()
        let timer = Timer.after(delay, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in self?.timedOut() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ignoreTimer = timer
    }

    private func timedOut() {
        ignoreTimer = nil
        guard let nudge = state.nudge, nudge.id == shown?.id, nudge.phase == .offer, !(hover?.inside ?? false) else { return }
        // No fold-away to wait for: DWM's transition plays as the window hides.
        actions.ignoreNudge()
    }

    private func hoverChanged(_ inside: Bool) {
        guard let nudge = state.nudge, nudge.id == shown?.id else { return }
        if inside {
            ignoreTimer?.invalidate()
            ignoreTimer = nil
            if nudge.phase == .autoStartCard { actions.cancelAutoStart() }
        } else if nudge.phase == .offer, !nudge.isRehearsal {
            restartIgnoreTimer(after: Timing.nudgeIgnoreAfterHover)
        }
    }

    // MARK: Shortcuts (registered only while the nudge shows)

    private func registerHotKeys() {
        unregisterHotKeys()
        hotKeysWanted = true
        let accept = hotKeys.register(.nudgeStart) { [weak self] in self?.actions.acceptNudge() }
        let decline = hotKeys.register(.nudgeDismiss) { [weak self] in self?.notNow() }
        hotKeyTokens = [accept, decline].compactMap { $0 }
    }

    private func unregisterHotKeys() {
        hotKeysWanted = false
        for token in hotKeyTokens { hotKeys.unregister(token) }
        hotKeyTokens.removeAll()
    }
}
