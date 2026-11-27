import Foundation

/// A Breakpoint day runs 05:00 to 05:00 local time (SPEC §2.7). Manual "until tomorrow" pauses and
/// the wind-down wrap-up also end at 05:00.
public enum BreakpointDay {
    /// Start (05:00) of the Breakpoint day containing `date`.
    public static func start(of date: Date, calendar: Calendar = .current) -> Date {
        let boundaryToday = calendar.date(
            bySettingHour: Timing.dayBoundaryHour, minute: 0, second: 0, of: date
        ) ?? date
        if date >= boundaryToday { return boundaryToday }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        return calendar.date(bySettingHour: Timing.dayBoundaryHour, minute: 0, second: 0, of: yesterday) ?? date
    }

    /// The first 05:00 strictly after `date`.
    public static func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date {
        let start = start(of: date, calendar: calendar)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
        // Re-anchor at 05:00 in case of a DST shift.
        return calendar.date(bySettingHour: Timing.dayBoundaryHour, minute: 0, second: 0, of: next) ?? next
    }

    /// The Breakpoint day containing `date`, as an interval [05:00, next 05:00).
    public static func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = start(of: date, calendar: calendar)
        return DateInterval(start: start, end: nextBoundary(after: start, calendar: calendar))
    }
}

/// A wall-clock time of day, e.g. the wind-down stop time 23:00. Encodes as "HH:mm".
public struct TimeOfDay: Codable, Equatable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// Parses "HH:mm" (also "H:mm").
    public init?(string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        self.init(hour: h, minute: m)
    }

    /// "23:00".
    public var description: String { String(format: "%02d:%02d", hour, minute) }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    /// This time of day on the calendar day of `date`.
    public func date(on date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let value = TimeOfDay(string: string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Expected HH:mm, got \(string)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A set of weekdays (wind-down "on [Mon–Sun]"). Bit 0 = Sunday … bit 6 = Saturday, matching
/// `Calendar` weekday numbers 1…7. Encodes as an array of weekday numbers, e.g. [1,2,3,4,5,6,7].
public struct Weekdays: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0b111_1111 }

    public static let sunday = Weekdays(rawValue: 1 << 0)
    public static let monday = Weekdays(rawValue: 1 << 1)
    public static let tuesday = Weekdays(rawValue: 1 << 2)
    public static let wednesday = Weekdays(rawValue: 1 << 3)
    public static let thursday = Weekdays(rawValue: 1 << 4)
    public static let friday = Weekdays(rawValue: 1 << 5)
    public static let saturday = Weekdays(rawValue: 1 << 6)

    public static let all: Weekdays = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
    public static let weekdays: Weekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]

    /// The day for a `Calendar` weekday number (1 = Sunday … 7 = Saturday).
    public init(calendarWeekday: Int) {
        self.init(rawValue: (1...7).contains(calendarWeekday) ? UInt8(1 << (calendarWeekday - 1)) : 0)
    }

    public func contains(calendarWeekday: Int) -> Bool { contains(Weekdays(calendarWeekday: calendarWeekday)) }

    /// Whether `date` falls on one of these days.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        contains(calendarWeekday: calendar.component(.weekday, from: date))
    }

    /// Calendar weekday numbers in this set, ascending.
    public var calendarWeekdays: [Int] { (1...7).filter { contains(calendarWeekday: $0) } }

    public init(from decoder: Decoder) throws {
        let days = try decoder.singleValueContainer().decode([Int].self)
        self = days.reduce(into: Weekdays()) { $0.insert(Weekdays(calendarWeekday: $1)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(calendarWeekdays)
    }
}
