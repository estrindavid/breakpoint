import Foundation

/// The append-only record of offers and breaks, `history.jsonl` (SPEC §2.7, §8): one
/// `HistoryEntry` JSON object per line (dates ISO 8601), oldest first.
///
/// Contract:
/// - `append` adds one line (creating the file and directory as needed) and never rewrites
///   earlier lines. If the file ends in a partial line (a crash mid-write), the new entry starts on
///   a fresh line so it is not glued to the damaged one.
/// - `entries(in:)` returns entries whose `start` is in the interval, oldest first; lines that do
///   not decode are skipped, never fatal.
/// - `delete(ids:)` rewrites the file without those entries (Undo of a credited away period).
///   Lines it cannot decode are kept as they are (they may come from a newer version).
/// - `summary(forDayContaining:)` summarises the 05:00–05:00 day (`DaySummary.summarize`).
/// - `totals()` counts the all-time totals (`HistoryTotals`) in one pass over the file.
/// - `export(to:)` writes all entries as a JSON array to `url`.
/// - `deleteAll()` removes the file.
/// - Files are mode 0600 in a 0700 directory.
/// - Not thread-safe; called from the main thread.
public final class HistoryStore {
    public let fileURL: URL
    public let calendar: Calendar

    public init(fileURL: URL, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
    }

    public convenience init(paths: BreakpointPaths, calendar: Calendar = .current) {
        self.init(fileURL: paths.historyFile, calendar: calendar)
    }

    public func append(_ entry: HistoryEntry) throws {
        var line = try Self.lineEncoder.encode(entry)
        line.append(Self.newline)
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            let last = try handle.read(upToCount: 1)
            if last?.first != Self.newline { line.insert(Self.newline, at: line.startIndex) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }

    /// Every entry that decodes, oldest first.
    public func allEntries() throws -> [HistoryEntry] {
        // Stable: entries with the same start keep their file order.
        try lines().compactMap(Self.decode).enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    /// Only lines whose `start` falls in the interval are decoded in full: today's summary is read
    /// after every recorded offer, on the main thread, and the file grows by every offer forever.
    /// Lines are found and their `start` compared on the raw bytes (memchr / memmem / memcmp).
    public func entries(in interval: DateInterval) throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let lower = Array(ISO8601.string(from: interval.start).utf8)
        let upper = Array(ISO8601.string(from: interval.end).utf8)
        var candidates: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var lineStart = 0
            while lineStart < count {
                var lineEnd = count
                if let newline = memchr(base + lineStart, 0x0A, count - lineStart) {
                    lineEnd = UnsafeRawPointer(newline) - UnsafeRawPointer(base)
                }
                let length = lineEnd - lineStart
                if length > 0, !Self.startIsOutside(base + lineStart, length: length, lower: lower, upper: upper) {
                    candidates.append(Data(bytes: base + lineStart, count: length))
                }
                lineStart = lineEnd + 1
            }
        }
        var found: [(entry: HistoryEntry, offset: Int)] = []
        for (offset, line) in candidates.enumerated() {
            guard let entry = Self.decode(line), entry.start >= interval.start, entry.start < interval.end else { continue }
            found.append((entry, offset))
        }
        // Stable: entries with the same start keep their file order.
        found.sort { ($0.entry.start, $0.offset) < ($1.entry.start, $1.offset) }
        return found.map(\.entry)
    }

    private static let startKey = Array("\"start\":\"".utf8)

    /// True when the line's `start` is certainly outside [lower, upper), read without decoding:
    /// this file's own format (`2026-11-22T09:00:00.000Z`, UTC, fixed width) sorts as text. Any
    /// other spelling returns false, so the line is decoded and filtered by date.
    static func startIsOutside(_ line: UnsafePointer<UInt8>, length: Int, lower: [UInt8], upper: [UInt8]) -> Bool {
        let width = 24
        guard lower.count == width, upper.count == width,
              let found = memmem(line, length, startKey, startKey.count) else { return false }
        let value = found.assumingMemoryBound(to: UInt8.self) + startKey.count
        guard value + width < line + length, value[width] == UInt8(ascii: "\""),
              value[10] == UInt8(ascii: "T"), value[width - 1] == UInt8(ascii: "Z") else { return false }
        return memcmp(value, lower, width) < 0 || memcmp(value, upper, width) >= 0
    }

