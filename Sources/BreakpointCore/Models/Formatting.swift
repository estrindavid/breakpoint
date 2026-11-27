import Foundation

/// Duration and time formatting shared by every surface, so the same value reads the same way
/// everywhere. English only in v1. All functions are pure.
///
/// Rounding convention: elapsed durations ("42 min since you moved") round **down**; countdowns
/// ("Eye rest in 6 min", "6m") round **up**, so a countdown never shows 0 before it is due.
public enum DurationFormat {
    public enum Rounding: Sendable {
        case down, up, nearest
    }

    /// Whole minutes in `seconds` using `rounding` (never negative).
    public static func wholeMinutes(_ seconds: TimeInterval, rounding: Rounding = .down) -> Int {
        let minutes = max(0, seconds) / 60
        switch rounding {
        case .down: return Int(minutes.rounded(.down))
        case .up: return Int(minutes.rounded(.up))
        case .nearest: return Int(minutes.rounded(.toNearestOrAwayFromZero))
        }
    }

    /// Timer format `m:ss` ("0:19", "1:42", "12:05"); `h:mm:ss` from one hour. Rounds up to the
    /// next whole second so a countdown shows "0:01" until it ends. Negative values show "0:00".
    public static func clock(_ seconds: TimeInterval, rounding: Rounding = .up) -> String {
        let raw = max(0, seconds)
        let total: Int
        switch rounding {
        case .up: total = Int((raw - 0.000_001).rounded(.up).clamped(min: 0))
        case .down: total = Int(raw.rounded(.down))
        case .nearest: total = Int(raw.rounded())
        }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// "6 min", "1 h", "1 h 5 min". Under one minute: "<1 min" (rounding down) or "1 min"
    /// (rounding up).
    public static func minutes(_ seconds: TimeInterval, rounding: Rounding = .down) -> String {
        let m = wholeMinutes(seconds, rounding: rounding)
        if m == 0 { return rounding == .up && seconds > 0 ? "1 min" : "<1 min" }
        return hoursAndMinutes(m, separator: " ", hourUnit: "h", minuteUnit: "min")
    }

    /// Menu-bar form: "6m", "1h", "1h 5m"; "<1m" under a minute when rounding down.
    public static func compact(_ seconds: TimeInterval, rounding: Rounding = .up) -> String {
        let m = wholeMinutes(seconds, rounding: rounding)
        if m == 0 { return rounding == .up && seconds > 0 ? "1m" : "<1m" }
        return hoursAndMinutes(m, separator: "", hourUnit: "h", minuteUnit: "m")
    }

    /// Length adjective for offers: "20-sec", "2-min", "6-min", "1-min" (SPEC §3.1).
    /// Under 60 s uses seconds; otherwise minutes rounded to nearest.
    public static func lengthAdjective(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(max(0, seconds).rounded()))-sec" }
        return "\(wholeMinutes(seconds, rounding: .nearest))-min"
    }

    /// Spoken length for VoiceOver and long copy: "20 seconds", "2 minutes", "1 minute".
    public static func spokenLength(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            let s = Int(max(0, seconds).rounded())
            return s == 1 ? "1 second" : "\(s) seconds"
        }
        let m = wholeMinutes(seconds, rounding: .nearest)
        return m == 1 ? "1 minute" : "\(m) minutes"
    }

    /// "42 min since you moved" (popover, SPEC §3.8).
    public static func sinceYouMoved(_ stillTime: TimeInterval) -> String {
        "\(minutes(stillTime)) since you moved"
    }

    /// "52 min at the screen" (nudge subtitle for `typingPause`, SPEC §3.1).
    public static func atTheScreen(_ screenTime: TimeInterval) -> String {
        "\(minutes(screenTime)) at the screen"
    }

    /// "about 4 min" (usual run length, SPEC §3.1 why-now line). At least "about 1 min".
    public static func approximately(_ seconds: TimeInterval) -> String {
        "about \(max(1, wholeMinutes(seconds, rounding: .nearest))) min"
    }

    private static func hoursAndMinutes(_ totalMinutes: Int, separator: String, hourUnit: String, minuteUnit: String) -> String {
        let h = totalMinutes / 60, m = totalMinutes % 60
        if h == 0 { return "\(m)\(separator)\(minuteUnit)" }
        if m == 0 { return "\(h)\(separator)\(hourUnit)" }
        return "\(h)\(separator)\(hourUnit) \(m)\(separator)\(minuteUnit)"
    }
}

/// Time-of-day formatting ("14:05", or "2:05 PM" in 12-hour locales).
public enum TimeFormat {
    /// Hours and minutes in the user's locale (`jmm` template). Pass a fixed locale and time zone
    /// in tests and snapshots.
    public static func timeOfDay(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }
}

/// Text helpers shared by copy and parsers.
public enum TextFormat {
    /// `text` cut to at most `limit` characters, with "…" appended when cut (SPEC §3.5: ≤ 80
    /// characters + ellipsis). Trims surrounding whitespace first.
    public static func truncated(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit, limit > 0 else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The first non-empty line of `text`.
    public static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

extension Double {
    func clamped(min lower: Double) -> Double { Swift.max(self, lower) }
}
