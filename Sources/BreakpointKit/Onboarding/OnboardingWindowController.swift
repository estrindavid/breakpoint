import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.10.

/// The onboarding steps, in order.
public enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome, howItWorks, connect, pace, done

    public var id: Int { rawValue }
}

/// The first-launch window: 560 × 460, centred, follows the system appearance.
///
/// Contract: `show()` opens it (the coordinator calls it when `settings.hasCompletedOnboarding`
/// is false). Finishing, or closing the window, calls `actions.completeOnboarding()` once (which
/// registers the login item if on and opens the popover once). Completable by keyboard alone:
/// Return = Continue, Esc / ⌘[ = Back, ⌘] = Continue, ← → choose a pace. Nothing is installed
/// until the user presses Install.
@MainActor
public final class OnboardingWindowController: NSObject, SurfaceController, NSWindowDelegate {
    private let state: AppState
    private let actions: AppActions
    private var window: BreakpointWindow?
    private var completed = false
    private let flow = OnboardingFlow()
    private var stepObservation: Any?

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
        super.init()
        flow.onFinish = { [weak self] in self?.finish() }
        Self.current = self
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    /// The app's controller (development self-test).
    static weak var current: OnboardingWindowController?

    /// The current step (development self-test).
    var step: OnboardingStep { flow.step }
    var onboardingWindow: NSWindow? { window }

    public func show() {
        if window == nil {
            let window = BreakpointWindow(contentRect: CGRect(origin: .zero, size: Theme.Layout.onboardingSize),
                                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Welcome to Breakpoint"
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.sharingType = .none
            window.delegate = self
            let hosting = NSHostingController(rootView: OnboardingView(state: state, actions: actions, flow: flow))
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(Theme.Layout.onboardingSize)
            window.center()
            window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
            self.window = window
            stepObservation = flow.$step.sink { [weak self] step in
                if step == .done { DispatchQueue.main.async { self?.locateStatusItem() } }
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func sync() {
        // The window observes AppState directly; nothing to reconcile.
    }

    public func tearDown() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    public func windowWillClose(_ notification: Notification) { complete() }

    /// Return / Enter continue, Esc and ⌘[ go back, ⌘] continues, ← → pick a pace.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window, !window.isEditingText else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "[": flow.back(); return true
            case "]": flow.advance(); return true
            default: return false
            }
        }
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.keyCode {
        case 36, 76: flow.advance(); return true
        case 53: flow.back(); return true
        case 123 where flow.step == .pace: movePreset(-1); return true
        case 124 where flow.step == .pace: movePreset(1); return true
        default: return false
        }
    }

    private func movePreset(_ delta: Int) {
        let cards = CadencePreset.cards
        let index = cards.firstIndex(of: state.settings.preset) ?? 1
        let next = cards[min(max(index + delta, 0), cards.count - 1)]
        actions.updateSettings { $0.applyPreset(next) }
    }

    /// Points the Done step's arrow at the status item's real position.
    private func locateStatusItem() {
        guard let window else { return }
        guard let item = StatusItemController.current?.statusItemFrame else {
            flow.statusItemVisible = StatusItemController.current == nil
            flow.arrowAngle = nil
            return
        }
        flow.statusItemVisible = true
        let from = CGPoint(x: window.frame.midX, y: window.frame.maxY)
        let to = CGPoint(x: item.midX, y: item.midY)
        // Screen y grows upward; the angle is clockwise from "up".
        let angle = atan2(to.x - from.x, to.y - from.y) * 180 / .pi
        flow.arrowAngle = min(max(angle, -80), 80)
        let screen = NSScreen.screens.first { $0.frame.contains(to) } ?? NSScreen.main
        let third = (screen?.frame.width ?? 1) / 3
        let x = to.x - (screen?.frame.minX ?? 0)
        flow.statusItemPlace = x > 2 * third ? "top right of your screen" : (x < third ? "top left of your screen" : "top of your screen")
    }

    private func finish() {
        window?.close()
        complete()
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        actions.completeOnboarding()
    }
}
