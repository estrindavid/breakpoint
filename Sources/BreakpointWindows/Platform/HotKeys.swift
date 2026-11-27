import BreakpointCore
import Foundation
import WinSDK

/// Global keyboard shortcuts with `RegisterHotKey` (no hook: Windows tells the app only that its
/// own combination was pressed). The nudge's Start and Not now and the popover shortcut use it,
/// as ⌃⌥⌘B, ⌃⌥⌘. and the Settings shortcut do on macOS.
///
/// Settings store shortcuts as macOS key codes and modifiers (`HotKeyCombo`), so one settings file
/// means the same keys on both: ⌃ is Ctrl, ⌥ is Alt, ⌘ is the Windows key, ⇧ is Shift. The same
/// combination registered twice (the nudge and the resume card share ⌃⌥⌘.) goes to the most recent
/// registration until it is released, as on macOS.
@MainActor
public final class HotKeys {
    public struct Token: Hashable { let id: Int32 }

    private struct Registration {
        let combo: HotKeyCombo
        let action: () -> Void
    }

    private var registrations: [Int32: Registration] = [:]
    private var nextID: Int32 = 1
    private var listening = false

    public init() {}

    public var registeredCount: Int { registrations.count }

    /// Registers `combo`; nil when Windows refuses it (another app holds it).
    @discardableResult
    public func register(_ combo: HotKeyCombo, action: @escaping () -> Void) -> Token? {
        listen()
        guard let hwnd = SystemEvents.shared.hwnd, let key = Self.virtualKey(combo.keyCode) else { return nil }
        let id = nextID
        nextID += 1
        // An earlier registration of the same keys steps aside while this one holds them.
        for (other, registration) in registrations where registration.combo == combo {
            UnregisterHotKey(hwnd, other)
        }
        guard RegisterHotKey(hwnd, id, Self.modifiers(combo.carbonModifiers) | UINT(MOD_NOREPEAT), UINT(key)) else {
            restore(combo)
            return nil
        }
        registrations[id] = Registration(combo: combo, action: action)
        return Token(id: id)
    }

    public func unregister(_ token: Token?) {
        guard let token, let registration = registrations.removeValue(forKey: token.id) else { return }
        if let hwnd = SystemEvents.shared.hwnd { UnregisterHotKey(hwnd, token.id) }
        restore(registration.combo)
    }

    public func unregisterAll() {
        if let hwnd = SystemEvents.shared.hwnd {
            for id in registrations.keys { UnregisterHotKey(hwnd, id) }
        }
        registrations.removeAll()
    }

    /// The newest earlier registration of `combo` takes the keys back.
    private func restore(_ combo: HotKeyCombo) {
        guard let hwnd = SystemEvents.shared.hwnd,
              let (id, registration) = registrations.filter({ $0.value.combo == combo }).max(by: { $0.key < $1.key }),
              let key = Self.virtualKey(combo.keyCode) else { return }
        _ = RegisterHotKey(hwnd, id, Self.modifiers(registration.combo.carbonModifiers) | UINT(MOD_NOREPEAT), UINT(key))
    }

    private func listen() {
        guard !listening else { return }
        listening = true
        SystemEvents.shared.start()
        SystemEvents.shared.on(UInt32(WM_HOTKEY)) { [weak self] wParam, _ in
            guard let self, let registration = self.registrations[Int32(truncatingIfNeeded: wParam)] else { return nil }
            registration.action()
            return 0
        }
    }

    // MARK: macOS codes → Windows

    /// Carbon `cmdKey` 0x100, `shiftKey` 0x200, `optionKey` 0x800, `controlKey` 0x1000.
    static func modifiers(_ carbon: UInt32) -> UINT {
        var result: UINT = 0
        if carbon & 0x1000 != 0 { result |= UINT(MOD_CONTROL) }
        if carbon & 0x0800 != 0 { result |= UINT(MOD_ALT) }
        if carbon & 0x0100 != 0 { result |= UINT(MOD_WIN) }
        if carbon & 0x0200 != 0 { result |= UINT(MOD_SHIFT) }
        return result
    }

    /// The Windows virtual key for a macOS key code (`kVK_ANSI_*` and the common keys).
    static func virtualKey(_ code: UInt32) -> Int32? {
        let letters: [UInt32: Character] = [
            0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I",
            0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
            0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
            0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        ]
        if let letter = letters[code], let ascii = letter.asciiValue { return Int32(ascii) }
        switch code {
        case 0x2F: return Int32(VK_OEM_PERIOD)
        case 0x2B: return Int32(VK_OEM_COMMA)
        case 0x2C: return Int32(VK_OEM_2)       // slash
        case 0x29: return Int32(VK_OEM_1)       // semicolon
        case 0x27: return Int32(VK_OEM_7)       // quote
        case 0x21: return Int32(VK_OEM_4)       // [
        case 0x1E: return Int32(VK_OEM_6)       // ]
        case 0x2A: return Int32(VK_OEM_5)       // backslash
        case 0x1B: return Int32(VK_OEM_MINUS)
        case 0x18: return Int32(VK_OEM_PLUS)    // =
        case 0x32: return Int32(VK_OEM_3)       // `
        case 0x31: return Int32(VK_SPACE)
        case 0x24: return Int32(VK_RETURN)
        case 0x7A: return Int32(VK_F1)
        case 0x78: return Int32(VK_F2)
        case 0x63: return Int32(VK_F3)
        case 0x76: return Int32(VK_F4)
        default: return nil
        }
    }

    /// The macOS key code for a Windows virtual key (the shortcut recorder), or nil.
    static func carbonKey(_ virtualKey: Int32) -> UInt32? {
        for code in UInt32(0)...0x7F where self.virtualKey(code) == virtualKey { return code }
        return nil
    }

    /// "Ctrl+Alt+Win+B": the Windows spelling of a combination.
    public static func display(_ combo: HotKeyCombo) -> String {
        var parts: [String] = []
        if combo.carbonModifiers & 0x1000 != 0 { parts.append("Ctrl") }
        if combo.carbonModifiers & 0x0800 != 0 { parts.append("Alt") }
        if combo.carbonModifiers & 0x0200 != 0 { parts.append("Shift") }
        if combo.carbonModifiers & 0x0100 != 0 { parts.append("Win") }
        let key: String
        switch virtualKey(combo.keyCode) {
        case Int32(VK_OEM_PERIOD): key = "."
        case Int32(VK_OEM_COMMA): key = ","
        case Int32(VK_SPACE): key = "Space"
        case Int32(VK_RETURN): key = "Enter"
        case let code?: key = String(UnicodeScalar(UInt8(clamping: code)))
        case nil: key = "?"
        }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}
