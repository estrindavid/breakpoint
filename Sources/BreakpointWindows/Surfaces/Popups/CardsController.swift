import BreakpointCore
import BreakpointRuntime
import Foundation
import WinSDK

/// Shows every card of `state.cards` (SPEC §3.5, §3.6, §2.11), each in its own pop-up window
/// through `PopupStack` at `CardState.priority`: the Windows counterpart of the macOS
/// `CardPanelSurface` and the resume, away-note, toast, wind-down and update controllers.
///
/// - Auto-hide is timed here, as on the Mac (the surface, not the coordinator): a `CardCountdown`
///   of `CardState.autoHideAfter` runs from arrival, is held while the pointer is on the card and
///   resumes with at least half when it leaves; the time rim draws the same countdown; at the
///   deadline the card goes and `actions.dismissCard` is called. Cards with no auto-hide (a
///   needs-you resume card, the wind-down, an update in progress, the tour's sample card) stay
///   until answered; one that starts hiding itself later gets its countdown then.
/// - ×, a click anywhere on a resume card, Later, Close and Done → `dismissCard`; Resume on the
///   call-pause toast → `resume` then `dismissCard`; Undo on the away note → `undoLastDecision`;
///   Update → `installUpdate`; Download page → `openUpdate`; Wrap up → `windDownWrapUp`;
///   "15 more minutes" → `windDownExtend` once its hold completes; Copy note → `copyWrapUpNote`.
/// - A card the coordinator removes, or one `PopupStack` evicts, simply goes.
/// - The resume card's dismiss shortcut (Ctrl+Alt+Win+., the nudge's Not now) while a resume
///   card shows and the nudge shortcuts are on, never while the nudge card holds those keys.
/// - The wind-down card takes the keyboard once clicked into (as the Mac's becomes key): Return
///   wraps up (or copies the note), Esc closes the note, Ctrl+C copies it, Space held holds
///   "15 more minutes". The other cards never take focus.
@MainActor
final class CardsController: SurfaceController {
    private let state: AppState
    private let actions: AppActions
    private let stack: PopupStack
    private let hotKeys: HotKeys
    private var live: [UUID: Live] = [:]
    private var rimTimer: Timer?
    private var rimTimerInterval: TimeInterval = 0
    private var dismissToken: HotKeys.Token?
    private var dismissRefused = false
    private var showsDismissKey = false
    private var shownTour: TourPresentation?

    /// The tour's coach line under its sample resume card (SPEC §3.12), set by the tour: draws at
    /// the origin and width given and returns its height (nil canvas: measure only).
    var tourCaption: ((Canvas?, Controls?, PointF, Float) -> Float)?

    @MainActor
    final class Live {
        let id: UUID
        var card: CardState
        let window: DrawnWindow
        let hover: PopupHover
        var size = SizeF(width: 0, height: 0)
        var rim: PopupRimTimeline?
        var timer: Timer?
        var evicted = false
        // The wind-down card.
        var isKey = false
        var holdStart: Date?
        var holdRelease: (from: Double, at: Date)?
        var holdTimer: Timer?
        var copiedUntil: Date?
        var copiedTimer: Timer?
        /// The pointer just released a hold: the capsule's click that follows is not another act.
        var releasedByPointer = false

        init(card: CardState, window: DrawnWindow, hover: PopupHover) {
            id = card.id
            self.card = card
            self.window = window
            self.hover = hover
        }
    }

    init(state: AppState, actions: AppActions, stack: PopupStack, hotKeys: HotKeys) {
        self.state = state
        self.actions = actions
        self.stack = stack
        self.hotKeys = hotKeys
    }

    func sync() {
        let cards = state.cards
        let ids = Set(cards.map(\.id))
        for (id, card) in live where !ids.contains(id) { remove(card) }
        let tourChanged = state.tour != shownTour
        shownTour = state.tour
        for card in cards {
            guard let existing = live[card.id] else {
                show(card)
                continue
            }
            if existing.evicted { continue }
            if !stack.ids.contains(card.id) {
                // Pushed out by a higher-priority pop-up; the coordinator drops it next.
                existing.evicted = true
                stopTimers(existing)
                continue
            }
            if existing.card != card || (tourChanged && card.isRehearsal) {
                existing.card = card
                refresh(existing)
            }
            if existing.rim == nil, let full = card.autoHideAfter {
                startCountdown(existing, full: full)
            } else if existing.rim != nil, card.autoHideAfter == nil {
                // It stays now (an update that started installing): no timeout, no rim.
                existing.rim = nil
                existing.timer?.invalidate()
                existing.timer = nil
                existing.window.setNeedsDisplay()
            }
        }
        syncHotKey()
        updateRimTimer()
    }

