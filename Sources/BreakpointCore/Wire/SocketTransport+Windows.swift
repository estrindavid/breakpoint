#if os(Windows)
import Foundation
import WinSDK

/// Windows transport for `EventSocketServer`: Winsock `AF_UNIX` sockets driven by one I/O thread
/// that sleeps in `WSAWaitForMultipleEvents` until a socket is ready, a reply is queued, a
/// connection's idle time runs out or the server stops. No polling interval, no busy loop.
///
/// A wait covers at most 64 handles (`WSA_MAXIMUM_WAIT_EVENTS`): the wake event, the listener and
/// up to 62 connections. Past that, further clients wait in the listen queue (as on macOS).
final class SocketTransport: @unchecked Sendable {
    let socketPath: SocketPath
    let idleTimeout: TimeInterval
    let maxConnections: Int
    private let onLine: (Data, ReplyChannel) -> Void

    /// Guards everything the I/O thread shares with other threads.
    private let lock = NSLock()
    private var queuedReplies: [(Connection, Data?)] = []
    private var stopping = false
    private var openConnections = 0

    private var listener: SOCKET = INVALID_SOCKET
    private var listenEvent: HANDLE?
    private var wakeEvent: HANDLE?
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    private var boundFile: FileIdentity?

    // Owned by the I/O thread.
    private var connections: [Connection] = []

    private static let fdRead: Int32 = 1, fdWrite: Int32 = 2, fdAccept: Int32 = 8, fdClose: Int32 = 32
    private static let waitTimeout = DWORD(258) // WSA_WAIT_TIMEOUT
    private static let waitFailed = DWORD(0xFFFF_FFFF)

    init(socketPath: SocketPath, idleTimeout: TimeInterval, maxConnections: Int,
         onLine: @escaping (Data, ReplyChannel) -> Void) {
        self.socketPath = socketPath
        self.idleTimeout = idleTimeout
        self.maxConnections = max(1, min(maxConnections, Int(WSA_MAXIMUM_WAIT_EVENTS) - 2))
        self.onLine = onLine
    }

    var connectionCount: Int { lock.withLock { openConnections } }

