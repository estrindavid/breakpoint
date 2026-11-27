#if !os(Windows)
import Foundation

/// macOS transport for `EventSocketServer`: a non-blocking `AF_UNIX` listener and connections,
/// each driven by Dispatch read/write sources on one private serial queue.
final class SocketTransport: @unchecked Sendable {
    let socketPath: SocketPath
    let idleTimeout: TimeInterval
    let maxConnections: Int
    private let onLine: (Data, ReplyChannel) -> Void

    private let ioQueue = DispatchQueue(label: "com.breakpointapp.Breakpoint.socket")
    private let ioQueueKey = DispatchSpecificKey<Bool>()
    private var listenSource: DispatchSourceRead?
    private var listenSuspended = false
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var boundFile: (device: dev_t, inode: ino_t)?

    init(socketPath: SocketPath, idleTimeout: TimeInterval, maxConnections: Int,
         onLine: @escaping (Data, ReplyChannel) -> Void) {
        self.socketPath = socketPath
        self.idleTimeout = idleTimeout
        self.maxConnections = maxConnections
        self.onLine = onLine
        ioQueue.setSpecific(key: ioQueueKey, value: true)
    }

    func start() throws {
        try onIOQueue {
            guard listenSource == nil else { return }
            try bindAndListen()
        }
    }

    func stop() {
        onIOQueue { stopOnIOQueue() }
    }

    var connectionCount: Int { onIOQueue { connections.count } }

    private func onIOQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: ioQueueKey) == true { return try body() }
        return try ioQueue.sync(execute: body)
    }

    // MARK: Setup

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
            // nil: nothing more to accept (EAGAIN) or a transient error.
            guard let fd = UnixSocket.accept(listenFD) else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
                close(fd)
                continue
            }
            let connection = Connection(fd: fd, queue: ioQueue, idleTimeout: idleTimeout)
            let id = ObjectIdentifier(connection)
            connection.onLine = { [weak self, unowned connection] line in self?.onLine(line, connection) }
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
}

/// One accepted connection. Every method except `finishReply` runs on the transport's I/O queue.
private final class Connection: ReplyChannel {
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
    private var lines = LineSplitter()
    private var outgoing = Data()
    private var peerClosed = false
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, idleTimeout: TimeInterval) {
        self.fd = fd
        self.queue = queue
        self.idleTimeout = idleTimeout
    }

    func beginReply() {
        pendingReplies += 1
    }

    func finishReply(_ line: Data?) {
        queue.async { [self] in
            pendingReplies -= 1
            if let line { send(line) } else { closeIfDone() }
        }
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
                let complete = chunk.withUnsafeBytes { lines.consume(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                for line in complete {
                    onLine?(line)
                    if closed { return }
                }
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

    private func peerFinished() {
        if let line = lines.finish() { onLine?(line) }
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
#endif