    func tearDown() {
        for card in live.values {
            stopTimers(card)
            stack.dismiss(card.id)
            card.window.destroy()
        }
        live.removeAll()
        rimTimer?.invalidate()
        rimTimer = nil
        if let dismissToken { hotKeys.unregister(dismissToken) }
        dismissToken = nil
    }

    // MARK: Lifecycle

    private func show(_ card: CardState) {
        let window = DrawnWindow(style: .popup)
        let hover = PopupHover(window)
        let model = Live(card: card, window: window, hover: hover)
        live[card.id] = model
        hover.onHover = { [weak self, weak model] inside in
            guard let self, let model else { return }
            self.hoverChanged(model, inside: inside)
        }
        hover.onChange = { [weak model] in model?.window.setNeedsDisplay() }
        window.content = { [weak self, weak model] canvas, controls in
            guard let self, let model else { return }
            let now = Date()
            PopupCardView.draw(canvas, controls, model.card, look: self.look(model, at: now), handlers: self.handlers(model))
            model.window.animating = self.holdMoving(model, at: now)
        }
        model.size = PopupCardView.size(card, look: look(model), handlers: handlers(model))
        window.create(size: model.size, owner: SystemEvents.shared.hwnd)
        if case .windDown = card.content { takesKeyboard(model) }
        stack.present(window.window, id: card.id, size: model.size, priority: card.priority)
        hover.park()
        guard stack.ids.contains(card.id) else {
            model.evicted = true
            return
        }
        if let full = card.autoHideAfter { startCountdown(model, full: full) }
    }

    /// Closes the card as its × does: it goes now and the coordinator is told.
    private func close(_ id: UUID) {
        guard let model = live[id], !model.evicted else { return }
        remove(model)
        actions.dismissCard(id)
    }

    private func remove(_ model: Live) {
        stopTimers(model)
        model.hover.cancel()
        live[model.id] = nil
        stack.dismiss(model.id)
        model.window.hide()
        // Not from inside the window's own click: destroy on the next turn of the loop.
        DispatchQueue.main.async { model.window.destroy() }
    }

    private func stopTimers(_ model: Live) {
        model.timer?.invalidate()
        model.timer = nil
        model.holdTimer?.invalidate()
        model.holdTimer = nil
        model.copiedTimer?.invalidate()
        model.copiedTimer = nil
        model.window.animating = false
    }

    private func refresh(_ model: Live) {
        let size = PopupCardView.size(model.card, look: look(model), handlers: handlers(model))
        if size != model.size {
            model.size = size
            stack.resize(model.id, to: size)
        }
        model.window.setNeedsDisplay()
    }

    // MARK: Drawing state

    private func look(_ model: Live, at now: Date = Date()) -> PopupCardLook {
        var look = PopupCardLook()
        look.hovering = model.hover.inside
        look.rim = model.rim?.frame(at: now, reduceMotion: Appearance.reduceMotion)
        if case .resume = model.card.content, showsDismissKey { look.dismissKey = HotKeys.display(.nudgeDismiss) }
        look.isKey = model.isKey
        look.holdProgress = holdProgress(model, at: now)
        look.holding = model.holdStart != nil
        look.copied = model.copiedUntil.map { $0 > now } ?? false
        return look
    }

    private func handlers(_ model: Live) -> PopupCardHandlers {
        let id = model.id
        var handlers = PopupCardHandlers()
        handlers.close = { [weak self] in self?.close(id) }
        handlers.undo = { [actions] in actions.undoLastDecision() }
        handlers.resume = { [weak self] in
            self?.actions.resume()
            self?.close(id)
        }
        handlers.update = { [actions] in actions.installUpdate() }
        handlers.openPage = { [actions] in actions.openUpdate() }
        handlers.wrapUp = { [actions] in actions.windDownWrapUp() }
        handlers.copyNote = { [weak self, weak model] in
            guard let self, let model else { return }
            self.copyNote(model)
        }
        handlers.holdClick = { [weak self, weak model] in
            // Enter on the focused capsule; the pointer and Space hold it instead.
            guard let self, let model, !model.releasedByPointer, self.holdDuration(model) <= 0, model.holdStart == nil else { return }
            self.actions.windDownExtend()
        }
        if model.card.isRehearsal, case .resume = model.card.content, state.tour?.step == .resumeCard {
            handlers.tourCaption = tourCaption
        }
        return handlers
    }

