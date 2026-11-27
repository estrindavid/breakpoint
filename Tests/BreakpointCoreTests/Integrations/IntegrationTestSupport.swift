import Foundation
import Testing
@testable import BreakpointCore

/// A fake home folder for installer tests. Never the real home: everything lives in a fresh
/// temporary directory that `cleanup()` removes.
struct FakeHome {
    let temp = TemporaryDirectory()
    var url: URL { temp.url }
    var paths: BreakpointPaths { temp.paths }

    /// A fixed clock so backup names are predictable.
    var environment: IntegrationEnvironment {
        IntegrationEnvironment(paths: paths, processEnvironment: [:], now: { Date(timeIntervalSince1970: 1_795_400_000) })
    }

    func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    func mkdir(_ relative: String) {
        try! FileManager.default.createDirectory(at: path(relative), withIntermediateDirectories: true)
    }

    func write(_ relative: String, _ text: String) {
        let file = path(relative)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: file)
    }

    func read(_ relative: String) -> String? {
        (try? Data(contentsOf: path(relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path(relative).path) }

    var backups: [URL] {
        let dir = paths.backupsDirectory
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().map { dir.appendingPathComponent($0) }
    }

    var ledger: IntegrationLedger { IntegrationLedger.load(paths) }

    func cleanup() { temp.cleanup() }
}

/// Short temporary folder under /tmp, for Unix socket paths (≤ 103 bytes).
struct ShortTemporaryDirectory {
    let url: URL

    init() {
        var template = Array("/tmp/bpt-XXXXXX".utf8CString)
        let result = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
        precondition(result != nil, "mkdtemp failed")
        url = URL(fileURLWithPath: String(cString: template), isDirectory: true).standardizedFileURL
    }

    var paths: BreakpointPaths { BreakpointPaths(home: url) }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// Parses JSON text for semantic comparisons.
func json(_ text: String, comments: Bool = false) throws -> JValue {
    try JSONTextParser.parse(Array(text.utf8), allowComments: comments).value
}

/// Waits (polling) until `condition` holds or `timeout` passes.
func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

/// Thread-safe collector for events delivered by a server.
final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AgentEvent] = []
    var events: [AgentEvent] { lock.withLock { items } }
    func append(_ event: AgentEvent) { lock.withLock { items.append(event) } }
    var count: Int { lock.withLock { items.count } }
}
