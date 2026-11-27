import Foundation
import Testing
@testable import BreakpointCore

@Suite("HistoryStore (SPEC §2.7, §8)")
struct HistoryStoreTests {
    let calendar = Fixture.calendar

    func store(_ dir: TemporaryDirectory) -> HistoryStore { HistoryStore(paths: dir.paths, calendar: calendar) }

    func entry(_ kind: BreakKind, _ outcome: BreakOutcome, at date: Date, duration: TimeInterval = 0) -> HistoryEntry {
        HistoryEntry(kind: kind, outcome: outcome, opportunityKind: .agentStarted, source: .claudeCode, start: date,
                     duration: duration)
    }

    func everything() -> DateInterval { DateInterval(start: .distantPast, end: .distantFuture) }

    @Test func appendsOneLinePerEntryWithPrivateModes() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let s = store(dir)
        #expect(try s.entries(in: everything()).isEmpty)
        let a = entry(.eyes, .completed, at: Fixture.date(9), duration: 20)
        let b = entry(.move, .declined, at: Fixture.date(10))
        try s.append(a)
        try s.append(b)
        let text = try String(contentsOf: dir.paths.historyFile, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.hasSuffix("\n"))
        #expect(text.contains("\"start\":\"2026-11-22T09:00:00.000Z\""))
        #expect(try s.entries(in: everything()) == [a, b])
        let file = try FileManager.default.attributesOfItem(atPath: dir.paths.historyFile.path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.paths.appSupport.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func appendNeverRewritesEarlierLines() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let s = store(dir)
        try s.append(entry(.eyes, .completed, at: Fixture.date(9)))
        let before = try Data(contentsOf: dir.paths.historyFile)
        try s.append(entry(.move, .completed, at: Fixture.date(10)))
        let after = try Data(contentsOf: dir.paths.historyFile)
        #expect(after.prefix(before.count) == before)
    }

    @Test func entriesAreFilteredByIntervalAndSortedOldestFirst() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let s = store(dir)
        let late = entry(.move, .completed, at: Fixture.date(16))
        let early = entry(.eyes, .completed, at: Fixture.date(9))
        let outside = entry(.walk, .completed, at: Fixture.date(4))
        for e in [late, early, outside] { try s.append(e) }
        let day = DateInterval(start: Fixture.date(5), end: Fixture.date(5, day: 23))
        #expect(try s.entries(in: day) == [early, late])
    }

    @Test func truncatedAndCorruptLinesAreSkipped() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let s = store(dir)
        let good = entry(.eyes, .completed, at: Fixture.date(9))
        try s.append(good)
        // A crash left half a line at the end, plus junk and a line from a newer version.
        let handle = try FileHandle(forWritingTo: dir.paths.historyFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage\n\n   \n{\"id\":\"not-a-uuid\"}\n{\"id\":\"".utf8))
        try handle.close()
        #expect(try s.entries(in: everything()) == [good])
        // The next append starts a fresh line instead of gluing onto the partial one.
        let next = entry(.move, .completed, at: Fixture.date(11))
        try s.append(next)
        #expect(try s.entries(in: everything()) == [good, next])
    }

    @Test func entriesWithUnknownOpportunityKindsStillLoad() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let line = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"move","outcome":"completed","opportunityKind":"futureKind","start":"2026-11-22T10:00:00Z"}"#
        try dir.paths.ensureAppSupportDirectory()
        try Data((line + "\n").utf8).write(to: dir.paths.historyFile)
        let entries = try store(dir).entries(in: everything())
        #expect(entries.count == 1 && entries[0].opportunityKind == nil && entries[0].duration == 0)
    }

    @Test func deleteRemovesOnlyThoseIDsAndKeepsUnknownLines() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let s = store(dir)
        let keep = entry(.eyes, .completed, at: Fixture.date(9))
        let credited1 = HistoryEntry(kind: .eyes, outcome: .credited, start: Fixture.date(12), duration: 3600)
        let credited2 = HistoryEntry(kind: .move, outcome: .credited, start: Fixture.date(12), duration: 3600)
        for e in [keep, credited1, credited2] { try s.append(e) }
        let handle = try FileHandle(forWritingTo: dir.paths.historyFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"from\":\"the future\"}\n".utf8))
        try handle.close()

        try s.delete(ids: [credited1.id, credited2.id])
        #expect(try s.entries(in: everything()) == [keep])
        let text = try String(contentsOf: dir.paths.historyFile, encoding: .utf8)
        #expect(text.contains("the future"))
        let file = try FileManager.default.attributesOfItem(atPath: dir.paths.historyFile.path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Deleting nothing, or from a missing file, is fine.
        try s.delete(ids: [])
        try s.delete(ids: [UUID()])
        try s.deleteAll()
        try s.delete(ids: [keep.id])
    }

    @Test func summaryUsesTheFiveOClockDayBoundary() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let s = store(dir)
        try s.append(entry(.eyes, .completed, at: Fixture.date(4, 59)))            // previous day
        try s.append(entry(.eyes, .completed, at: Fixture.date(5)))                // today
        try s.append(entry(.move, .credited, at: Fixture.date(12)))                // today
        try s.append(entry(.move, .skipped, at: Fixture.date(13)))                 // older versions only: never counted
        try s.append(entry(.eyes, .declined, at: Fixture.date(14)))                // never counted
        try s.append(entry(.eyes, .ignored, at: Fixture.date(15)))                 // never counted
        try s.append(entry(.walk, .endedEarly, at: Fixture.date(16)))              // started: taken
        try s.append(entry(.move, .completed, at: Fixture.date(1, day: 23)))       // late night: still today
        try s.append(entry(.eyes, .completed, at: Fixture.date(5, day: 23)))       // tomorrow

        let today = try s.summary(forDayContaining: Fixture.date(20))
        #expect(today.dayStart == Fixture.date(5))
        #expect(today.breaksTaken == 4)
        #expect(today.takenByKind == [.eyes: 1, .move: 2, .walk: 1])
        // 02:00 belongs to the same Breakpoint day.
        #expect(try s.summary(forDayContaining: Fixture.date(2, day: 23)) == today)
        let yesterday = try s.summary(forDayContaining: Fixture.date(4, 59))
        #expect(yesterday.breaksTaken == 1 && yesterday.dayStart == Fixture.date(5, day: 21))
        #expect(try s.summary(forDayContaining: Fixture.date(6, day: 23)).breaksTaken == 1)
    }

    @Test func exportWritesAJSONArray() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let s = store(dir)
        let entries = [entry(.eyes, .completed, at: Fixture.date(9)), entry(.walk, .completed, at: Fixture.date(10), duration: 420)]
        for e in entries { try s.append(e) }
        let out = dir.url.appendingPathComponent("export.json")
        try s.export(to: out)
        let decoded = try JSONFile<[HistoryEntry]>.decoder.decode([HistoryEntry].self, from: Data(contentsOf: out))
        #expect(decoded == entries)
        // An empty history exports an empty array.
        try s.deleteAll()
        try s.export(to: out)
        #expect(try JSONFile<[HistoryEntry]>.decoder.decode([HistoryEntry].self, from: Data(contentsOf: out)).isEmpty)
    }

    @Test func deleteAllRemovesTheFile() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let s = store(dir)
        try s.deleteAll()
        try s.append(entry(.eyes, .completed, at: Fixture.date(9)))
        try s.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: dir.paths.historyFile.path))
        #expect(try s.entries(in: everything()).isEmpty)
        try s.append(entry(.eyes, .completed, at: Fixture.date(10)))
        #expect(try s.entries(in: everything()).count == 1)
    }
}