    // MARK: Auto-hide and the rim

    private func startCountdown(_ model: Live, full: TimeInterval) {
        let now = Date()
        var rim = PopupRimTimeline.arriving(CardCountdown(full: full, start: now), at: now)
        if model.hover.inside { rim = PopupRimTimeline(countdown: rim.countdown.held(at: now)) }
        model.rim = rim
        scheduleTimeout(model)
        updateRimTimer()
    }

    private func hoverChanged(_ model: Live, inside: Bool) {
        if let rim = model.rim, !model.evicted {
            let now = Date()
            model.rim = inside ? rim.held(at: now) : rim.resumed(at: now, reduceMotion: Appearance.reduceMotion)
            scheduleTimeout(model)
            updateRimTimer()
        }
        model.window.setNeedsDisplay()
    }

    /// One timer at the countdown's deadline (none while held).
    private func scheduleTimeout(_ model: Live) {
        model.timer?.invalidate()
        model.timer = nil
        guard let deadline = model.rim?.countdown.deadline else { return }
        let id = model.id
        let timer = Timer(timeInterval: max(0, deadline.timeIntervalSinceNow), repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, let model = self.live[id], !model.hover.inside, !model.evicted else { return }
                // No fold-away to wait for: DWM's transition plays as the window hides.
                self.close(id)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        model.timer = timer
    }

    /// Redraws the cards whose rims run: 30 times a second (5 under Reduce Motion, where the rim
    /// only fades), only while one does.
    private func updateRimTimer() {
        let moving = live.values.contains { !$0.evicted && ($0.rim?.isMoving ?? false) }
        let interval = Appearance.reduceMotion ? 0.2 : 1.0 / 30
        if moving, rimTimer == nil || rimTimerInterval != interval {
            rimTimer?.invalidate()
            let timer = Timer(timeInterval: interval, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.rimTick() }
            }
            timer.tolerance = interval / 4
            RunLoop.main.add(timer, forMode: .common)
            rimTimer = timer
            rimTimerInterval = interval
        } else if !moving {
            rimTimer?.invalidate()
            rimTimer = nil
        }
    }

    private func rimTick() {
        var any = false
        for model in live.values where !model.evicted && (model.rim?.isMoving ?? false) {
            any = true
            model.window.setNeedsDisplay()
        }
        if !any { updateRimTimer() }
    }

    // MARK: The resume card's shortcut

    private func syncHotKey() {
        let hasResume = state.cards.contains { if case .resume = $0.content { return true } else { return false } }
        // The nudge card holds the same keys while it shows (on the Mac it outranks the card).
        let nudgeCardShows = state.nudge.map { $0.phase != .countdownChip } ?? false
        let wanted = hasResume && state.settings.nudgeHotkeys && !nudgeCardShows
        if wanted, dismissToken == nil, !dismissRefused {
            dismissToken = hotKeys.register(.nudgeDismiss) { [weak self] in self?.dismissNewestResume() }
            // Another app holds the keys: don't ask again until the card or the setting changes.
            dismissRefused = dismissToken == nil
        } else if !wanted {
            dismissRefused = false
            if let token = dismissToken { hotKeys.unregister(token) }
            dismissToken = nil
        }
        // The keycap only where the key reaches the card.
        let shows = dismissToken != nil && state.nudge == nil
        guard shows != showsDismissKey else { return }
        showsDismissKey = shows
        for model in live.values {
            if case .resume = model.card.content { model.window.setNeedsDisplay() }
        }
    }

    private func dismissNewestResume() {
        guard let card = state.cards.last(where: { if case .resume = $0.content { return true } else { return false } }) else { return }
        close(card.id)
    }

    // MARK: The wind-down card's keyboard and hold

