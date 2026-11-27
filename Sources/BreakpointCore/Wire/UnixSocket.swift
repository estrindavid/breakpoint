import Foundation
#if os(Windows)
import WinSDK
#endif

/// Small socket helpers shared by the socket server and client. No AppKit, no Dispatch.
///
/// One API over two transports, so the wire format and every contract stay identical:
/// - macOS: POSIX `AF_UNIX` stream sockets.
/// - Windows: Winsock `AF_UNIX` stream sockets (Windows 10 1803 and later). The socket is a file
///   in the user's own `%LOCALAPPDATA%\Breakpoint`, whose ACL admits only that user (and the
///   system); see SPEC §5.1.
enum UnixSocket {
    enum ConnectError: Error, Equatable {
        /// No socket file.
        case missing
        /// A socket file nobody is listening on.
        case refused
        case timedOut
        case failed(Int32)
    }

    #if os(Windows)
    typealias Handle = SOCKET
    static let invalid: Handle = INVALID_SOCKET
    #else
    typealias Handle = Int32
    static let invalid: Handle = -1
    #endif

    /// `poll` event masks, named the same on both platforms.
    #if os(Windows)
    static let pollIn = Int16(POLLRDNORM)
    static let pollOut = Int16(POLLWRNORM)
    #else
    static let pollIn = Int16(POLLIN)
    static let pollOut = Int16(POLLOUT)
    #endif

    /// A `sockaddr_un` for `path`, or nil if the path does not fit (103 bytes).
    static func address(_ path: String) -> sockaddr_un? {
        #if os(Windows)
        // Winsock wants the Win32 form of the path (backslashes).
        let bytes = Array(path.replacingOccurrences(of: "/", with: "\\").utf8)
        #else
        let bytes = Array(path.utf8)
        #endif
        var address = sockaddr_un()
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path), bytes.count <= SocketPath.maxBytes else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        #if !os(Windows)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }

    /// A non-blocking stream socket (close-on-exec and SIGPIPE disabled where those exist).
    static func makeSocket() -> Handle? {
        startUp()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd != invalid else { return nil }
        configure(fd)
        return fd
    }

