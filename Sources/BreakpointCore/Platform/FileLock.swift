import Foundation
#if os(Windows)
import WinSDK
#endif

/// An exclusive, blocking, cross-process lock on a lock file (created if missing), held until
/// `unlock()`. `flock` on macOS, `LockFileEx` on Windows. Best effort: if the file cannot be
/// opened the caller proceeds unlocked, as before.
final class FileLock {
    #if os(Windows)
    private var handle: HANDLE?
    #else
    private var fd: Int32 = -1
    #endif

    init(_ url: URL) {
        #if os(Windows)
        let opened = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else { return }
        var overlapped = OVERLAPPED()
        if LockFileEx(opened, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, 1, 0, &overlapped) {
            handle = opened
        } else {
            CloseHandle(opened)
        }
        #else
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 {
            while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        }
        #endif
    }

    func unlock() {
        #if os(Windows)
        guard let handle else { return }
        var overlapped = OVERLAPPED()
        _ = UnlockFileEx(handle, 0, 1, 0, &overlapped)
        CloseHandle(handle)
        self.handle = nil
        #else
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
        #endif
    }

    deinit { unlock() }
}

#if os(Windows)
/// Windows error codes in the system's own words.
enum WindowsError {
    static func message(_ code: DWORD) -> String {
        var buffer: UnsafeMutablePointer<WCHAR>?
        let flags = DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS)
        let length = withUnsafeMutablePointer(to: &buffer) { pointer in
            pointer.withMemoryRebound(to: WCHAR.self, capacity: 1) {
                FormatMessageW(flags, nil, code, 0, $0, 0, nil)
            }
        }
        guard length > 0, let buffer else { return "error \(code)" }
        defer { LocalFree(buffer) }
        let text = String(decoding: UnsafeBufferPointer(start: buffer, count: Int(length)), as: UTF16.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }
}

/// What the installers need to know about a file on NTFS.
struct WindowsFileInfo {
    let isReadOnly: Bool
    let links: Int

    init?(path: String) {
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
                        DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { return nil }
        isReadOnly = info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_READONLY) != 0
        links = Int(info.nNumberOfLinks)
    }
}
#endif
