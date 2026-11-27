import AppKit
import SwiftUI
import BreakpointCore

// SPEC §3.1.

/// Shows the nudge card while `state.nudge` is in phase `.offer` or `.autoStartCard`.
///
/// Contract (beyond `SurfaceController`):
/// - Presents through the shared `TransientPanelStack` with priority `.nudge`; never takes focus.
/// - Runs the ignore timer: 10 s without interaction → `actions.ignoreNudge()` (hover pauses it;
///   leaving restarts it at 5 s). Not during auto-start (the coordinator drives that countdown);
///   when auto-start is cancelled back to an offer, the 10 s start afresh.
/// - Hovering during auto-start calls `actions.cancelAutoStart()`.
/// - While visible and `nudge.hotkeysEnabled`, registers ⌃⌥⌘B (accept) and ⌃⌥⌘. (decline) with
///   `HotKeyCenter`; unregisters when hidden.
/// - Exit: Start → scale 1.04 + fade 0.2 s; timeout → folds up into the top edge 0.35 s; withdrawn
///   → settle and fade 0.2 s; handed to the countdown chip → the chip's panel takes the card over
///   (`PopupHandoff`) and morphs it into the chip (SPEC §3.1, §3.2, §4.6).
/// - VoiceOver: announces the offer when it appears ("Break offer: 2-minute stretch.
///   Control-Option-Command-B to start.").
@MainActor
public final class NudgePanelController: SurfaceController {
    private let state: AppState
    private let actions: AppActions
    private let stack: TransientPanelStack
    private let hotKeys: HotKeyCenter
    private let model = NudgeModel()
    private var panel: TransientPanel?
    private var shownID: UUID?
    private var shownPhase: NudgePhase?
    private var ignoreTimer: Timer?
    private var hotKeyTokens: [HotKeyToken] = []
    /// Whether the visible nudge asked for its shortcuts (even if the system refused them).
    private var hotKeysWanted = false
    private var leaving: [TransientPanel] = []

    public init(state: AppState, actions: AppActions, stack: TransientPanelStack, hotKeys: HotKeyCenter) {
        self.state = state
        self.actions = actions
        self.stack = stack
        self.hotKeys = hotKeys
    }

    public func sync() {
        guard let nudge = state.nudge, nudge.phase != .countdownChip else {
            if let nudge = state.nudge, nudge.id == shownID, handOffToChip() {
                hide(exit: .handoff)
            } else if shownID != nil {
                // Accepted when a break of the offered kind just started; otherwise withdrawn,
                // timed out (already faded) or handed to the countdown chip.
                let accepted = state.activeBreak != nil && state.activeBreak?.kind == model.nudge?.kind
                hide(exit: accepted ? .accepted : .action)
            }
            return
        }
        if shownID != nudge.id {
            if shownID != nil { hide(exit: .action) }
            show(nudge)
            return
        }
        // Only real changes re-render the card (sync runs at 10 Hz while a nudge shows).
        if model.nudge != nudge { model.nudge = nudge }
        let tour = nudge.isRehearsal ? state.tour : nil
        if model.tour != tour { model.tour = tour }
        // The shortcut setting changed while the card shows: follow it now, not at the next nudge.
        if nudge.hotkeysEnabled != hotKeysWanted {
            if nudge.hotkeysEnabled { registerHotKeys() } else { unregisterHotKeys() }
        }
        if shownPhase != nudge.phase {
            let previous = shownPhase
            shownPhase = nudge.phase
            // Auto-start cancelled back to an ordinary offer: it stays its full 10 s.
            if previous == .autoStartCard, nudge.phase == .offer { restartIgnoreTimer(after: Timing.nudgeIgnoreAfter) }
        }
    }

    public func tearDown() {
        ignoreTimer?.invalidate()
        ignoreTimer = nil
        unregisterHotKeys()
        if let id = shownID { stack.dismiss(id: id) }
        panel?.close()
        leaving.forEach { $0.close() }
        leaving.removeAll()
        panel = nil
        shownID = nil
        shownPhase = nil
        model.nudge = nil
    }

    // MARK: Show and hide

    private func show(_ nudge: NudgeState) {
        model.nudge = nudge
        model.tour = nudge.isRehearsal ? state.tour : nil
        model.popup = PopupModel()
        let popup = model.popup
        let root = NudgeHost(model: model, popup: popup, actions: actions, onClose: { [weak self] in
            self?.actions.declineNudge()
        })
        let panel = TransientPanel(rootView: root)
        panel.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        self.panel = panel
        shownID = nudge.id
        shownPhase = nudge.phase
        stack.present(panel, id: nudge.id, priority: .nudge)
        DispatchQueue.main.async { [weak popup] in
            guard let popup, popup.phase == .arriving else { return }
            popup.phase = .shown
        }
        // The tour's sample nudge waits for Start or Not now (SPEC §3.12).
        if nudge.phase == .offer, !nudge.isRehearsal { restartIgnoreTimer(after: Timing.nudgeIgnoreAfter) }
        if nudge.hotkeysEnabled { registerHotKeys() }
        Announcer.announce(Copy.nudgeAnnouncement(kind: nudge.kind, length: nudge.offer.length, hotkeysOn: nudge.hotkeysEnabled))
    }