    public func delete(ids: Set<UUID>) throws {
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let all = try lines()
        let kept = all.filter { line in
            guard let id = Self.decodeID(line) else { return true }
            return !ids.contains(id)
        }
        guard kept.count != all.count else { return }
        var data = Data()
        for line in kept {
            data.append(line)
            data.append(Self.newline)
        }
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func summary(forDayContaining date: Date) throws -> DaySummary {
        let day = BreakpointDay.interval(containing: date, calendar: calendar)
        return DaySummary.summarize(try entries(in: day), dayStart: day.start, calendar: calendar)
    }

    /// The all-time totals (`HistoryTotals`), entries added in file order. Called once at launch;
    /// the app then adds each entry it records. Lines in this file's own compact spelling are read
    /// without decoding (`start`, `kind`, `outcome` and `duration` from the raw bytes); lines in
    /// any other spelling are decoded in full.
    public func totals() throws -> HistoryTotals {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        var totals = HistoryTotals()
        var earliest: [UInt8]?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var lineStart = 0
            while lineStart < count {
                var lineEnd = count
                if let newline = memchr(base + lineStart, 0x0A, count - lineStart) {
                    lineEnd = UnsafeRawPointer(newline) - UnsafeRawPointer(base)
                }
                let line = base + lineStart
                let length = lineEnd - lineStart
                lineStart = lineEnd + 1
                guard length > 0 else { continue }
                if let start = Self.fixedWidthStart(line, length: length),
                   let kind = Self.rawString(line, length: length, key: Self.kindKey).flatMap(BreakKind.init(rawValue:)),
                   let outcome = Self.rawString(line, length: length, key: Self.outcomeKey).flatMap(BreakOutcome.init(rawValue:)),
                   let duration = Self.rawNumber(line, length: length, key: Self.durationKey) {
                    if earliest.map({ memcmp(start, $0, Self.startWidth) < 0 }) ?? true {
                        earliest = Array(UnsafeBufferPointer(start: start, count: Self.startWidth))
                    }
                    totals.add(kind: kind, outcome: outcome, duration: duration, start: nil)
                } else if let entry = Self.decode(Data(bytes: line, count: length)) {
                    totals.add(entry)
                }
            }
        }
        if let earliest, let date = ISO8601.date(from: String(decoding: earliest, as: UTF8.self)),
           totals.firstEntry.map({ date < $0 }) ?? true {
            totals.firstEntry = date
        }
        return totals
    }

    private static let startWidth = 24
    private static let kindKey = Array("\"kind\":\"".utf8)
    private static let outcomeKey = Array("\"outcome\":\"".utf8)
    private static let durationKey = Array("\"duration\":".utf8)

    /// The line's `start` in this file's own fixed-width spelling, or nil for any other spelling.
    private static func fixedWidthStart(_ line: UnsafePointer<UInt8>, length: Int) -> UnsafePointer<UInt8>? {
        guard let found = memmem(line, length, startKey, startKey.count) else { return nil }
        let value = found.assumingMemoryBound(to: UInt8.self) + startKey.count
        guard value + startWidth < line + length, value[startWidth] == UInt8(ascii: "\""),
              value[10] == UInt8(ascii: "T"), value[startWidth - 1] == UInt8(ascii: "Z") else { return nil }
        return UnsafePointer(value)
    }

    /// The string value after `key` (which ends with the opening quote), up to 16 bytes.
    private static func rawString(_ line: UnsafePointer<UInt8>, length: Int, key: [UInt8]) -> String? {
        guard let found = memmem(line, length, key, key.count) else { return nil }
        let value = found.assumingMemoryBound(to: UInt8.self) + key.count
        let end = line + length
        var cursor = value
        while cursor < end, cursor - value <= 16 {
            if cursor.pointee == UInt8(ascii: "\"") {
                return String(decoding: UnsafeBufferPointer(start: value, count: cursor - value), as: UTF8.self)
            }
            cursor += 1
        }
        return nil
    }

    /// The plain decimal number after `key`; 0 when the key is absent (as when decoding); nil
    /// when the value is not a plain number.
    private static func rawNumber(_ line: UnsafePointer<UInt8>, length: Int, key: [UInt8]) -> TimeInterval? {
        guard let found = memmem(line, length, key, key.count) else { return 0 }
        let value = found.assumingMemoryBound(to: UInt8.self) + key.count
        let end = line + length
        var cursor = value
        while cursor < end, cursor - value < 24,
              (cursor.pointee >= UInt8(ascii: "0") && cursor.pointee <= UInt8(ascii: "9"))
                || cursor.pointee == UInt8(ascii: ".") || cursor.pointee == UInt8(ascii: "-") {
            cursor += 1
        }
        guard cursor > value, cursor < end, cursor.pointee == UInt8(ascii: ",") || cursor.pointee == UInt8(ascii: "}") else {
            return nil
        }
        return TimeInterval(String(decoding: UnsafeBufferPointer(start: value, count: cursor - value), as: UTF8.self))
    }

    public func export(to url: URL) throws {
        let encoder = JSONFile<[HistoryEntry]>.encoder
        var data = try encoder.encode(try allEntries())
        data.append(Self.newline)
        try data.write(to: url, options: .atomic)
    }

    public func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Lines

    private static let newline = UInt8(ascii: "\n")

    /// One compact JSON object per line, keys sorted, dates ISO 8601.
    static var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.string(from: date))
        }
        return encoder
    }

    /// The file's non-blank lines; none when the file does not exist.
    private func lines() throws -> [Data] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return data.split(separator: Self.newline, omittingEmptySubsequences: true)
            .map { Data($0) }
            .filter { line in line.contains { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0D) } }
    }

    private static let lineDecoder = JSONFile<HistoryEntry>.decoder

    private static func decode(_ line: Data) -> HistoryEntry? {
        try? lineDecoder.decode(HistoryEntry.self, from: line)
    }

    private struct IDOnly: Decodable { let id: UUID }

    private static func decodeID(_ line: Data) -> UUID? {
        (try? JSONDecoder().decode(IDOnly.self, from: line))?.id
    }
}