    static func configure(_ fd: Handle) {
        #if os(Windows)
        var nonBlocking: u_long = 1
        _ = ioctlsocket(fd, fionbio, &nonBlocking)
        #else
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func bind(_ fd: Handle, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                WinSDK.bind(fd, $0, Int32(MemoryLayout<sockaddr_un>.size))
                #else
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
    }

    static func listen(_ fd: Handle, _ backlog: Int32) -> Int32 {
        #if os(Windows)
        WinSDK.listen(fd, backlog)
        #else
        Darwin.listen(fd, backlog)
        #endif
    }

    /// Accepts one pending connection, configured like `makeSocket`'s; nil when none is waiting.
    static func accept(_ fd: Handle) -> Handle? {
        while true {
            #if os(Windows)
            let client = WinSDK.accept(fd, nil, nil)
            #else
            let client = Darwin.accept(fd, nil, nil)
            #endif
            if client != invalid {
                configure(client)
                return client
            }
            if lastError == eintr { continue }
            return nil
        }
    }

    static func close(_ fd: Handle) {
        #if os(Windows)
        _ = closesocket(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }

    /// Bytes read (0 at end of stream), or -1 with `lastError` set.
    static func read(_ fd: Handle, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if os(Windows)
        Int(recv(fd, buffer.assumingMemoryBound(to: CChar.self), Int32(clamping: count), 0))
        #else
        Darwin.read(fd, buffer, count)
        #endif
    }

    /// Bytes written, or -1 with `lastError` set.
    static func write(_ fd: Handle, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if os(Windows)
        Int(send(fd, buffer.assumingMemoryBound(to: CChar.self), Int32(clamping: count), 0))
        #else
        Darwin.write(fd, buffer, count)
        #endif
    }

    /// The last socket error (`errno`, or `WSAGetLastError()` on Windows).
    static var lastError: Int32 {
        #if os(Windows)
        WSAGetLastError()
        #else
        errno
        #endif
    }

    #if os(Windows)
    static let eintr = Int32(WSAEINTR)
    static let wouldBlock = Int32(WSAEWOULDBLOCK)
    static let inProgress = Int32(WSAEINPROGRESS)
    static let refused = Int32(WSAECONNREFUSED)
    static let addressInUse = Int32(WSAEADDRINUSE)
    /// `FIONBIO` (`_IOW('f', 126, u_long)`), which Swift does not import.
    private static let fionbio = Int32(bitPattern: 0x8004_667E)
    #else
    static let eintr = EINTR
    static let wouldBlock = EAGAIN
    static let inProgress = EINPROGRESS
    static let refused = ECONNREFUSED
    static let addressInUse = EADDRINUSE
    #endif

    static func isRetryable(_ error: Int32) -> Bool { error == wouldBlock || error == eintr }

    /// Winsock needs `WSAStartup` once per process; a no-op elsewhere.
    static func startUp() {
        #if os(Windows)
        _ = winsockStarted
        #endif
    }

    #if os(Windows)
    private static let winsockStarted: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()
    #endif

    /// Connects to `path` before `deadline`. A refused connection (a full listen queue looks the
    /// same as a dead socket file) is retried for at most `refusedRetry` seconds.
    static func connect(path: String, deadline: Date, refusedRetry: TimeInterval = 0.02) -> Result<Handle, ConnectError> {
        guard let address = address(path) else { return .failure(.missing) }
        #if os(Windows)
        // Winsock reports a missing socket file as a refused connection; tell the two apart first.
        guard socketFileExists(path) else { return .failure(.missing) }
        #endif
        let refusedUntil = min(deadline, Date().addingTimeInterval(refusedRetry))
        while true {
            guard let fd = makeSocket() else { return .failure(.failed(lastError)) }
            var address = address
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                    #if os(Windows)
                    WinSDK.connect(fd, pointer, Int32(MemoryLayout<sockaddr_un>.size))
                    #else
                    Darwin.connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                    #endif
                }
            }
            if result == 0 { return .success(fd) }
            let error = lastError
            if error == inProgress || error == eintr || (isWindows && error == wouldBlock) {
                if waitFor(fd, events: pollOut, until: deadline) {
                    var soError: Int32 = 0
                    var length = socketLength(MemoryLayout<Int32>.size)
                    withUnsafeMutablePointer(to: &soError) { pointer in
                        pointer.withMemoryRebound(to: CChar.self, capacity: 4) {
                            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, $0, &length)
                        }
                    }
                    if soError == 0 { return .success(fd) }
                    close(fd)
                    if soError == refused { return .failure(.refused) }
                    return .failure(.failed(soError))
                }
                close(fd)
                return .failure(.timedOut)
            }
            close(fd)
            switch error {
            case _ where isMissingFileError(error):
                return .failure(.missing)
            case refused where Date() < refusedUntil, wouldBlock where Date() < deadline:
                usleep(1_000)
                continue
            case refused:
                return .failure(.refused)
            case wouldBlock:
                return .failure(.timedOut)
            default:
                return .failure(.failed(error))
            }
        }
    }

    /// Whether anything is at `path`. On Windows `FileManager.fileExists` answers false for an
    /// AF_UNIX socket file (a reparse point it cannot follow), so ask the file system directly.
    static func socketFileExists(_ path: String) -> Bool {
        #if os(Windows)
        let attributes = path.replacingOccurrences(of: "/", with: "\\").withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        return attributes != INVALID_FILE_ATTRIBUTES
        #else
        var info = stat()
        return lstat(path, &info) == 0
        #endif
    }

    static func isSocketFile(_ path: String) -> Bool {
        #if os(Windows)
        let attributes = path.replacingOccurrences(of: "/", with: "\\").withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        return attributes != INVALID_FILE_ATTRIBUTES && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
            && attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
        #else
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
        #endif
    }

    private static var isWindows: Bool {
        #if os(Windows)
        true
        #else
        false
        #endif
    }

    private static func isMissingFileError(_ error: Int32) -> Bool {
        #if os(Windows)
        false
        #else
        error == ENOENT || error == ENOTDIR
        #endif
    }

    #if os(Windows)
    private static func socketLength(_ value: Int) -> Int32 { Int32(value) }
    #else
    private static func socketLength(_ value: Int) -> socklen_t { socklen_t(value) }
    #endif

    /// Waits until `fd` is ready for `events` or the deadline passes.
    static func waitFor(_ fd: Handle, events: Int16, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            let milliseconds = Int32(max(1, (remaining * 1000).rounded(.up)))
            #if os(Windows)
            var pfd = WSAPOLLFD(fd: fd, events: events, revents: 0)
            let ready = WSAPoll(&pfd, 1, milliseconds)
            #else
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&pfd, 1, milliseconds)
            #endif
            if ready > 0 { return true }
            if ready == 0 { continue }
            if lastError != eintr { return false }
        }
    }

    /// Writes all of `data` before `deadline`. Returns false on error or timeout.
    static func writeAll(_ fd: Handle, _ data: Data, deadline: Date) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, isRetryable(lastError) {
                    guard waitFor(fd, events: pollOut, until: deadline) else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }
}

#if os(Windows)
/// `sockaddr_un` from `afunix.h`, which the WinSDK module does not include.
struct sockaddr_un {
    var sun_family: ADDRESS_FAMILY = 0
    var sun_path: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
typealias sa_family_t = ADDRESS_FAMILY

/// `usleep`, which Windows lacks.
func usleep(_ microseconds: UInt32) {
    Sleep(DWORD(max(1, microseconds / 1000)))
}
#endif