    func start() throws {
        let path = socketPath.path
        guard let address = UnixSocket.address(path) else { throw SocketServerError.pathTooLong(path) }
        do {
            try FileManager.default.createDirectory(at: socketPath.directory, withIntermediateDirectories: true)
        } catch {
            throw SocketServerError.system("mkdir", Int32(bitPattern: GetLastError()))
        }
        try removeStaleSocket(at: path)

        guard let fd = UnixSocket.makeSocket() else { throw SocketServerError.system("socket", UnixSocket.lastError) }
        guard UnixSocket.bind(fd, address) == 0 else {
            let error = UnixSocket.lastError
            UnixSocket.close(fd)
            if error == UnixSocket.addressInUse { throw SocketServerError.alreadyRunning(path) }
            throw SocketServerError.system("bind", error)
        }
        guard UnixSocket.listen(fd, SOMAXCONN) == 0 else {
            let error = UnixSocket.lastError
            UnixSocket.close(fd)
            _ = path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
            throw SocketServerError.system("listen", error)
        }
        boundFile = FileIdentity(path: path)
        listener = fd
        listenEvent = WSACreateEvent()
        wakeEvent = WSACreateEvent()
        _ = WSAEventSelect(fd, listenEvent, Self.fdAccept)

        let thread = Thread { [self] in run() }
        thread.name = "com.breakpointapp.Breakpoint.socket"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    func stop() {
        guard thread != nil else { return }
        lock.withLock { stopping = true }
        _ = WSASetEvent(wakeEvent)
        finished.wait()
        thread = nil
        _ = WSACloseEvent(wakeEvent)
        _ = WSACloseEvent(listenEvent)
        wakeEvent = nil
        listenEvent = nil
        if let bound = boundFile, FileIdentity(path: socketPath.path) == bound {
            _ = socketPath.path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
        }
        boundFile = nil
    }

    deinit { stop() }

    /// Removes a socket file nobody is accepting on (left by a crashed app). A live socket means
    /// another copy is running; anything else at the path is left alone.
    private func removeStaleSocket(at path: String) throws {
        let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        guard attributes != INVALID_FILE_ATTRIBUTES else { return }
        // An AF_UNIX socket file is a reparse point (IO_REPARSE_TAG_AF_UNIX); so is a symbolic link.
        guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0,
              attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0 else {
            throw SocketServerError.pathOccupied(path)
        }
        if case .success(let fd) = UnixSocket.connect(path: path, deadline: Date().addingTimeInterval(0.2), refusedRetry: 0) {
            UnixSocket.close(fd)
            throw SocketServerError.alreadyRunning(path)
        }
        _ = path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
    }

    /// Queues a reply line for `connection` (any thread) and wakes the I/O thread.
    fileprivate func queue(_ line: Data?, for connection: Connection) {
        lock.withLock { queuedReplies.append((connection, line)) }
        _ = WSASetEvent(wakeEvent)
    }

    // MARK: The I/O thread

    private func run() {
        defer {
            for connection in connections { connection.close() }
            connections.removeAll()
            lock.withLock { openConnections = 0 }
            UnixSocket.close(listener)
            listener = INVALID_SOCKET
            finished.signal()
        }
        var handles: [HANDLE?] = []
        while true {
            if lock.withLock({ stopping }) { return }
            handles.removeAll(keepingCapacity: true)
            handles.append(wakeEvent)
            let accepting = connections.count < maxConnections
            if accepting { handles.append(listenEvent) }
            for connection in connections { handles.append(connection.event) }

            let timeout = nextTimeout()
            let result = handles.withUnsafeBufferPointer {
                WSAWaitForMultipleEvents(DWORD($0.count), $0.baseAddress, false, timeout, false)
            }
            if result == Self.waitFailed { Sleep(1) }

            _ = WSAResetEvent(wakeEvent)
            deliverQueuedReplies()
            if accepting { acceptPending() }
            for connection in connections where !connection.closed { connection.service() }
            expireIdleConnections()
            let before = connections.count
            connections.removeAll { $0.closed }
            if connections.count != before { lock.withLock { openConnections = connections.count } }
        }
    }

    /// Milliseconds until the earliest idle deadline, or forever.
    private func nextTimeout() -> DWORD {
        guard let earliest = connections.map(\.idleDeadline).min() else { return INFINITE }
        let milliseconds = (earliest.timeIntervalSinceNow * 1000).rounded(.up)
        return DWORD(max(0, min(milliseconds, Double(Int32.max))))
    }

    private func deliverQueuedReplies() {
        let replies = lock.withLock { () -> [(Connection, Data?)] in
            defer { queuedReplies.removeAll() }
            return queuedReplies
        }
        for (connection, line) in replies {
            connection.pendingReplies -= 1
            if let line { connection.send(line) } else { connection.closeIfDone() }
        }
    }

    private func acceptPending() {
        var events = WSANETWORKEVENTS()
        guard WSAEnumNetworkEvents(listener, listenEvent, &events) == 0,
              events.lNetworkEvents & Self.fdAccept != 0 else { return }
        while connections.count < maxConnections, let fd = UnixSocket.accept(listener) {
            let connection = Connection(fd: fd, transport: self)
            connection.onLine = { [weak self, unowned connection] line in self?.onLine(line, connection) }
            _ = WSAEventSelect(fd, connection.event, Self.fdRead | Self.fdWrite | Self.fdClose)
            connections.append(connection)
            // Data may already be waiting; FD_READ is re-signalled only after a recv.
            connection.readAvailable()
        }
        lock.withLock { openConnections = connections.count }
    }

    private func expireIdleConnections() {
        let now = Date()
        for connection in connections where !connection.closed && connection.idleDeadline <= now {
            if connection.pendingReplies > 0 {
                connection.touch()
            } else {
                connection.close()
            }
        }
    }

    /// One accepted connection. Every method except `finishReply` runs on the I/O thread.
    fileprivate final class Connection: ReplyChannel {
        let fd: SOCKET
        let event: HANDLE?
        /// Weak: a reply can arrive from the delivery queue after the server stopped.
        weak var transport: SocketTransport?
        let idleTimeout: TimeInterval
        var onLine: ((Data) -> Void)?
        var pendingReplies = 0
        var idleDeadline: Date
        private(set) var closed = false
        private var lines = LineSplitter()
        private var outgoing = Data()
        private var peerClosed = false

        init(fd: SOCKET, transport: SocketTransport) {
            self.fd = fd
            self.transport = transport
            event = WSACreateEvent()
            idleTimeout = transport.idleTimeout
            idleDeadline = Date().addingTimeInterval(transport.idleTimeout)
        }

        func touch() { idleDeadline = Date().addingTimeInterval(idleTimeout) }

        func beginReply() { pendingReplies += 1 }

        func finishReply(_ line: Data?) { transport?.queue(line, for: self) }

        /// After a wake: read what arrived, write what is pending.
        func service() {
            var events = WSANETWORKEVENTS()
            guard WSAEnumNetworkEvents(fd, event, &events) == 0 else {
                close()
                return
            }
            if events.lNetworkEvents & (SocketTransport.fdRead | SocketTransport.fdClose) != 0 { readAvailable() }
            if !closed, events.lNetworkEvents & SocketTransport.fdWrite != 0 { flush() }
        }

        func readAvailable() {
            guard !closed, !peerClosed else { return }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = chunk.withUnsafeMutableBytes { UnixSocket.read(fd, $0.baseAddress!, $0.count) }
                if n > 0 {
                    touch()
                    let complete = chunk.withUnsafeBytes { lines.consume(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                    for line in complete {
                        onLine?(line)
                        if closed { return }
                    }
                } else if n == 0 {
                    peerFinished()
                    return
                } else {
                    let error = UnixSocket.lastError
                    if error == UnixSocket.eintr { continue }
                    if error == UnixSocket.wouldBlock { return }
                    close()
                    return
                }
            }
        }

        private func peerFinished() {
            if let line = lines.finish() { onLine?(line) }
            peerClosed = true
            closeIfDone()
        }

        func send(_ data: Data) {
            guard !closed else { return }
            outgoing.append(data)
            flush()
        }

        private func flush() {
            while !outgoing.isEmpty {
                let n = outgoing.withUnsafeBytes { UnixSocket.write(fd, $0.baseAddress!, $0.count) }
                if n > 0 {
                    outgoing.removeFirst(n)
                    touch()
                } else if n < 0, UnixSocket.isRetryable(UnixSocket.lastError) {
                    return  // FD_WRITE wakes the loop when there is room again.
                } else {
                    close()
                    return
                }
            }
            closeIfDone()
        }

        func closeIfDone() {
            if peerClosed, outgoing.isEmpty, pendingReplies == 0 { close() }
        }

        func close() {
            guard !closed else { return }
            closed = true
            _ = WSAEventSelect(fd, nil, 0)
            // A graceful end of stream, so the peer reads 0 bytes rather than a reset.
            _ = shutdown(fd, Int32(SD_BOTH))
            UnixSocket.close(fd)
            _ = WSACloseEvent(event)
            onLine = nil
        }
    }
}

/// A file's identity (volume and index), so `stop()` removes only the socket file it created.
struct FileIdentity: Equatable {
    let volume: DWORD
    let indexHigh: DWORD
    let indexLow: DWORD

    init?(path: String) {
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
                        DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { return nil }
        volume = info.dwVolumeSerialNumber
        indexHigh = info.nFileIndexHigh
        indexLow = info.nFileIndexLow
    }
}
#endif
