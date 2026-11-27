import CBreakpointWin32
import Foundation
import WinSDK

/// One hidden top-level window that receives the system's broadcasts and notifications and hands
/// them to whoever subscribed: power (sleep, wake, display on/off), the session (lock, unlock,
/// remote), display and DPI changes, theme and accessibility settings, global hotkeys, the tray
/// icon's callbacks and Explorer restarting (`TaskbarCreated`).
///
/// A message-only window would be lighter but receives no broadcasts, so this is an ordinary,
/// never-shown popup window.
@MainActor
public final class SystemEvents {
    public static let shared = SystemEvents()

    public private(set) var hwnd: HWND?
    private var handlers: [UInt32: [(WPARAM, LPARAM) -> LRESULT?]] = [:]
    private var displayStateNotification: HPOWERNOTIFY?
    /// `RegisterWindowMessage("TaskbarCreated")`: Explorer (re)started; tray icons must be re-added.
    public private(set) var taskbarCreatedMessage: UINT = 0

    /// The private message the tray icon calls back with.
    public static let trayCallback = UINT(WM_APP) + 1
    /// Posted to wake the loop (no payload).
    public static let wake = UINT(WM_APP) + 2

    private init() {}

    /// Creates the window and registers for session and display-state notifications.
    public func start() {
        guard hwnd == nil else { return }
        WindowClass.register()
        let created = "Breakpoint system events".withCString(encodedAs: UTF16.self) { title in
            WindowClass.name.withCString(encodedAs: UTF16.self) { className in
                CreateWindowExW(DWORD(WS_EX_TOOLWINDOW), className, title, DWORD(WS_POPUP), 0, 0, 0, 0, nil, nil,
                                GetModuleHandleW(nil), nil)
            }
        }
        guard let created else { return }
        hwnd = created
        let window = EventsWindow()
        window.events = self
        WindowClass.windows[UInt(bitPattern: created)] = window
        taskbarCreatedMessage = "TaskbarCreated".withCString(encodedAs: UTF16.self) { RegisterWindowMessageW($0) }
        // Lock, unlock, remote connect and disconnect of this session.
        _ = bp_session_notifications_register(UnsafeMutableRawPointer(created))
        // Display on, off and dimmed (PBT_POWERSETTINGCHANGE with GUID_CONSOLE_DISPLAY_STATE).
        var guid = GUID_CONSOLE_DISPLAY_STATE
        displayStateNotification = RegisterPowerSettingNotification(HANDLE(created), &guid, DWORD(DEVICE_NOTIFY_WINDOW_HANDLE))
    }

    public func stop() {
        guard let hwnd else { return }
        bp_session_notifications_unregister(UnsafeMutableRawPointer(hwnd))
        if let displayStateNotification { _ = UnregisterPowerSettingNotification(displayStateNotification) }
        displayStateNotification = nil
        WindowClass.windows[UInt(bitPattern: hwnd)] = nil
        DestroyWindow(hwnd)
        self.hwnd = nil
    }

    /// Calls `handler` for every `message` (several handlers may share one message; the first that
    /// returns a result consumes it).
    public func on(_ message: UInt32, _ handler: @escaping (WPARAM, LPARAM) -> LRESULT?) {
        handlers[message, default: []].append(handler)
    }

    fileprivate func dispatch(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        guard let list = handlers[message] else { return nil }
        var result: LRESULT?
        for handler in list {
            if let value = handler(wParam, lParam), result == nil { result = value }
        }
        return result
    }
}

/// The `Window` entry the shared window procedure dispatches to for the events window.
@MainActor
private final class EventsWindow: Window {
    weak var events: SystemEvents?

    init() { super.init(style: .popup) }

    override func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        events?.dispatch(message, wParam, lParam)
    }
}
