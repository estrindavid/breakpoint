import BreakpointCore
import BreakpointRuntime
import CBreakpointWin32
import Foundation
import WinSDK

/// Windows' side of `AppPlatform`: Win32 for quitting, the clipboard, the save dialog and
/// message boxes, the install folder's layout and the relaunch helper, and the Windows services.
@MainActor
public final class WindowsPlatform: AppPlatform {
    /// Called on the way out (the app's entry point stops the coordinator).
    public var willQuit: (() -> Void)?

    public init() {}

    public func makeActivityMonitor() -> ActivityMonitoring { WindowsActivityMonitor() }
    public func makeHeadphoneMonitor() -> HeadphoneMotionMonitoring { UnavailableHeadphoneMotion() }
    public func makeSoundPlayer() -> SoundPlaying { WindowsSoundPlayer() }
    public func makeLoginItem() -> LoginItemControlling { WindowsLoginItem() }
    public func makeUpdateFetcher() -> UpdateFetching { WindowsUpdateFetcher() }

    public func makeShell(state: AppState, actions: AppActions, options: LaunchOptions, paths: BreakpointPaths) -> PlatformShell {
        WindowsShell(state: state, actions: actions, options: options, paths: paths)
    }

    public func quit() {
        willQuit?()
        willQuit = nil
        ExitGuard.arm()
        MessageLoop.quit()
    }

    public func copyText(_ text: String) {
        let utf16 = Array(text.replacingOccurrences(of: "\n", with: "\r\n").utf16) + [0]
        guard OpenClipboard(SystemEvents.shared.hwnd) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let bytes = utf16.count * MemoryLayout<UInt16>.size
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)), let pointer = GlobalLock(memory) else { return }
        utf16.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(memory)
        if SetClipboardData(UINT(CF_UNICODETEXT), memory) == nil { GlobalFree(memory) }
    }

    public func exportHistory(suggestedName: String, write: (URL) throws -> Void) {
        guard let url = FileDialogs.save(suggestedName: suggestedName, filter: ("JSON", "*.json"), owner: Dialogs.ownerWindow) else {
            return
        }
        do {
            try write(url)
        } catch {
            alert(title: "Breakpoint couldn’t export the history", message: "\(error.localizedDescription)")
        }
    }

    public func confirm(title: String, message: String, confirm: String) -> Bool {
        MessageBoxes.confirm(title: title, message: message, confirm: confirm, owner: Dialogs.ownerWindow)
    }

    public func alert(title: String, message: String) {
        MessageBoxes.alert(title: title, message: message, owner: Dialogs.ownerWindow)
    }

    public func open(_ url: URL) {
        guard url.scheme == "https" else { return }
        _ = ShellExecuteW(nil, "open".wide, url.absoluteString.wide, nil, nil, SW_SHOWNORMAL)
    }

    /// The install folder (`…\Breakpoint`, holding `Breakpoint.exe`).
    public var appLocation: URL { WindowsLoginItem.executable.deletingLastPathComponent() }

    /// `bin\breakpoint.exe` in the install folder; a development build's `breakpoint.exe` next to
    /// the app.
    public var bundledCLI: URL? {
        let folder = appLocation
        for candidate in [folder.appendingPathComponent("bin/breakpoint.exe"), folder.appendingPathComponent("breakpoint.exe")]
            where Executable.isRunnable(candidate) {
            return candidate
        }
        return nil
    }

    public func relaunchHelper(in app: URL) -> URL { app.appendingPathComponent("bin/breakpoint.exe") }

    /// Starts the helper detached from this process (no console, its own process group), so it
    /// outlives the app; it inherits `BREAKPOINT_HOME`.
    public func startRelaunchHelper(_ helper: URL, pid: Int32) throws {
        var command = ("\"" + PathDisplay.native(helper) + "\" update-relaunch --pid \(pid)").wide
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var process = PROCESS_INFORMATION()
        let flags = DWORD(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW)
        guard CreateProcessW(nil, &command, nil, nil, false, flags, nil, nil, &startup, &process) else {
            throw UpdateInstallError.swapFailed(SystemErrorText.describe(Int32(bitPattern: GetLastError())))
        }
        CloseHandle(process.hThread)
        CloseHandle(process.hProcess)
    }

    public func launchDiagnostics() -> String? {
        "tray icon " + (SystemEvents.shared.hwnd == nil ? "not set up" : "set up")
    }
}

/// The save dialog.
enum FileDialogs {
    @MainActor
    static func save(suggestedName: String, filter: (String, String), owner: HWND?) -> URL? {
        var file = [WCHAR](repeating: 0, count: 1024)
        let name = Array(suggestedName.utf16)
        for (i, c) in name.prefix(1000).enumerated() { file[i] = c }
        let filterText = Array("\(filter.0) (\(filter.1))".utf16) + [0] + Array(filter.1.utf16) + [0, 0]
        let extensionText = Array("json".utf16) + [0]
        let picked: Bool = filterText.withUnsafeBufferPointer { filters in
            extensionText.withUnsafeBufferPointer { ext in
                file.withUnsafeMutableBufferPointer { buffer in
                    var dialog = OPENFILENAMEW()
                    dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
                    dialog.hwndOwner = owner
                    dialog.lpstrFilter = filters.baseAddress
                    dialog.lpstrFile = buffer.baseAddress
                    dialog.nMaxFile = DWORD(buffer.count)
                    dialog.lpstrDefExt = ext.baseAddress
                    dialog.Flags = DWORD(OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER)
                    return GetSaveFileNameW(&dialog)
                }
            }
        }
        guard picked else { return nil }
        let length = file.firstIndex(of: 0) ?? file.count
        return URL(fileURLWithPath: String(decoding: file.prefix(length), as: UTF16.self))
    }
}

/// Task dialogs for the two questions the app ever asks, with message boxes as the fallback.
enum MessageBoxes {
    @MainActor
    static func alert(title: String, message: String, owner: HWND?) {
        _ = MessageBoxW(owner, message.wide, title.wide, UINT(MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND))
    }

    @MainActor
    static func confirm(title: String, message: String, confirm: String, owner: HWND?) -> Bool {
        let text = message + "\n\nChoose OK to \(confirm.lowercased())."
        return MessageBoxW(owner, text.wide, title.wide, UINT(MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2 | MB_SETFOREGROUND)) == IDOK
    }
}

extension Dialogs {
    /// The window a dialog belongs to: Breakpoint's own foreground window (Settings) when it has
    /// one, else none (the dialog then stands alone). Never another app's window: a dialog owned
    /// by it would disable that app until answered.
    @MainActor static var ownerWindow: HWND? {
        guard let window = GetForegroundWindow() else { return nil }
        var process: DWORD = 0
        GetWindowThreadProcessId(window, &process)
        return process == GetCurrentProcessId() ? window : nil
    }
}

/// Ends the process if quitting stalls. By the time it is armed everything is saved and stopped;
/// what remains (leaving the message loop, the runtime's exit handlers) has, rarely and on a slow
/// machine, waited forever on a thread that never finishes. After `seconds` the process ends with
/// exit status 0, as a normal quit would.
public enum ExitGuard {
    nonisolated(unsafe) private static var armed = false

    public static func arm(seconds: TimeInterval = 10, status: Int32 = 0) {
        guard !armed else { return }
        armed = true
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: seconds)
            fflush(stdout)
            fflush(stderr)
            TerminateProcess(GetCurrentProcess(), UINT(bitPattern: status))
        }
    }
}
