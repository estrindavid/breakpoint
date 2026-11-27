import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// The popover's commands, menus and keyboard
// model, shared by `StatusItemController` (key handling) and `PopoverView` (clicks), so a click
// and a key press always do exactly the same thing.

/// The controls of the popover that take part in keyboard navigation (← → / Tab, Return, Space).
enum PopoverFocusItem: Hashable, CaseIterable {
    case takeBreak, pause, resume, undo, connect, gear
}

/// Commands and keyboard state for the popover.
@MainActor
final class PopoverCommands: ObservableObject {
    /// The keyboard-focused control; `nil` until the user presses an arrow or Tab (no ring on open).
    @Published var focus: PopoverFocusItem?

    private let state: AppState
    private let actions: AppActions
    /// Closes the popover (set by the controller).
    var close: () -> Void = {}
    /// Frames of the controls in the popover's coordinate space (top-left origin), for menus.
    var anchorFrames: [PopoverFocusItem: CGRect] = [:]
    /// The view hosting the popover content (menus pop up in it).
    weak var hostView: NSView?

    init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    /// The focusable controls in visual order for the current state.
    func items() -> [PopoverFocusItem] {
        var items: [PopoverFocusItem] = state.status.isPaused ? [.resume, .takeBreak] : [.takeBreak, .pause]
        if state.undoableDecision != nil { items.append(.undo) }
        if PopoverModel.showsConnectPrompt(state) { items.append(.connect) }
        items.append(.gear)
        return items
    }

    /// Moves keyboard focus by `delta` (wrapping); the first move shows the ring on the primary.
    func moveFocus(_ delta: Int) {
        let items = items()
        guard !items.isEmpty else { return }
        guard let current = focus, let index = items.firstIndex(of: current) else {
            focus = items[0]
            return
        }
        focus = items[(index + delta + items.count) % items.count]
    }

    /// Return / Space: the focused control, or the primary action when nothing is focused.
    func activateFocused() {
        let item = focus.flatMap { items().contains($0) ? $0 : nil } ?? items().first
        if let item { perform(item) }
    }

    func perform(_ item: PopoverFocusItem) {
        switch item {
        case .takeBreak: popUp(breakMenu(), from: .takeBreak)
        case .pause: popUp(pauseMenu(), from: .pause)
        case .resume: actions.resume()
        case .undo: actions.undoLastDecision()
        case .connect: openSettings(.integrations)
        case .gear: popUp(gearMenu(), from: .gear)
        }
    }

    func openSettings(_ pane: SettingsPane? = nil) {
        close()
        SettingsNavigator.pendingPane = pane
        actions.openSettings()
    }

    func quit() {
        close()
        actions.quit()
    }

    // MARK: Menus (shared with the status item's right-click menu)

    func breakMenu() -> NSMenu {
        let menu = NSMenu(title: "Take a break")
        for kind in BreakKind.allCases {
            let item = ClosureMenuItem(title: "\(kind.menuTitle) · \(PopoverModel.lengthLabel(kind))") { [weak self] in
                self?.close()
                self?.actions.startBreak(kind)
            }
            item.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    func pauseMenu() -> NSMenu {
        let menu = NSMenu(title: "Pause")
        for duration in PauseDuration.allCases {
            let title = duration == .untilTomorrow
                ? duration.menuTitle
                : "\(duration.menuTitle) · until \(TimeFormat.timeOfDay(duration.end(from: state.now)))"
            menu.addItem(ClosureMenuItem(title: title) { [weak self] in self?.actions.pause(duration) })
        }
        return menu
    }

    func gearMenu() -> NSMenu {
        let menu = NSMenu(title: "Breakpoint")
        menu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { [weak self] in self?.openSettings() })
        menu.addItem(ClosureMenuItem(title: "About Breakpoint") { [weak self] in self?.openSettings(.about) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit Breakpoint", keyEquivalent: "q") { [weak self] in self?.quit() })
        return menu
    }

    private func popUp(_ menu: NSMenu, from item: PopoverFocusItem) {
        guard let host = hostView, host.window != nil, let frame = anchorFrames[item] else { return }
        // Below the control, aligned to its leading edge.
        let y = host.isFlipped ? frame.maxY + 4 : host.bounds.height - frame.maxY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: y), in: host)
    }
}

// `SettingsNavigator` lives in BreakpointRuntime (Presentation/SettingsPane.swift).

/// Reports a control's frame in the popover's coordinate space, so a native menu can pop up
/// below it (from a click or from the keyboard).
struct MenuAnchor: View {
    let item: PopoverFocusItem

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: PopoverAnchorKey.self,
                                   value: [item: geo.frame(in: .named(PopoverAnchorKey.space))])
        }
    }
}

struct PopoverAnchorKey: PreferenceKey {
    static let space = "breakpoint.popover"
    static var defaultValue: [PopoverFocusItem: CGRect] { [:] }
    static func reduce(value: inout [PopoverFocusItem: CGRect], nextValue: () -> [PopoverFocusItem: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// An `NSMenuItem` that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
