import AppKit
import SwiftUI
import BreakpointCore

// SPEC §3.6.

/// Shows the `.windDown` card through the panel stack (priority `.windDown`). It stays until
/// answered and becomes key only after the user clicks into it (`TransientPanel.allowsKey`).
/// "15 more minutes" calls `actions.windDownExtend()` only after the hold completes.
///
/// Keys once the card is key: Return → Wrap up (asking) or Copy note (note); ⌘C → Copy note;
/// Esc → Done (note only; the question is never dismissed by Esc); Space held → holds
/// "15 more minutes".
@MainActor
public final class WindDownCardController: SurfaceController {
    private var surface: CardPanelSurface!
    private var keyboards: [UUID: WindDownKeyboard] = [:]
    private let state: AppState
    private let actions: AppActions

    public init(state: AppState, actions: AppActions, stack: TransientPanelStack) {
        self.state = state
        self.actions = actions
        surface = CardPanelSurface(
            state: state, actions: actions, stack: stack,
            matches: { if case .windDown = $0 { return true } else { return false } },
            configure: { [weak self] panel, id in self?.configure(panel, id: id) },
            makeView: { [weak self] card, context in
                guard case .windDown(let content) = card.content else { return AnyView(EmptyView()) }
                let keyboard = self?.keyboard(for: card.id) ?? WindDownKeyboard()
                return AnyView(WindDownCardView(card: content, actions: actions, onDone: context.close, keyboard: keyboard))
            })
    }

    public func sync() {
        surface.sync()
        let ids = Set(state.cards.map(\.id))
        keyboards = keyboards.filter { ids.contains($0.key) }
    }

    public func tearDown() { surface.tearDown() }

    private func keyboard(for id: UUID) -> WindDownKeyboard {
        if let existing = keyboards[id] { return existing }
        let keyboard = WindDownKeyboard()
        keyboards[id] = keyboard
        return keyboard
    }

    private func configure(_ panel: TransientPanel, id: UUID) {
        panel.allowsKey = true
        // A click anywhere on the card makes it key (without activating Breakpoint), so Return,
        // Esc, ⌘C and the Space hold reach it. With `true`, SwiftUI buttons never ask for key.
        panel.becomesKeyOnlyIfNeeded = false
        let keyboard = keyboard(for: id)
        panel.onBecameKey = { keyboard.isKey = true }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                keyboard.isKey = false
                keyboard.spaceHeld = false
            }
        }
        panel.keyHandler = { [weak self] event in
            guard let self else { return false }
            return self.handleKey(event, id: id, keyboard: keyboard)
        }
    }

    private func handleKey(_ event: NSEvent, id: UUID, keyboard: WindDownKeyboard) -> Bool {
        guard let card = state.cards.first(where: { $0.id == id }), case .windDown(let content) = card.content else {
            return false
        }
        let isNote: Bool
        if case .note = content.phase { isNote = true } else { isNote = false }
        let command = event.modifierFlags.contains(.command)
        switch (event.type, event.keyCode) {
        case (.keyDown, KeyCode.space) where !isNote && !command:
            if !event.isARepeat { keyboard.spaceHeld = true }
            return true
        case (.keyUp, KeyCode.space):
            keyboard.spaceHeld = false
            return true
        case (.keyDown, KeyCode.returnKey), (.keyDown, KeyCode.enter):
            if isNote { actions.copyWrapUpNote() } else { actions.windDownWrapUp() }
            return true
        case (.keyDown, KeyCode.escape) where isNote:
            actions.dismissCard(id)
            return true
        case (.keyDown, KeyCode.c) where command && isNote:
            actions.copyWrapUpNote()
            return true
        default:
            return false
        }
    }
}

/// Virtual key codes used by the break screens (`kVK_*`).
enum KeyCode {
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let c: UInt16 = 8
}
