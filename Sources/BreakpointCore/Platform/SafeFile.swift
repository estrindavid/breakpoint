import Foundation
#if os(Windows)
import WinSDK
#endif

/// Whole-file reads and atomic replacements of Breakpoint's own small files (settings, history,
/// the ledger, `pending-update.json`, …), which the app, the CLI and the update helper share.
///
/// macOS: `Data(contentsOf:)` and `Data.write(to:options: .atomic)`, as before.
///
/// Windows: replacing a file fails while any other handle has it open without `FILE_SHARE_DELETE`
/// (another Breakpoint process reading it, or an antivirus scanner looking at the file just
/// written). So reads open with every share mode, and a replacement retries for a moment on a
/// sharing violation instead of losing the write.
enum SafeFile {
    static func read(_ url: URL) throws -> Data {
        #if os(Windows)
        let handle = PathDisplay.native(url).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            let code = GetLastError()
            if code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND) {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { CloseHandle(handle) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var read: DWORD = 0
            let ok = buffer.withUnsafeMutableBytes { ReadFile(handle, $0.baseAddress, DWORD($0.count), &read, nil) }
            guard ok else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
            if read == 0 { break }
            data.append(buffer, count: Int(read))
        }
        return data
        #else
        return try Data(contentsOf: url)
        #endif
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        #if os(Windows)
        try AtomicFile.write(data, to: url, mode: 0o600)
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    #if os(Windows)
    /// Runs `body` until it succeeds or a short while passes, while it fails because another
    /// handle is in the way (sharing or lock violation, or access denied by a pending delete).
    static func retryingWhileBusy(_ body: () -> Bool) -> Bool {
        for attempt in 0..<40 {
            if body() { return true }
            let error = GetLastError()
            guard error == DWORD(ERROR_SHARING_VIOLATION) || error == DWORD(ERROR_LOCK_VIOLATION)
                    || error == DWORD(ERROR_ACCESS_DENIED) else { return false }
            Sleep(DWORD(min(5 + attempt * 5, 50)))
        }
        return false
    }
    #endif
}
