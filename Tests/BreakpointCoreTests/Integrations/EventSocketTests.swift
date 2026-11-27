import Foundation
import Testing
@testable import BreakpointCore

/// A running server on a short temporary path, delivering to a private queue.
final class ServerFixture {
    let dir = ShortTemporaryDirectory()
    let queue = DispatchQueue(label: "test.delivery")
    let queueKey = DispatchSpecificKey<Bool>()
    let inbox = EventInbox()
    let server: EventSocketServer
    var socket: SocketPath { server.socketPath }
    private let offQueueLock = NSLock()
    private var _deliveredOffQueue = false
    var deliveredOffQueue: Bool { offQueueLock.withLock { _deliveredOffQueue } }

    init(idleTimeout: TimeInterval = 5, start: Bool = true) throws {
        queue.setSpecific(key: queueKey, value: true)
        server = EventSocketServer(socketPath: SocketPath(paths: dir.paths), deliveryQueue: queue)
        server.idleTimeout = idleTimeout
        let inbox = self.inbox
        let queueKey = self.queueKey
        server.onEvent = { [weak self] event in
            if DispatchQueue.getSpecific(key: queueKey) != true { self?.offQueueLock.withLock { self?._deliveredOffQueue = true } }
            inbox.append(event)
        }
        if start { try server.start() }
    }

    func event(_ kind: AgentEventKind = .agentStarted, session: String = "s1", title: String? = nil) -> AgentEvent {
        AgentEvent(kind: kind, source: .claudeCode, sessionID: session, cwd: "/tmp/project", title: title,
                   timestamp: Date(timeIntervalSince1970: 1_795_400_000))
    }

    /// Connects a raw client.
    func connect() throws -> Int32 {
        switch UnixSocket.connect(path: socket.path, deadline: Date().addingTimeInterval(1)) {
        case .success(let fd): return fd
        case .failure(let error): throw error
        }
    }

    func write(_ fd: Int32, _ text: String) {
        _ = UnixSocket.writeAll(fd, Data(text.utf8), deadline: Date().addingTimeInterval(1))
    }

    func line(_ event: AgentEvent) throws -> String { String(decoding: try WireMessage.event(event).encodedLine(), as: UTF8.self) }

    func tearDown() {
        server.stop()
        dir.cleanup()
    }
}

