import Foundation

/// Why `EventSocketServer.start()` failed.
public enum SocketServerError: Error, Equatable, Sendable {
    /// Another process is already accepting on the socket (another copy of the app).
    case alreadyRunning(String)
    /// Something that is not a socket sits at the socket path; it was left alone.
    case pathOccupied(String)
    /// The path is longer than a Unix socket allows.
    case pathTooLong(String)
    /// A system call failed (`call`, `errno` or the Winsock error).
    case system(String, Int32)
}

/// The app's end of the socket (SPEC §5.1, §6). No AppKit.
///
/// Contract:
/// - `start()` creates the socket directory (0700 on macOS; the user's own profile folder on
///   Windows), removes a stale socket file (one nobody answers on; a live one makes `start()` throw
///   `.alreadyRunning`, anything that is not a socket `.pathOccupied`), binds a `SOCK_STREAM` Unix
///   socket at `socketPath` (mode 0600 on macOS) and accepts in the background. Throws if binding
///   fails.
/// - Each connection may carry several lines; each line ≤ `WireMessage.maxLineBytes` is decoded
///   with `WireMessage.decode`. Malformed lines, unknown kinds, other protocol versions and
///   oversized lines are dropped without error; the connection stays usable. A final line without
///   a newline is decoded when the peer closes.
/// - macOS: peers whose uid (`getpeereid`) differs from the server's are closed immediately.
///   Windows: the socket file's ACL (inherited from the user's `%LOCALAPPDATA%`) admits only the
///   same user, so no other account can connect.
/// - `.event` messages are delivered to `onEvent` on `deliveryQueue`, in arrival order per
///   connection.
/// - `.statusRequest` calls `statusProvider` on `deliveryQueue` and writes one `.statusReply` line
///   back on that connection (a minimal report if no provider is set).
/// - `.command` calls `commandHandler` on `deliveryQueue` and writes one `.reply` line back (a
///   reply saying the command is unknown if no handler is set; text longer than a line allows is
///   cut to fit).
/// - Connections idle for `idleTimeout` (and not waiting for a reply) are closed; at most
///   `maxConnections` are open at once (further clients wait in the listen queue until one closes,
///   so no event is lost).
/// - `stop()` closes every connection and removes the socket file (only if it is still the one this
///   server created). Safe to call twice; `start()` may be called again afterwards.
/// - Never blocks the delivery queue on socket I/O. `onEvent` and `statusProvider` may be set
///   before or after `start()`, from any thread.
///
/// The transport (`SocketTransport`) is POSIX sockets with Dispatch sources on macOS and one
/// Winsock event loop thread on Windows; everything above the byte stream is shared.
public final class EventSocketServer: @unchecked Sendable {
    public let socketPath: SocketPath
    public let deliveryQueue: DispatchQueue

    private let lock = NSLock()
    private var _onEvent: ((AgentEvent) -> Void)?
    private var _statusProvider: (() -> StatusReport)?
    private var _commandHandler: ((String, [String]) -> String)?
    private var _isRunning = false
    private var transport: SocketTransport?

    /// Called on `deliveryQueue` for each decoded event.
    public var onEvent: ((AgentEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    /// Called on `deliveryQueue` to answer a status request.
    public var statusProvider: (() -> StatusReport)? {
        get { lock.withLock { _statusProvider } }
        set { lock.withLock { _statusProvider = newValue } }
    }

    /// Called on `deliveryQueue` to answer a `.command` (name, arguments) with plain text.
    public var commandHandler: ((String, [String]) -> String)? {
        get { lock.withLock { _commandHandler } }
        set { lock.withLock { _commandHandler = newValue } }
    }

    public private(set) var isRunning: Bool {
        get { lock.withLock { _isRunning } }
        set { lock.withLock { _isRunning = newValue } }
    }

    /// Seconds a connection may stay silent before it is closed.
    public var idleTimeout: TimeInterval = 5
    /// Open connections allowed at once.
    public var maxConnections = 64

    public init(socketPath: SocketPath, deliveryQueue: DispatchQueue = .main) {
        self.socketPath = socketPath
        self.deliveryQueue = deliveryQueue
    }

    deinit {
        transport?.stop()
    }

    public func start() throws {
        let started: Bool = try lock.withLock {
            guard transport == nil else { return false }
            let transport = SocketTransport(socketPath: socketPath, idleTimeout: idleTimeout,
                                            maxConnections: maxConnections) { [weak self] line, channel in
                self?.handle(line, from: channel)
            }
            try transport.start()
            self.transport = transport
            return true
        }
        _ = started
        isRunning = true
    }

    public func stop() {
        let running = lock.withLock { () -> SocketTransport? in
            defer { transport = nil }
            return transport
        }
        running?.stop()
        isRunning = false
    }

    /// Number of open connections (for tests).
    var connectionCount: Int { lock.withLock { transport }?.connectionCount ?? 0 }

    // MARK: Messages (shared by every transport)

    /// Called by the transport, on its I/O thread, for each complete line of a connection.
    private func handle(_ line: Data, from channel: ReplyChannel) {
        guard let message = try? WireMessage.decode(line: line) else { return }
        switch message {
        case .event(let event):
            deliveryQueue.async { [weak self] in self?.onEvent?(event) }
        case .statusRequest:
            channel.beginReply()
            deliveryQueue.async { [weak self] in
                guard let self else {
                    channel.finishReply(nil)
                    return
                }
                let report = self.statusProvider?() ?? StatusReport(generatedAt: Date())
                channel.finishReply(Self.replyLine(report))
            }
        case .command(let name, let arguments):
            channel.beginReply()
            deliveryQueue.async { [weak self] in
                guard let self else {
                    channel.finishReply(nil)
                    return
                }
                let text = self.commandHandler?(name, arguments) ?? "Unknown command \(name)."
                channel.finishReply(Self.replyLine(text: text))
            }
        case .statusReply, .reply:
            break
        }
    }

    /// A `.reply` line; text that does not fit in one line is cut to fit.
    static func replyLine(text: String) -> Data {
        if let line = try? WireMessage.reply(text).encodedLine() { return line }
        var cut = String(text.prefix(WireMessage.maxLineBytes / 2))
        while !cut.isEmpty {
            if let line = try? WireMessage.reply(cut + "\n[cut]").encodedLine() { return line }
            cut = String(cut.prefix(cut.count * 3 / 4))
        }
        return (try? WireMessage.reply("").encodedLine()) ?? Data()
    }

    /// The reply line; trims sessions and commands if the full report exceeds the line limit.
    static func replyLine(_ report: StatusReport) -> Data {
        if let line = try? WireMessage.statusReply(report).encodedLine() { return line }
        var trimmed = report
        trimmed.sessions = []
        trimmed.commands = []
        return (try? WireMessage.statusReply(trimmed).encodedLine()) ?? Data()
    }
}

/// One connection, as the shared message handling sees it. `beginReply` is called on the
/// transport's I/O thread when a request arrives (the connection then stays open past its idle
/// timeout); `finishReply` may be called from any thread, exactly once per `beginReply`, with the
/// line to write (nil: nothing to write).
protocol ReplyChannel: AnyObject {
    func beginReply()
    func finishReply(_ line: Data?)
}
