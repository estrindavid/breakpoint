import Foundation
import WinSDK

/// Taking the keyboard while the overlay shows, and giving it back afterwards (the Windows
/// counterpart of the Mac's `FocusRestorer`, SPEC §7.2).
///
/// - `record()` when a break starts: the foreground window, or, when that is one of Breakpoint's
///   own (the break started from the flyout or its menu), the next visible window of another app
///   in z-order, which is the one the person was using before.
/// - `restore()` when it ends, while the overlay is still the foreground window: brings the
///   recorded window back, unless it closed or the person switched to another app during the
///   break.
/// - `take(_:)` brings the overlay to the foreground. Windows refuses `SetForegroundWindow` to a
///   process that did not receive the last input (a break that starts by itself while the person
///   types elsewhere), so it falls back to joining the foreground thread's input queue for the
///   call, the standard way an alarm-style window takes focus.
@MainActor
final class OverlayFocus {
    private var recorded: HWND?

    func record() {
        guard var front = GetForegroundWindow() else {
            recorded = nil
            return
        }
        if Self.isOwn(front) {
            guard let other = Self.nextOtherWindow(after: front) else {
                recorded = nil
                return
            }
            front = other
        }
        recorded = front
    }

    func restore() {
        defer { recorded = nil }
        guard let target = recorded, IsWindow(target) else { return }
        if let front = GetForegroundWindow(), !Self.isOwn(front), front != target { return }
        if IsIconic(target) { return }
        SetForegroundWindow(target)
    }

    func forget() { recorded = nil }

    /// Makes `hwnd` the foreground window; true when it is.
    @discardableResult
    static func take(_ hwnd: HWND) -> Bool {
        if GetForegroundWindow() == hwnd { return true }
        SetForegroundWindow(hwnd)
        if GetForegroundWindow() == hwnd { return true }
        let front = GetForegroundWindow()
        let frontThread = GetWindowThreadProcessId(front, nil)
        let ownThread = GetCurrentThreadId()
        guard frontThread != 0, frontThread != ownThread else { return false }
        AttachThreadInput(frontThread, ownThread, true)
        BringWindowToTop(hwnd)
        SetForegroundWindow(hwnd)
        SetFocus(hwnd)
        AttachThreadInput(frontThread, ownThread, false)
        return GetForegroundWindow() == hwnd
    }

    static func isOwn(_ hwnd: HWND) -> Bool {
        var process: DWORD = 0
        GetWindowThreadProcessId(hwnd, &process)
        return process == GetCurrentProcessId()
    }

    /// The next visible, unowned, non-tool top-level window of another process below `hwnd`.
    private static func nextOtherWindow(after hwnd: HWND) -> HWND? {
        var candidate = GetWindow(hwnd, UINT(GW_HWNDNEXT))
        var checked = 0
        while let window = candidate, checked < 512 {
            checked += 1
            let exStyle = DWORD(truncatingIfNeeded: GetWindowLongPtrW(window, GWL_EXSTYLE))
            if IsWindowVisible(window), !IsIconic(window), !isOwn(window), GetWindow(window, UINT(GW_OWNER)) == nil,
               exStyle & DWORD(WS_EX_TOOLWINDOW) == 0, GetWindowTextLengthW(window) > 0 {
                return window
            }
            candidate = GetWindow(window, UINT(GW_HWNDNEXT))
        }
        return nil
    }
}
