import CBreakpointWin32
import Foundation
import WinSDK

/// The app's main thread: one Win32 message loop that also runs `DispatchQueue.main` and
/// Foundation's timers (the coordinator's tick, `asyncAfter`, every controller's timers).
///
/// It sleeps in `MsgWaitForMultipleObjectsEx` until a window message arrives, the main queue has
/// work (libdispatch signals its event) or the next Foundation timer is due, so an idle app uses
/// no CPU at all: no polling interval anywhere.
public enum MessageLoop {
    /// Runs until `quit()`; returns the exit code passed to it.
    @discardableResult
    public static func run() -> Int32 {
        let mainQueueEvent = _dispatch_get_main_queue_handle_4CF()
        var handles: [HANDLE?] = [mainQueueEvent.map { HANDLE($0) }]
        var message = MSG()
        while true {
            // Due timers and run-loop sources (non-blocking), then how long until the next one.
            let next = RunLoop.main.limitDate(forMode: .default)
            let timeout: DWORD
            if let next {
                let milliseconds = next.timeIntervalSinceNow * 1000
                timeout = milliseconds <= 0 ? 0 : DWORD(min(milliseconds.rounded(.up), Double(Int32.max)))
            } else {
                timeout = INFINITE
            }
            let waited = handles.withUnsafeMutableBufferPointer { buffer -> DWORD in
                MsgWaitForMultipleObjectsEx(buffer.baseAddress == nil || mainQueueEvent == nil ? 0 : 1,
                                            buffer.baseAddress, timeout, DWORD(QS_ALLINPUT),
                                            DWORD(MWMO_INPUTAVAILABLE))
            }
            if mainQueueEvent != nil, waited == WAIT_OBJECT_0 {
                _dispatch_main_queue_callback_4CF(nil)
            }
            while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
                if message.message == UINT(WM_QUIT) { return Int32(truncatingIfNeeded: message.wParam) }
                if !Dialogs.handled(&message) {
                    TranslateMessage(&message)
                    DispatchMessageW(&message)
                }
            }
            // Work queued while handling messages, then timers that came due.
            if mainQueueEvent != nil, WaitForSingleObject(handles[0], 0) == WAIT_OBJECT_0 {
                _dispatch_main_queue_callback_4CF(nil)
            }
            _ = RunLoop.main.run(mode: .default, before: Date.distantPast)
        }
    }

    /// Ends `run()` with `code` once the current message is handled.
    public static func quit(_ code: Int32 = 0) {
        PostQuitMessage(code)
    }
}

/// Keyboard navigation for windows that hold controls (Settings, Onboarding): Tab, arrows,
/// Enter and Esc reach them through `IsDialogMessageW`.
enum Dialogs {
    static var windows: Set<UInt> = []

    static func handled(_ message: inout MSG) -> Bool {
        guard !windows.isEmpty, let target = message.hwnd else { return false }
        let root = GetAncestor(target, UINT(GA_ROOT))
        guard let root, windows.contains(UInt(bitPattern: root)) else { return false }
        return IsDialogMessageW(root, &message)
    }
}