@Suite("Event socket")
struct EventSocketTests {
    @Test func roundTripOnTheDeliveryQueue() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        #expect(f.server.isRunning)
        let event = f.event(title: "fix the login redirect")
        #expect(EventSocketClient.send(.event(event), to: f.socket))
        #expect(waitUntil { f.inbox.count == 1 })
        #expect(f.inbox.events == [event])
        #expect(!f.deliveredOffQueue)
    }

    @Test func socketAndFolderAreOwnerOnly() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        var info = stat()
        #expect(lstat(f.socket.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(f.socket.directory.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    @Test func manyConcurrentShortLivedClients() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        let count = 200
        let sent = EventInbox()
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let event = f.event(session: "s\(i)")
            if EventSocketClient.send(.event(event), to: f.socket, timeout: 2) { sent.append(event) }
        }
        #expect(sent.count == count)
        #expect(waitUntil(timeout: 5) { f.inbox.count == count })
        #expect(Set(f.inbox.events.compactMap(\.sessionID)) == Set((0..<count).map { "s\($0)" }))
        #expect(waitUntil { f.server.connectionCount == 0 })
    }

    @Test func connectionLimitQueuesClientsInsteadOfDroppingThem() throws {
        let f = try ServerFixture(start: false)
        defer { f.tearDown() }
        f.server.maxConnections = 2
        try f.server.start()
        // Two silent clients hold both slots for a moment.
        let a = try f.connect()
        let b = try f.connect()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { close(a); close(b) }
        let sent = EventInbox()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            let event = f.event(session: "q\(i)")
            if EventSocketClient.send(.event(event), to: f.socket, timeout: 2) { sent.append(event) }
        }
        #expect(sent.count == 40)
        // Generous: with two slots the forty are served a pair at a time, slowly on a busy CI runner.
        #expect(waitUntil(timeout: 30) { f.inbox.count == 40 })
    }

    @Test func garbageIsDroppedAndTheConnectionKeepsWorking() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        let fd = try f.connect()
        defer { close(fd) }
        f.write(fd, "hello\n{not json}\n[1,2]\n{\"v\":1}\n{\"v\":1,\"type\":\"event\"}\n\n   \n\u{0}\u{1}\u{2}\n")
        f.write(fd, "{\"v\":2,\"type\":\"event\",\"event\":{\"kind\":\"agentStarted\",\"source\":\"x\",\"ts\":1}}\n")
        f.write(fd, "{\"v\":1,\"type\":\"event\",\"event\":{\"kind\":\"somethingNew\",\"source\":\"x\",\"ts\":1}}\n")
        f.write(fd, "{\"v\":1,\"type\":\"mystery\"}\n")
        // Unknown fields are ignored.
        f.write(fd, "{\"v\":1,\"type\":\"event\",\"extra\":true,\"event\":{\"kind\":\"agentFinished\",\"source\":\"codex\",\"ts\":1795400000,\"future\":[1]}}\n")
        let good = f.event(.agentNeedsUser)
        f.write(fd, try f.line(good))
        #expect(waitUntil { f.inbox.count == 2 })
        #expect(f.inbox.events.first?.kind == .agentFinished)
        #expect(f.inbox.events.first?.source == .codex)
        #expect(f.inbox.events.last == good)
    }

    @Test func severalLinesInOneWriteArriveInOrder() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        let fd = try f.connect()
        defer { close(fd) }
        let events = (0..<20).map { f.event(session: "s\($0)") }
        f.write(fd, try events.map(f.line).joined())
        #expect(waitUntil { f.inbox.count == 20 })
        #expect(f.inbox.events == events)
    }

    @Test func lineSplitAcrossWrites() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        let fd = try f.connect()
        defer { close(fd) }
        let text = try f.line(f.event())
        let mid = text.index(text.startIndex, offsetBy: 17)
        f.write(fd, String(text[..<mid]))
        usleep(50_000)
        #expect(f.inbox.count == 0)
        f.write(fd, String(text[mid...]))
        #expect(waitUntil { f.inbox.count == 1 })
    }

    @Test func oversizedLineIsDroppedAndTheNextLineIsRead() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        let fd = try f.connect()
        defer { close(fd) }
        // `encodedLine` refuses > 64 KB, so build the oversized line by hand.
        let big = "{\"v\":1,\"type\":\"event\",\"event\":{\"kind\":\"agentStarted\",\"source\":\"x\",\"ts\":1,\"title\":\"" + String(repeating: "y", count: 70_000) + "\"}}\n"
        f.write(fd, big)
        let good = f.event(.agentFinished)
        f.write(fd, try f.line(good))
        #expect(waitUntil { f.inbox.count == 1 })
        usleep(50_000)
        #expect(f.inbox.events == [good])
    }

    @Test func clientThatDisconnectsMidLine() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        let fd = try f.connect()
        f.write(fd, "{\"v\":1,\"type\":\"event\",\"event\":{\"kind\":\"agentSta")
        close(fd)
        // A complete object without the final newline is still accepted when the peer closes.
        let fd2 = try f.connect()
        var text = try f.line(f.event(session: "last"))
        text.removeLast()
        f.write(fd2, text)
        close(fd2)
        #expect(waitUntil { f.inbox.count == 1 })
        #expect(f.inbox.events.first?.sessionID == "last")
        #expect(waitUntil { f.server.connectionCount == 0 })
    }

    @Test func silentClientDoesNotBlockOthersAndIsClosed() throws {
        let f = try ServerFixture(idleTimeout: 0.3)
        defer { f.tearDown() }
        let silent = try f.connect()
        defer { close(silent) }
        #expect(EventSocketClient.send(.event(f.event()), to: f.socket))
        #expect(waitUntil { f.inbox.count == 1 })
        #expect(waitUntil { f.server.connectionCount == 0 })
        // The server closed it: reading gives EOF.
        var byte: UInt8 = 0
        #expect(UnixSocket.waitFor(silent, events: Int16(POLLIN), until: Date().addingTimeInterval(1)))
        #expect(read(silent, &byte, 1) == 0)
    }

    @Test func statusRequestAndReply() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        let report = StatusReport(appVersion: "9.9.9", generatedAt: Date(timeIntervalSince1970: 1_795_400_000),
                                  sessions: [.init(source: .codex, sessionID: "a", state: .working, cwd: "/w",
                                                   lastEventAt: Date(timeIntervalSince1970: 1_795_399_000))],
                                  paused: "Paused: microphone is on", away: false,
                                  lastEventBySource: [.codex: Date(timeIntervalSince1970: 1_795_399_000)])
        f.server.statusProvider = { report }
        let reply = try EventSocketClient.request(.statusRequest, to: f.socket)
        #expect(reply == .statusReply(report))

        // Many status requests in parallel.
        let ok = EventInbox()
        DispatchQueue.concurrentPerform(iterations: 30) { _ in
            if (try? EventSocketClient.request(.statusRequest, to: f.socket)) == .statusReply(report) {
                ok.append(f.event())
            }
        }
        #expect(ok.count == 30)
    }

    @Test func commandIsAnsweredOnTheDeliveryQueue() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        let key = f.queueKey
        f.server.commandHandler = { name, arguments in
            "\(name) \(arguments.joined(separator: ",")) onQueue=\(DispatchQueue.getSpecific(key: key) == true)"
        }
        let reply = try EventSocketClient.request(.command(name: "signals", arguments: ["a", "b"]), to: f.socket)
        #expect(reply == .reply("signals a,b onQueue=true"))
        // Text longer than one line is cut to fit rather than dropped.
        f.server.commandHandler = { _, _ in String(repeating: "x", count: WireMessage.maxLineBytes * 2) }
        guard case .reply(let long) = try EventSocketClient.request(.command(name: "big", arguments: []), to: f.socket) else {
            Issue.record("no reply")
            return
        }
        #expect(long.hasSuffix("[cut]"))
        // Without a handler the server still answers.
        f.server.commandHandler = nil
        #expect(try EventSocketClient.request(.command(name: "nope", arguments: []), to: f.socket) == .reply("Unknown command nope."))
    }

    @Test func statusWithoutProviderStillAnswers() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        guard case .statusReply(let report) = try EventSocketClient.request(.statusRequest, to: f.socket) else {
            Issue.record("no reply")
            return
        }
        #expect(report.appVersion == BreakpointVersion.current)
    }

    @Test func staleSocketFromACrashedAppIsReplaced() throws {
        let dir = ShortTemporaryDirectory()
        defer { dir.cleanup() }
        let socket = SocketPath(paths: dir.paths)
        try FileManager.default.createDirectory(at: socket.directory, withIntermediateDirectories: true)
        // A socket file nobody listens on, as a crash leaves it.
        let fd = try #require(UnixSocket.makeSocket())
        #expect(UnixSocket.bind(fd, UnixSocket.address(socket.path)!) == 0)
        close(fd)
        #expect(FileManager.default.fileExists(atPath: socket.path))
        #expect(!EventSocketClient.send(.event(AgentEvent(kind: .test, source: "x", timestamp: Date())), to: socket))

        let server = EventSocketServer(socketPath: socket, deliveryQueue: DispatchQueue(label: "q"))
        try server.start()
        defer { server.stop() }
        #expect(EventSocketClient.send(.event(AgentEvent(kind: .test, source: "x", timestamp: Date())), to: socket))
    }

    @Test func aLiveServerIsNeverStolen() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        let second = EventSocketServer(socketPath: f.socket, deliveryQueue: DispatchQueue(label: "q2"))
        #expect(throws: SocketServerError.alreadyRunning(f.socket.path)) { try second.start() }
        second.stop()
        #expect(EventSocketClient.send(.event(f.event()), to: f.socket))
        #expect(waitUntil { f.inbox.count == 1 })
    }

    @Test func somethingElseAtThePathIsLeftAlone() throws {
        let dir = ShortTemporaryDirectory()
        defer { dir.cleanup() }
        let socket = SocketPath(paths: dir.paths)
        try FileManager.default.createDirectory(at: socket.directory, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: socket.url)
        let server = EventSocketServer(socketPath: socket, deliveryQueue: DispatchQueue(label: "q"))
        #expect(throws: SocketServerError.pathOccupied(socket.path)) { try server.start() }
        #expect(try String(contentsOf: socket.url, encoding: .utf8) == "keep me")
    }

    @Test func stopRemovesTheSocketAndCanRestart() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        f.server.stop()
        f.server.stop()
        #expect(!f.server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: f.socket.path))
        #expect(!EventSocketClient.send(.event(f.event()), to: f.socket))
        try f.server.start()
        #expect(EventSocketClient.send(.event(f.event()), to: f.socket))
        #expect(waitUntil { f.inbox.count == 1 })
    }

    @Test func stopDoesNotRemoveAnotherServersSocket() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        // Someone replaced the socket file (e.g. a second copy started after removing ours).
        unlink(f.socket.path)
        let other = EventSocketServer(socketPath: f.socket, deliveryQueue: DispatchQueue(label: "o"))
        try other.start()
        defer { other.stop() }
        f.server.stop()
        #expect(FileManager.default.fileExists(atPath: f.socket.path))
    }

    @Test func clientFailsFastWithoutAServer() throws {
        let dir = ShortTemporaryDirectory()
        defer { dir.cleanup() }
        let socket = SocketPath(paths: dir.paths)
        let start = Date()
        #expect(!EventSocketClient.send(.event(AgentEvent(kind: .test, source: "x", timestamp: Date())), to: socket))
        #expect(Date().timeIntervalSince(start) < 0.05)
        #expect(throws: SocketClientError.notRunning) { try EventSocketClient.request(.statusRequest, to: socket) }
    }

    @Test func requestTimesOutWhenTheAppDoesNotAnswer() throws {
        let f = try ServerFixture()
        defer { f.tearDown() }
        // A provider stuck on the delivery queue (a frozen main thread) makes `status` time out.
        let gate = DispatchSemaphore(value: 0)
        f.server.statusProvider = { gate.wait(); return StatusReport(generatedAt: Date()) }
        let start = Date()
        #expect(throws: SocketClientError.timedOut) { try EventSocketClient.request(.statusRequest, to: f.socket, timeout: 0.3) }
        #expect(Date().timeIntervalSince(start) < 1)
        gate.signal()
    }

    @Test func longHomePathUsesTheFallbackSocket() {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 60))
        let socket = SocketPath(paths: BreakpointPaths(home: long))
        #expect(socket.isFallback)
        #expect(socket.path.hasSuffix("/.breakpoint/run/bp.sock"))
    }
}
