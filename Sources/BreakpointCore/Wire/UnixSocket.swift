import Foundation

/// Small POSIX helpers shared by the socket server and client. No AppKit, no Dispatch.
enum UnixSocket {
    enum ConnectError: Error, Equatable {
        /// No socket file.
        case missing
        /// A socket file nobody is listening on.
        case refused
        case timedOut
        case failed(Int32)
    }

    /// A `sockaddr_un` for `path`, or nil if the path does not fit (103 bytes).
    static func address(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A non-blocking, close-on-exec stream socket with SIGPIPE disabled.
    static func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configure(fd)
        return fd
    }

    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func bind(_ fd: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Connects to `path` before `deadline`. A refused connection (a full listen queue looks the
    /// same as a dead socket file) is retried for at most `refusedRetry` seconds.
    static func connect(path: String, deadline: Date, refusedRetry: TimeInterval = 0.02) -> Result<Int32, ConnectError> {
        guard let address = address(path) else { return .failure(.missing) }
        let refusedUntil = min(deadline, Date().addingTimeInterval(refusedRetry))
        while true {
            guard let fd = makeSocket() else { return .failure(.failed(errno)) }
            var address = address
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return .success(fd) }
            let error = errno
            if error == EINPROGRESS || error == EINTR {
                if waitFor(fd, events: Int16(POLLOUT), until: deadline) {
                    var soError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
                    if soError == 0 { return .success(fd) }
                    close(fd)
                    if soError == ECONNREFUSED { return .failure(.refused) }
                    return .failure(.failed(soError))
                }
                close(fd)
                return .failure(.timedOut)
            }
            close(fd)
            switch error {
            case ENOENT, ENOTDIR:
                return .failure(.missing)
            case ECONNREFUSED where Date() < refusedUntil, EAGAIN where Date() < deadline:
                usleep(1_000)
                continue
            case ECONNREFUSED:
                return .failure(.refused)
            case EAGAIN:
                return .failure(.timedOut)
            default:
                return .failure(.failed(error))
            }
        }
    }

    /// Waits until `fd` is ready for `events` or the deadline passes.
    static func waitFor(_ fd: Int32, events: Int16, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&pfd, 1, Int32(max(1, (remaining * 1000).rounded(.up))))
            if ready > 0 { return true }
            if ready == 0 { continue }
            if errno != EINTR { return false }
        }
    }

    /// Writes all of `data` before `deadline`. Returns false on error or timeout.
    static func writeAll(_ fd: Int32, _ data: Data, deadline: Date) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EAGAIN || errno == EINTR {
                    guard waitFor(fd, events: Int16(POLLOUT), until: deadline) else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }
}
