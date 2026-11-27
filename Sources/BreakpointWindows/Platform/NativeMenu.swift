import CBreakpointWin32
import Foundation
import WinSDK

/// A native Windows pop-up menu (the system draws it: dark or light mode, accessibility, the
/// keyboard), with submenus and greyed lines.
@MainActor
public enum NativeMenu {
    public indirect enum Item {
        case action(String, checked: Bool = false, enabled: Bool = true, () -> Void)
        case submenu(String, [Item])
        /// A greyed line that says something (the tooltip sentence, "Why not now?").
        case label(String)
        case separator
    }

    /// Shows `items` at `point` (screen pixels) for `owner` and runs the chosen action. `alignBottom`
    /// opens it upward from the point (from the tray, over the taskbar).
    public static func show(_ items: [Item], at point: POINT, owner: HWND, alignBottom: Bool = false) {
        var actions: [() -> Void] = []
        guard let menu = build(items, actions: &actions) else { return }
        defer { DestroyMenu(menu) }
        // The owner must be foreground, or the menu does not close when the person clicks away.
        SetForegroundWindow(owner)
        var flags = UInt32(TPM_RIGHTBUTTON)
        flags |= alignBottom ? UInt32(TPM_BOTTOMALIGN) : UInt32(TPM_TOPALIGN)
        flags |= UInt32(TPM_LEFTALIGN)
        let chosen = bp_track_popup_menu(UnsafeMutableRawPointer(menu), flags, point.x, point.y, UnsafeMutableRawPointer(owner))
        // Documented fix for menus from the notification area: post a benign message so the
        // menu's loop ends cleanly the next time it is shown.
        PostMessageW(owner, UINT(WM_NULL), 0, 0)
        if chosen > 0, Int(chosen) <= actions.count { actions[Int(chosen) - 1]() }
    }

    private static func build(_ items: [Item], actions: inout [() -> Void]) -> HMENU? {
        guard let menu = CreatePopupMenu() else { return nil }
        for item in items {
            switch item {
            case .action(let title, let checked, let enabled, let run):
                actions.append(run)
                var flags = UINT(MF_STRING)
                if checked { flags |= UINT(MF_CHECKED) }
                if !enabled { flags |= UINT(MF_GRAYED) }
                AppendMenuW(menu, flags, UINT_PTR(actions.count), escaped(title).wide)
            case .submenu(let title, let children):
                guard let child = build(children, actions: &actions) else { continue }
                AppendMenuW(menu, UINT(MF_POPUP) | UINT(MF_STRING), UINT_PTR(UInt(bitPattern: child)), escaped(title).wide)
            case .label(let title):
                AppendMenuW(menu, UINT(MF_STRING) | UINT(MF_GRAYED), 0, escaped(title).wide)
            case .separator:
                AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
            }
        }
        return menu
    }

    /// `&` marks an access key in menu text; a literal one is doubled.
    private static func escaped(_ title: String) -> String { title.replacingOccurrences(of: "&", with: "&&") }
}
