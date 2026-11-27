import Foundation
@testable import BreakpointCore

/// A fresh directory under the system temp folder, removed by `cleanup()`. Every test that
/// touches files uses one of these as its fake home; tests never touch the real home folder.
struct TemporaryDirectory {
    let url: URL

    init(function: String = #function) {
        let name = "breakpoint-tests-\(UUID().uuidString.prefix(8))"
        url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var paths: BreakpointPaths { BreakpointPaths(home: url) }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// Fixed calendar (UTC, Gregorian) and dates for deterministic tests.
enum Fixture {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static let utc = TimeZone(identifier: "UTC")!
    static let posix = Locale(identifier: "en_GB")

    /// 2026-11-22 at `hour`:`minute` UTC.
    static func date(_ hour: Int, _ minute: Int = 0, day: Int = 22) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    static func jsonRoundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONFile<T>.encoder.encode(value)
        return try JSONFile<T>.decoder.decode(T.self, from: data)
    }
}