@Suite("HistoryStore cost")
struct HistoryStoreCostTests {
    /// The coordinator reads today's summary after every recorded offer or break, on the main
    /// thread. A year of history (about 60 lines a day) must not make that a visible pause.
    @Test func todaysSummaryStaysCheapWithAYearOfHistory() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let calendar = Fixture.calendar
        let store = HistoryStore(paths: dir.paths, calendar: calendar)
        var data = Data()
        let encoder = HistoryStore.lineEncoder
        let start = Fixture.date(9).addingTimeInterval(-365 * 86_400)
        for i in 0..<(365 * 60) {
            let entry = HistoryEntry(kind: i % 3 == 0 ? .move : .eyes, outcome: i % 2 == 0 ? .completed : .ignored,
                                     opportunityKind: .agentStarted, source: .claudeCode,
                                     start: start.addingTimeInterval(TimeInterval(i) * 86_400 / 60), duration: 20)
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        try dir.paths.ensureAppSupportDirectory()
        try data.write(to: dir.paths.historyFile)
        let clock = ContinuousClock()
        var summary: DaySummary?
        let elapsed = try clock.measure { summary = try store.summary(forDayContaining: Fixture.date(12)) }
        #expect(summary != nil)
        #expect(elapsed < .milliseconds(100), "summary took \(elapsed)")
    }

    /// The fast path compares this file's own timestamp spelling as text; any other spelling (an
    /// older version, a hand edit) is still decoded and filtered by date.
    @Test func otherTimestampSpellingsAreStillFound() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        try dir.paths.ensureAppSupportDirectory()
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let lines = [
            #"{"duration":20,"id":"\#(id1)","kind":"eyes","movementDetected":false,"outcome":"completed","start":"2026-11-22T10:00:00Z"}"#,
            #"{"duration":20,"id":"\#(id2)","kind":"eyes","movementDetected":false,"outcome":"completed","start":"2026-11-22T11:00:00.000Z"}"#,
            #"{"duration":20,"id":"\#(id3)","kind":"eyes","movementDetected":false,"outcome":"completed","start":"2026-11-21T11:00:00.000Z"}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.paths.historyFile)
        let store = HistoryStore(paths: dir.paths, calendar: Fixture.calendar)
        let day = DateInterval(start: Fixture.date(5), end: Fixture.date(5, day: 23))
        #expect(try store.entries(in: day).map(\.id) == [id1, id2])
    }
}
