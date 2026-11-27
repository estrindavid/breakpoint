import Foundation

/// Why `EventSocketServer.start()` failed.
public enum SocketServerError: Error, Equatable, Sendable {
    /// Another process is already accepting on the socket (another copy of the app).
    case alreadyRunning(String)
    /// Something that is not a socket sits at the socket path; it was left alone.
    case pathOccupied(String)
    /// The path is longer than a Unix socket allows.
    case pathTooLong(String)
    /// A system call failed (`call`, `errno`).
    case system(String, Int32)
}

/// The app's end of the socket (SPEC §5.1, §6). POSIX only, no AppKit.
///
/// Contract:
/// - `start()` creates the socket directory (0700), removes a stale socket file (one nobody
///   answers on; a live one makes `start()` throw `.alreadyRunning`, anything that is not a socket
///   `.pathOccupied`), binds a `SOCK_STREAM` Unix socket at `socketPath` (mode 0600) and accepts on
///   a private background queue. Throws if binding fails.
/// - Each connection may carry several lines; each line ≤ `WireMessage.maxLineBytes` is decoded
///   with `WireMessage.decode`. Malformed lines, unknown kinds, other protocol versions and
///   oversized lines are dropped without error; the connection stays usable. A final line without
///   a newline is decoded when the peer closes.
/// - Peers whose uid (`getpeereid`) differs from the server's are closed immediately.
/// - `.event` messages are delivered to `onEvent` on `deliveryQueue`, in arrival order per
///   connection.
/// - `.statusRequest` calls `statusProvider` on `deliveryQueue` and writes one `.statusReply` line
///   back on that connection (a minimal report if no provider is set).
/// - `.command` calls `commandHandler` on `deliveryQueue` and writes one `.reply` line back (a
///   reply saying the command is unknown if no handler is set; text longer than a line allows is
///   cut to fit).
/// - Connections idle for `idleTimeout` (and not waiting for a reply) are closed; at most `maxConnections` are open at once
///   (further clients wait in the listen queue until one closes, so no event is lost).
/// - `stop()` closes every connection and removes the socket file (only if it is still the one this
///   server created). Safe to call twice; `start()` may be called again afterwards.
/// - Never blocks the delivery queue on socket I/O. `onEvent` and `statusProvider` may be set
///   before or after `start()`, from any thread.
public final class EventSocketServer: @unchecked Sendable {
    public let socketPath: SocketPath
    public let deliveryQueue: DispatchQueue

    private let lock = NSLock()
    private var _onEvent: ((AgentEvent) -> Void)?
    private var _statusProvider: (() -> StatusReport)?
    private var _commandHandler: ((String, [String]) -> String)?
    private var _isRunning = false

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

    private let ioQueue = DispatchQueue(label: "com.breakpointapp.Breakpoint.socket")
    private let ioQueueKey = DispatchSpecificKey<Bool>()
    private var listenSource: DispatchSourceRead?
    private var listenSuspended = false
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var boundFile: (device: dev_t, inode: ino_t)?

    public init(socketPath: SocketPath, deliveryQueue: DispatchQueue = .main) {
        self.socketPath = socketPath
        self.deliveryQueue = deliveryQueue
        ioQueue.setSpecific(key: ioQueueKey, value: true)
    }

    deinit {
        onIOQueue { stopOnIOQueue() }
    }

    public func start() throws {
        try onIOQueue {
            guard listenSource == nil else { return }
            try bindAndListen()
        }
        isRunning = true
    }

    public func stop() {
        onIOQueue { stopOnIOQueue() }
        isRunning = false
    }

    /// Number of open connections (for tests).
    var connectionCount: Int { onIOQueue { connections.count } }

    // MARK: Setup