    private func hide(exit: PopupExit) {
        ignoreTimer?.invalidate()
        ignoreTimer = nil
        unregisterHotKeys()
        guard let panel, let id = shownID else { return }
        self.panel = nil
        shownID = nil
        shownPhase = nil
        let popup = model.popup
        if case .leaving = popup.phase {
            // The timeout exit is already playing.
        } else {
            popup.phase = .leaving(exit)
        }
        // The chip's panel shows this card from now on: go in the same frame it appears.
        if exit == .handoff { panel.alphaValue = 0 }
        leaving.append(panel)
        stack.markLeaving(id: id)
        let duration = exit.duration(reduceMotion: SystemMotion.reduceMotion)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.03) { [weak self] in
            guard let self else { return }
            self.stack.dismiss(id: id)
            panel.close()
            self.leaving.removeAll { $0 === panel }
        }
    }

    /// The eye-rest countdown moves to the pointer: leave the card with the stack for the chip,
    /// which starts as this card and becomes itself (SPEC §3.2). Not under Reduce Motion (the
    /// card fades and the chip fades in), and not if the card is not on screen.
    private func handOffToChip() -> Bool {
        guard !SystemMotion.reduceMotion, let id = shownID, let last = model.nudge,
              let frame = stack.cardFrame(id: id) else { return false }
        let padding = Theme.Layout.cardPadding
        let content = NudgeCardView(nudge: last, actions: actions, revealed: false, onClose: nil)
            .environment(\.glassSurfaceHosted, true)
            .fixedSize()
        stack.handOff(PopupHandoff(frame: frame, radius: Theme.Radius.card,
                                   badge: CGRect(x: padding, y: padding, width: Theme.Layout.badge, height: Theme.Layout.badge),
                                   content: AnyView(content)),
                      id: id)
        return true
    }

    // MARK: Ignore timer and hover

    private func restartIgnoreTimer(after delay: TimeInterval) {
        ignoreTimer?.invalidate()
        ignoreTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timedOut() }
        }
    }

    private func timedOut() {
        guard let nudge = state.nudge, nudge.id == shownID, nudge.phase == .offer, !model.popup.hovering else { return }
        ignoreTimer = nil
        model.popup.phase = .leaving(.timeout)
        let id = nudge.id
        stack.markLeaving(id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + PopupExit.timeout.duration(reduceMotion: SystemMotion.reduceMotion)) { [weak self] in
            guard let self, self.state.nudge?.id == id else { return }
            self.actions.ignoreNudge()
        }
    }

    private func hoverChanged(_ inside: Bool) {
        model.popup.setHovering(inside)
        guard let nudge = state.nudge, nudge.id == shownID else { return }
        if case .leaving = model.popup.phase { return }
        if inside {
            ignoreTimer?.invalidate()
            ignoreTimer = nil
            if nudge.phase == .autoStartCard { actions.cancelAutoStart() }
        } else if nudge.phase == .offer, !nudge.isRehearsal {
            restartIgnoreTimer(after: Timing.nudgeIgnoreAfterHover)
        }
    }

    // MARK: Hotkeys (registered only while the nudge shows, SPEC decision 16)

    private func registerHotKeys() {
        unregisterHotKeys()
        hotKeysWanted = true
        let accept = hotKeys.register(.nudgeStart) { [weak self] in self?.actions.acceptNudge() }
        let decline = hotKeys.register(.nudgeDismiss) { [weak self] in
            guard let self else { return }
            if self.state.nudge?.phase == .autoStartCard { self.actions.cancelAutoStart() }
            self.actions.declineNudge()
        }
        hotKeyTokens = [accept, decline].compactMap { $0 }
    }

    private func unregisterHotKeys() {
        hotKeysWanted = false
        hotKeyTokens.forEach { hotKeys.unregister($0) }
        hotKeyTokens.removeAll()
    }
}

/// What the nudge panel shows; kept by the controller so the exit can play after the state moved on.
@MainActor
final class NudgeModel: ObservableObject {
    @Published var nudge: NudgeState?
    /// The tour, while this is its sample nudge: the coach line hangs under the card.
    @Published var tour: TourPresentation?
    var popup = PopupModel()
}

/// The nudge card bound to the controller's model, with its pop-up motion.
struct NudgeHost: View {
    @ObservedObject var model: NudgeModel
    @ObservedObject var popup: PopupModel
    let actions: AppActions
    let onClose: () -> Void

    var body: some View {
        if let nudge = model.nudge {
            VStack(spacing: 0) {
                NudgeCardView(nudge: nudge, actions: actions, revealed: popup.revealed, onClose: onClose)
                    .popupMotion(popup.phase)
                if let tour = model.tour {
                    TourAttachedCaption(tour: tour, phase: popup.phase, actions: actions)
                }
            }
        }
    }
}

/// VoiceOver announcements (SPEC §3.3, §4.8).
@MainActor
enum Announcer {
    static func announce(_ text: String) {
        guard let element = NSApp else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
