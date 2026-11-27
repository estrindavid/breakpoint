import Foundation
#if os(Windows)
import WinSDK
#endif

/// The CLI's few direct uses of the process's standard streams, on macOS and on Windows.
enum Console {
    /// Writes to a closed pipe must fail instead of killing the process (POSIX `SIGPIPE`; Windows
    /// has no such signal).
    static func ignoreBrokenPipes() {
        #if !os(Windows)
        signal(SIGPIPE, SIG_IGN)
        #endif
    }

    /// Output lines end in `\n` on every platform (SPEC §5.8: `--version` piped is exactly one
    /// line). The Windows C runtime would otherwise turn each `\n` into `\r\n`; terminals, prompts
    /// and status bars all take a bare `\n`.
    static func useLineFeeds() {
        #if os(Windows)
        _ = _setmode(1, _O_BINARY)
        _ = _setmode(2, _O_BINARY)
        #endif
    }

    /// Standard output is a terminal (not a pipe or a file). On Windows a console, which also gets
    /// virtual-terminal processing switched on so colour sequences render.
    static var stdoutIsTerminal: Bool {
        #if os(Windows)
        guard let handle = GetStdHandle(STD_OUTPUT_HANDLE), handle != INVALID_HANDLE_VALUE,
              GetFileType(handle) == DWORD(FILE_TYPE_CHAR) else { return false }
        var mode: DWORD = 0
        guard GetConsoleMode(handle, &mode) else { return false }
        _ = SetConsoleMode(handle, mode | DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        // Text is printed as UTF-8 (the mark is block characters).
        _ = SetConsoleOutputCP(UINT(CP_UTF8))
        return true
        #else
        return isatty(STDOUT_FILENO) == 1
        #endif
    }

    /// Points stdout and stderr at the null device, so not even a runtime warning can reach a hook.
    static func silenceOutput() {
        #if os(Windows)
        var null: Int32 = -1
        if _sopen_s(&null, "NUL", _O_WRONLY, _SH_DENYNO, _S_IWRITE) == 0, null >= 0 {
            _ = _dup2(null, 1)
            _ = _dup2(null, 2)
            if null > 2 { _ = _close(null) }
        }
        let device = "NUL".withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), 0, nil)
        }
        if let device, device != INVALID_HANDLE_VALUE {
            _ = SetStdHandle(STD_OUTPUT_HANDLE, device)
            _ = SetStdHandle(STD_ERROR_HANDLE, device)
        }
        #else
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard null >= 0 else { return }
        dup2(null, STDOUT_FILENO)
        dup2(null, STDERR_FILENO)
        if null > STDERR_FILENO { close(null) }
        #endif
    }

    /// Reads stdin to EOF, at most `limit` bytes, giving up after `timeout` seconds in total.
    /// Never blocks longer than `timeout`, never reads a terminal, never changes stdin's flags
    /// (the descriptor is shared with the hook runner). Returns what was read (or nil).
    static func readStdin(limit: Int, timeout: TimeInterval) -> Data? {
        #if os(Windows)
        return readStdinWindows(limit: limit, timeout: timeout)
        #else
        let fd = STDIN_FILENO
        guard isatty(fd) == 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            let remainingMS = Int32((deadline.timeIntervalSinceNow * 1000).rounded(.up))
            if remainingMS <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, remainingMS)
            if ready < 0, errno == EINTR { continue }
            if ready <= 0 { break }
            if pfd.revents & Int16(POLLNVAL) != 0 { break }
            // poll said readable (or hung up), so this read does not block.
            let count = read(fd, &buffer, min(buffer.count, limit - data.count))
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                break  // EOF
            } else if errno != EAGAIN && errno != EINTR {
                break
            }
        }
        return data.isEmpty ? nil : data
        #endif
    }

    #if os(Windows)
    /// Windows pipes cannot be polled with a timeout, so a reader thread does blocking `ReadFile`s
    /// while this thread waits at most `timeout`. If time runs out, what arrived so far is used and
    /// the reader is abandoned (the process exits right after `emit`).
    private static func readStdinWindows(limit: Int, timeout: TimeInterval) -> Data? {
        guard let input = GetStdHandle(STD_INPUT_HANDLE), input != INVALID_HANDLE_VALUE else { return nil }
        let type = GetFileType(input)
        guard type == DWORD(FILE_TYPE_PIPE) || type == DWORD(FILE_TYPE_DISK) else { return nil }
        let reader = StdinReader(handle: input, limit: limit)
        let thread = Thread { reader.run() }
        thread.start()
        _ = reader.done.wait(timeout: .now() + timeout)
        let data = reader.snapshot()
        return data.isEmpty ? nil : data
    }

    private final class StdinReader: @unchecked Sendable {
        let handle: HANDLE
        let limit: Int
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var data = Data()

        init(handle: HANDLE, limit: Int) {
            self.handle = handle
            self.limit = limit
        }

        func run() {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while lock.withLock({ data.count }) < limit {
                var read: DWORD = 0
                let wanted = DWORD(min(buffer.count, limit - lock.withLock { data.count }))
                let ok = buffer.withUnsafeMutableBytes { ReadFile(handle, $0.baseAddress, wanted, &read, nil) }
                guard ok, read > 0 else { break }  // EOF, a broken pipe or an error
                lock.withLock { data.append(buffer, count: Int(read)) }
            }
            done.signal()
        }

        func snapshot() -> Data { lock.withLock { data } }
    }
    #endif
}
