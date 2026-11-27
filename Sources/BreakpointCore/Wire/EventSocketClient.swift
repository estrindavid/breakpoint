import Foundation

/// Errors from `EventSocketClient.request`.
public enum SocketClientError: Error, Equatable, Sendable {
    /// No socket file, or nothing listening (the app is not running).
    case notRunning
    case timedOut
    case badReply
}

/// The CLI's end of the socket (SPEC §5.1, §5.3). POSIX sockets on macOS, Winsock on Windows.
///
/// Contract:
/// - `send` connects and writes one line with a total timeout (default 100 ms), never waits for a
///   reply, never prints, never throws, never starts a child process. Returns whether the line was
///   fully written. Used by `breakpoint emit` (whose p95 target is < 50 ms).
/// - `request` sends one line and reads one reply line (timeout default 1 s). Used by
///   `breakpoint status` and `doctor`.
/// - Ignores `SIGPIPE` for its own writes (`SO_NOSIGPIPE`; Windows has no SIGPIPE).
public enum EventSocketClient {
    @discardableResult
    public static func send(_ message: WireMessage, to socketPath: SocketPath, timeout: TimeInterval = 0.1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        guard let line = try? message.encodedLine() else { return false }
        guard case .success(let fd) = UnixSocket.connect(path: socketPath.path, deadline: deadline) else { return false }
        defer { UnixSocket.close(fd) }
        return UnixSocket.writeAll(fd, line, deadline: deadline)
    }

    public static func request(_ message: WireMessage, to socketPath: SocketPath, timeout: TimeInterval = 1) throws -> WireMessage {
        let deadline = Date().addingTimeInterval(timeout)
        let line: Data
        do {
            line = try message.encodedLine()
        } catch {
            throw SocketClientError.badReply
        }
        let fd: UnixSocket.Handle
        switch UnixSocket.connect(path: socketPath.path, deadline: deadline) {
        case .success(let connected): fd = connected
        case .failure(.timedOut): throw SocketClientError.timedOut
        case .failure: throw SocketClientError.notRunning
        }
        defer { UnixSocket.close(fd) }
        guard UnixSocket.writeAll(fd, line, deadline: deadline) else { throw SocketClientError.timedOut }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let newline = reply.firstIndex(of: 0x0A) {
                reply = reply[..<newline]
                break
            }
            guard reply.count <= WireMessage.maxLineBytes else { throw SocketClientError.badReply }
            let n = buffer.withUnsafeMutableBytes { UnixSocket.read(fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                reply.append(buffer, count: n)
            } else if n == 0 {
                if reply.isEmpty { throw SocketClientError.badReply }
                break
            } else if UnixSocket.isRetryable(UnixSocket.lastError) {
                guard UnixSocket.waitFor(fd, events: UnixSocket.pollIn, until: deadline) else { throw SocketClientError.timedOut }
            } else {
                throw SocketClientError.badReply
            }
        }
        guard let decoded = try? WireMessage.decode(line: Data(reply)) else { throw SocketClientError.badReply }
        return decoded
    }
}
