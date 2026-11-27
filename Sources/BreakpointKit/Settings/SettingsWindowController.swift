import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.9.

// `SettingsPane` lives in BreakpointRuntime (Presentation/SettingsPane.swift), shared with Windows.

/// The settings window: sidebar window, default 860 × 770, minimum 720 × 560, sidebar 200 pt,
/// follows the system appearance. Remembers its frame and pane.
///
/// Contract: `show(pane:)` creates the window on first use, selects `pane` (or keeps the current
/// one when nil), activates the app and brings the window front. Closing hides it (state kept).
/// `tearDown()` closes it.
///
/// Keyboard: ⌘1…⌘8 select a pane; ↑ ↓ move through the sidebar; Page Up / Page Down / Home / End
/// scroll the pane; ⌘W closes; the usual editing keys work in text fields.
@MainActor
public final class SettingsWindowController: NSObject, SurfaceController, NSWindowDelegate {
    private let state: AppState
    private let actions: AppActions
    private var window: BreakpointWindow?
    private let selection = SettingsSelection(pane: SettingsSelection.remembered ?? .breaks)

    private static let frameName = "BreakpointSettingsWindow"

    /// The app's controller (development self-test).
    static weak var current: SettingsWindowController?

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
        super.init()
        Self.current = self
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    /// The selected pane.
    public var pane: SettingsPane { selection.pane }

    /// The settings window, once created (development self-test).
    var settingsWindow: NSWindow? { window }

    public func show(pane: SettingsPane? = nil) {
        if let pending = SettingsNavigator.pendingPane {
            selection.pane = pending
            SettingsNavigator.pendingPane = nil
        }
        if let pane { selection.pane = pane }
        if window == nil { window = makeWindow() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        focusSidebar()
    }

    public func sync() {
        // The window observes AppState directly; nothing to reconcile.
    }

    public func tearDown() {
        window?.close()
    }

    /// Closes the window (Take the tour: the tour happens on the real surfaces, not over Settings).
    public func close() {
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }

    private func makeWindow() -> BreakpointWindow {
        let window = BreakpointWindow(contentRect: CGRect(origin: .zero, size: Theme.Layout.settingsDefaultSize),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: true)
        window.title = "Breakpoint Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title bar 52 pt, so the traffic lights line up with
        // the pane header, as in System Settings.
        let toolbar = NSToolbar(identifier: "BreakpointSettings")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.contentMinSize = Theme.Layout.settingsMinimumSize
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.sharingType = .none
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SettingsRootView(state: state, actions: actions, selection: selection))
        window.setContentSize(Theme.Layout.settingsDefaultSize)
        if !(WindowMemory.isEnabled && window.setFrameUsingName(Self.frameName)) {
            window.center()
        }
        if WindowMemory.isEnabled { window.setFrameAutosaveName(Self.frameName) }
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        return window
    }

    /// Puts keyboard focus in the sidebar so ↑ ↓ move between panes straight away.
    private func focusSidebar() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, let table = Self.firstView(of: NSTableView.self, in: window.contentView) else { return }
            if !(window.firstResponder is NSTextView) { window.makeFirstResponder(table) }
        }
    }

    /// ⌘1…⌘8 and scrolling keys.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           (1...SettingsPane.allCases.count).contains(digit) {
            selection.pane = SettingsPane.allCases[digit - 1]
            return true
        }
        guard modifiers.isDisjoint(with: [.command, .control, .option]), !window.isEditingText,
              event.type == .keyDown else { return false }
        switch event.keyCode {
        case 121: return scrollContent(by: .pageDown)
        case 116: return scrollContent(by: .pageUp)
        case 115: return scrollContent(by: .top)
        case 119: return scrollContent(by: .bottom)
        default: return false
        }
    }

    enum ScrollStep { case pageUp, pageDown, top, bottom }

    /// Scrolls the pane's scroll view (not the sidebar's). SwiftUI's scroll view keeps its own
    /// position, so this sends it a scroll-wheel event (made in-process, never posted to the system).
    @discardableResult
    func scrollContent(by step: ScrollStep) -> Bool {
        guard let scrollView = contentScrollView else { return false }
        let page = max(40, scrollView.contentView.bounds.height - scrollView.contentInsets.top - 60)
        let distance: CGFloat
        switch step {
        case .pageDown: distance = -page
        case .pageUp: distance = page
        case .top: distance = 100_000
        case .bottom: distance = -100_000
        }
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: Int32(distance), wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent) else { return false }
        scrollView.scrollWheel(with: event)
        return true
    }

    /// The pane's scroll view: the largest scroll view that does not hold the sidebar table.
    var contentScrollView: NSScrollView? {
        guard let root = window?.contentView else { return nil }
        return Self.allViews(of: NSScrollView.self, in: root)
            .filter { !($0.documentView is NSTableView) && Self.firstView(of: NSTableView.self, in: $0) == nil }
            .max { $0.frame.width < $1.frame.width }
    }

    /// Selects a pane (development self-test and keyboard).
    func select(_ pane: SettingsPane) { selection.pane = pane }

    static func firstView<T: NSView>(of type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = firstView(of: type, in: sub) { return match } }
        return nil
    }

    static func allViews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for sub in view.subviews { result += allViews(of: type, in: sub) }
        return result
    }
}

/// The selected pane, shared between the controller and the root view. Remembered across launches.
@MainActor
public final class SettingsSelection: ObservableObject {
    @Published public var pane: SettingsPane {
        didSet { WindowMemory.set(pane.rawValue, for: Self.key) }
    }

    public init(pane: SettingsPane = .breaks) { self.pane = pane }

    private static let key = "settings.selectedPane"

    static var remembered: SettingsPane? { WindowMemory.string(key).flatMap(SettingsPane.init(rawValue:)) }
}