    private func onIOQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: ioQueueKey) == true { return try body() }
        return try ioQueue.sync(execute: body)
    }

    private func bindAndListen() throws {
        let path = socketPath.path
        guard let address = UnixSocket.address(path) else { throw SocketServerError.pathTooLong(path) }
        try prepareDirectory()
        try removeStaleSocket(at: path)

        guard let fd = UnixSocket.makeSocket() else { throw SocketServerError.system("socket", errno) }
        guard UnixSocket.bind(fd, address) == 0 else {
            let error = errno
            close(fd)
            if error == EADDRINUSE { throw SocketServerError.alreadyRunning(path) }
            throw SocketServerError.system("bind", error)
        }
        // Owner-only. The 0700 directory and the uid check below also keep other users out.
        chmod(path, 0o600)
        guard listen(fd, SOMAXCONN) == 0 else {
            let error = errno
            close(fd)
            unlink(path)
            throw SocketServerError.system("listen", error)
        }
        var info = stat()
        if lstat(path, &info) == 0 { boundFile = (info.st_dev, info.st_ino) }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        listenSource = source
        source.resume()
    }

    private func prepareDirectory() throws {
        let directory = socketPath.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw SocketServerError.system("mkdir", errno)
        }
        var info = stat()
        if stat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 != 0 {
            chmod(directory.path, 0o700)
        }
    }

    /// Removes a socket file nobody is accepting on (left by a crashed app). A live socket means
    /// another copy is running; anything else at the path is left alone.
    private func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        switch info.st_mode & S_IFMT {
        case S_IFSOCK:
            switch UnixSocket.connect(path: path, deadline: Date().addingTimeInterval(0.2), refusedRetry: 0) {
            case .success(let fd):
                close(fd)
                throw SocketServerError.alreadyRunning(path)
            default:
                unlink(path)
            }
        case S_IFLNK:
            unlink(path)
        default:
            throw SocketServerError.pathOccupied(path)
        }
    }

    private func stopOnIOQueue() {
        if listenSuspended {
            listenSource?.resume()
            listenSuspended = false
        }
        listenSource?.cancel()
        listenSource = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
        if let bound = boundFile {
            var info = stat()
            if lstat(socketPath.path, &info) == 0, info.st_dev == bound.device, info.st_ino == bound.inode {
                unlink(socketPath.path)
            }
            boundFile = nil
        }
    }

    // MARK: Connections

    private func acceptPending(_ listenFD: Int32) {
        while true {
            if connections.count >= maxConnections {
                // Leave further clients in the listen queue until a connection closes.
                if !listenSuspended, let listenSource {
                    listenSource.suspend()
                    listenSuspended = true
                }
                return
            }
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return  // EAGAIN: nothing more to accept (or a transient error)
            }
            UnixSocket.configure(fd)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
                close(fd)
                continue
            }
            let connection = Connection(fd: fd, queue: ioQueue, idleTimeout: idleTimeout)
            let id = ObjectIdentifier(connection)
            connection.onLine = { [weak self] line in self?.handle(line, from: connection) }
            connection.onClose = { [weak self] in
                guard let self else { return }
                self.connections[id] = nil
                if self.listenSuspended, let listenSource = self.listenSource {
                    self.listenSuspended = false
                    listenSource.resume()
                }
            }
            connections[id] = connection
            connection.start()
        }
    }

    private func handle(_ line: Data, from connection: Connection) {
        guard let message = try? WireMessage.decode(line: line) else { return }
        switch message {
        case .event(let event):
            deliveryQueue.async { [weak self] in self?.onEvent?(event) }
        case .statusRequest:
            connection.pendingReplies += 1
            deliveryQueue.async { [weak self] in
                guard let self else { return }
                let report = self.statusProvider?() ?? StatusReport(generatedAt: Date())
                let reply = Self.replyLine(report)
                self.ioQueue.async {
                    connection.pendingReplies -= 1
                    connection.send(reply)
                }
            }
        case .command(let name, let arguments):
            connection.pendingReplies += 1
            deliveryQueue.async { [weak self] in
                guard let self else { return }
                let text = self.commandHandler?(name, arguments) ?? "Unknown command \(name)."
                let reply = Self.replyLine(text: text)
                self.ioQueue.async {
                    connection.pendingReplies -= 1
                    connection.send(reply)
                }
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

/// One accepted connection. Every method runs on the server's I/O queue.
private final class Connection {
    let fd: Int32
    let queue: DispatchQueue
    let idleTimeout: TimeInterval
    var onLine: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var pendingReplies = 0

    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var idleTimer: DispatchSourceTimer?
    private var openSources = 0
    private var buffer = Data()
    private var discarding = false
    private var outgoing = Data()
    private var peerClosed = false
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, idleTimeout: TimeInterval) {
        self.fd = fd
        self.queue = queue
        self.idleTimeout = idleTimeout
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        retainSource(source)
        readSource = source
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.idleTimerFired() }
        idleTimer = timer
        resetIdleTimer()
        timer.resume()
        source.resume()
    }

    /// The descriptor is closed once the connection is closed and every source on it is cancelled.
    private func retainSource(_ source: DispatchSourceProtocol) {
        openSources += 1
        source.setCancelHandler { [self] in
            openSources -= 1
            closeDescriptorIfPossible()
        }
    }

    private var descriptorClosed = false

    private func closeDescriptorIfPossible() {
        guard closed, openSources == 0, !descriptorClosed else { return }
        descriptorClosed = true
        Darwin.close(fd)
    }

    private func resetIdleTimer() {
        idleTimer?.schedule(deadline: .now() + idleTimeout)
    }

    /// Silent for `idleTimeout`: closed, unless the app is still working on a reply for it.
    private func idleTimerFired() {
        if pendingReplies > 0 {
            resetIdleTimer()
        } else {
            close()
        }
    }

    private func readAvailable() {
        guard !closed else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                resetIdleTimer()
                consume(chunk[0..<n])
                if closed { return }
            } else if n == 0 {
                peerFinished()
                return
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                close()
                return
            }
        }
    }

    private func consume(_ bytes: ArraySlice<UInt8>) {
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 0x0A) {
            let piece = bytes[start..<newline]
            if discarding {
                discarding = false
                buffer.removeAll()
            } else {
                buffer.append(contentsOf: piece)
                let line = buffer
                buffer = Data()
                if line.count <= WireMessage.maxLineBytes, !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) {
                    onLine?(line)
                }
            }
            start = newline + 1
        }
        guard !discarding else { return }
        buffer.append(contentsOf: bytes[start...])
        if buffer.count > WireMessage.maxLineBytes {
            // Oversized: drop everything up to the next newline.
            buffer = Data()
            discarding = true
        }
    }

    private func peerFinished() {
        if !discarding, !buffer.isEmpty, buffer.count <= WireMessage.maxLineBytes {
            let line = buffer
            buffer = Data()
            onLine?(line)
        }
        peerClosed = true
        readSource?.cancel()
        readSource = nil
        closeIfDone()
    }

    func send(_ data: Data) {
        guard !closed else { return }
        outgoing.append(data)
        flush()
    }

    private func flush() {
        while !outgoing.isEmpty {
            let n = outgoing.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress!, raw.count) }
            if n > 0 {
                outgoing.removeFirst(n)
                resetIdleTimer()
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    retainSource(source)
                    writeSource = source
                    source.resume()
                }
                return
            } else {
                close()
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
        closeIfDone()
    }

    private func closeIfDone() {
        if peerClosed, outgoing.isEmpty, pendingReplies == 0 { close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        idleTimer = nil
        readSource?.cancel()
        writeSource?.cancel()
        readSource = nil
        writeSource = nil
        closeDescriptorIfPossible()
        onClose?()
        onClose = nil
        onLine = nil
    }
}
