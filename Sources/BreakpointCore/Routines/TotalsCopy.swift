import Foundation

/// Wording of the popover's totals (SPEC §3.8): a period label, three figures each with a short
/// label, and one small line comparing the moving to an everyday activity. Your own totals only:
/// never a target, a comparison with others, a streak or anything skipped.
public enum TotalsCopy {
    /// A number and its unit, drawn at two sizes ("74" "min", "5" "h" "20" "min").
    public struct Part: Equatable, Hashable, Sendable {
        public var value: String
        public var unit: String?

        public init(_ value: String, _ unit: String? = nil) {
            self.value = value
            self.unit = unit
        }
    }

    /// The small line: `prefix` + `activity` + `suffix`. `isNew` while the latest stretch or walk
    /// is the one that reached this example (the activity is then drawn in mint).
    public struct ExampleLine: Equatable, Hashable, Sendable {
        public var prefix: String
        public var activity: String
        public var suffix: String
        public var isNew: Bool

        public var text: String { prefix + activity + suffix }
    }

    public static let movingLabel = "moving"

    /// Moving time, rounded down: "74 min" under 100 min, then "5 h 20 min" ("5 h" on the hour),
    /// and from 10 h whole hours only ("12 h", "1,040 h").
    public static func movingParts(_ seconds: TimeInterval, locale: Locale = .current) -> [Part] {
        let minutes = DurationFormat.wholeMinutes(seconds)
        if minutes < 100 { return [Part(count(minutes, locale: locale), "min")] }
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 10 || rest == 0 { return [Part(count(hours, locale: locale), "h")] }
        return [Part("\(hours)", "h"), Part("\(rest)", "min")]
    }

    /// "74 min", "5 h 20 min", "12 h".
    public static func moving(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        movingParts(seconds, locale: locale).map { [$0.value, $0.unit].compactMap { $0 }.joined(separator: " ") }
            .joined(separator: " ")
    }

    /// A count with the locale's grouping ("26", "1,204").
    public static func count(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: max(0, value))) ?? "\(max(0, value))"
    }

    public static func stretchesLabel(_ count: Int) -> String { count == 1 ? "stretch" : "stretches" }
    public static func eyeRestsLabel(_ count: Int) -> String { count == 1 ? "eye rest" : "eye rests" }

    /// "Today" while everything recorded is from today's Breakpoint day (05:00–05:00), then
    /// "Since Nov 16" ("Since Nov 16, 2025" when that was another year).
    public static func period(firstEntry: Date?, now: Date, calendar: Calendar = .current,
                              locale: Locale = .current) -> String {
        guard let firstEntry else { return "Today" }
        let firstDay = BreakpointDay.start(of: firstEntry, calendar: calendar)
        guard firstDay < BreakpointDay.start(of: now, calendar: calendar) else { return "Today" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: firstDay) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return "Since \(formatter.string(from: firstDay))"
    }

    /// The small line once the moving time reaches the first example ("That's like walking the
    /// dog."); nil before that.
    public static func exampleLine(_ totals: HistoryTotals) -> ExampleLine? {
        guard let index = MovingExamples.index(forMovingSeconds: totals.movingSeconds) else { return nil }
        let isNew = MovingExamples.index(forMovingSeconds: totals.movingBeforeLatest) != index
        return ExampleLine(prefix: "That's like ", activity: MovingExamples.all[index].activity, suffix: ".", isNew: isNew)
    }

    /// The line for an example (for tests and review): "That's like a full yoga class."
    public static func line(for example: MovingExample) -> String { "That's like \(example.activity)." }

    /// VoiceOver: "Since Nov 16: 74 min moving, 26 stretches, 61 eye rests. That's like a full yoga class."
    public static func accessibility(_ totals: HistoryTotals, now: Date, calendar: Calendar = .current,
                                     locale: Locale = .current) -> String {
        let figures = "\(moving(totals.movingSeconds, locale: locale)) moving, "
            + "\(count(totals.stretches, locale: locale)) \(stretchesLabel(totals.stretches)), "
            + "\(count(totals.eyeRests, locale: locale)) \(eyeRestsLabel(totals.eyeRests))."
        let line = exampleLine(totals).map { " " + $0.text } ?? ""
        return "\(period(firstEntry: totals.firstEntry, now: now, calendar: calendar, locale: locale)): \(figures)\(line)"
    }
}