    /// The card activates when clicked into (not before), so its keys reach it.
    private func takesKeyboard(_ model: Live) {
        let window = model.window
        if let hwnd = window.window.hwnd {
            let exStyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, exStyle & ~LONG_PTR(WS_EX_NOACTIVATE))
        }
        window.window.onMessage = { [weak self, weak model] message, wParam, lParam in
            guard let self, let model else { return nil }
            switch Int32(message) {
            case WM_MOUSEACTIVATE:
                return LRESULT(MA_ACTIVATE)
            case WM_KEYDOWN where Int32(wParam) == VK_SPACE:
                guard self.isAsking(model), model.window.controls.focused == nil || model.window.controls.focused == PopupWindDownCard.holdID
                else { return nil }
                // Bit 30: the key was already down (auto-repeat).
                if (Int(lParam) >> 30) & 1 == 0 { self.beginHold(model) }
                return 0
            case WM_KEYUP where Int32(wParam) == VK_SPACE:
                guard model.holdStart != nil else { return nil }
                self.endHold(model)
                return 0
            default:
                return nil
            }
        }
        window.window.onActivate = { [weak self, weak model] active in
            guard let self, let model else { return }
            model.isKey = active
            if !active, model.holdStart != nil { self.endHold(model) }
            self.refresh(model)
        }
        window.controls.onKey = { [weak self, weak model] key in
            guard let self, let model else { return false }
            let asking = self.isAsking(model)
            switch Int32(key) {
            case VK_RETURN:
                if asking { self.actions.windDownWrapUp() } else { self.copyNote(model) }
                return true
            case VK_ESCAPE where !asking:
                self.close(model.id)
                return true
            case 0x43 where !asking && GetKeyState(Int32(VK_CONTROL)) < 0:  // Ctrl+C
                self.copyNote(model)
                return true
            default:
                return false
            }
        }
        // The pointer holds the capsule from press to release.
        let down = window.window.onMouseDown
        window.window.onMouseDown = { [weak self, weak model] point in
            down?(point)
            guard let self, let model, model.window.controls.pressed == PopupWindDownCard.holdID else { return }
            self.beginHold(model)
        }
        let up = window.window.onMouseUp
        window.window.onMouseUp = { [weak self, weak model] point in
            guard let self, let model, model.holdStart != nil else {
                up?(point)
                return
            }
            self.endHold(model)
            model.releasedByPointer = true
            up?(point)
            model.releasedByPointer = false
        }
    }

    private func isAsking(_ model: Live) -> Bool {
        if case .windDown(let content) = model.card.content, content.phase == .asking { return true }
        return false
    }

    private func holdDuration(_ model: Live) -> TimeInterval {
        if case .windDown(let content) = model.card.content { return content.holdDuration }
        return 0
    }

    private func beginHold(_ model: Live) {
        guard model.holdStart == nil, isAsking(model) else { return }
        model.holdStart = Date()
        model.holdRelease = nil
        let hold = holdDuration(model)
        if hold > 0 {
            let id = model.id
            let timer = Timer(timeInterval: hold + 0.02, repeats: false) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let self, let model = self.live[id], model.holdStart != nil else { return }
                    model.holdStart = nil
                    model.holdTimer = nil
                    model.window.setNeedsDisplay()
                    self.actions.windDownExtend()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            model.holdTimer = timer
        }
        model.window.setNeedsDisplay()
    }

    /// Released: early, the fill springs back over 0.3 s and nothing happens; a 0 s hold acts.
    private func endHold(_ model: Live) {
        guard let start = model.holdStart else { return }
        model.holdTimer?.invalidate()
        model.holdTimer = nil
        model.holdStart = nil
        let hold = holdDuration(model)
        if hold <= 0 {
            actions.windDownExtend()
        } else {
            let reached = min(1, Date().timeIntervalSince(start) / hold)
            model.holdRelease = (reached, Date())
        }
        model.window.setNeedsDisplay()
    }

    private func holdProgress(_ model: Live, at now: Date) -> Double {
        let hold = holdDuration(model)
        if let start = model.holdStart { return hold > 0 ? min(1, now.timeIntervalSince(start) / hold) : 0 }
        guard let release = model.holdRelease else { return 0 }
        let duration = Appearance.reduceMotion ? 0.2 : 0.3
        let t = min(1, now.timeIntervalSince(release.at) / duration)
        if t >= 1 { model.holdRelease = nil }
        return release.from * (1 - (1 - pow(1 - t, 3)))
    }

    private func holdMoving(_ model: Live, at now: Date) -> Bool {
        model.holdStart != nil && holdDuration(model) > 0 || model.holdRelease != nil
    }

    private func copyNote(_ model: Live) {
        actions.copyWrapUpNote()
        model.copiedUntil = Date().addingTimeInterval(1.6)
        model.copiedTimer?.invalidate()
        let id = model.id
        let timer = Timer(timeInterval: 1.6, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let model = self?.live[id] else { return }
                model.copiedTimer = nil
                self?.refresh(model)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        model.copiedTimer = timer
        refresh(model)
    }
}
