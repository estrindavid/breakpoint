import Foundation
import WinSDK

/// The tray app is a GUI program (no console window). When it is asked to print something
/// (`--signals`), it writes to the console it was started from, if any.
public enum Console {
    public static func attachToParent() {
        // Output already redirected to a file or pipe: nothing to do.
        if let out = GetStdHandle(STD_OUTPUT_HANDLE), out != INVALID_HANDLE_VALUE, GetFileType(out) != DWORD(FILE_TYPE_UNKNOWN) {
            return
        }
        guard AttachConsole(DWORD(bitPattern: -1)) else { return } // ATTACH_PARENT_PROCESS
        _ = SetConsoleOutputCP(UINT(CP_UTF8))
        var stream: UnsafeMutablePointer<FILE>?
        _ = freopen_s(&stream, "CONOUT$", "w", stdout)
        _ = freopen_s(&stream, "CONOUT$", "w", stderr)
    }
}
