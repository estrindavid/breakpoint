import Foundation

/// The update check's sentences (SPEC §2.11, §3.5 update prompt, §3.9 About). Plain verbs, no "!",
/// no urgency: a new version is news, never a warning.
public enum UpdateCopy {
    /// The prompt's title: "Breakpoint 0.3.0 is ready".
    public static func promptTitle(version: String) -> String { "Breakpoint \(version) is ready" }

    /// The prompt's one line: the release's own note, or a plain fallback.
    public static func promptDetail(notes: String) -> String {
        notes.isEmpty ? "A new version is on GitHub." : notes
    }

    // MARK: Settings → About → Updates

    public static let checking = "Checking for updates…"
    public static let upToDate = "Breakpoint is up to date"
    public static let neverChecked = "Not checked yet"
    public static let failed = "Couldn't reach GitHub"
    public static func available(version: String) -> String { "Version \(version) is available" }

    /// "Checked today at 09:12", "Checked yesterday at 18:40", "Checked on 3 Nov".
    public static func lastChecked(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current,
                                   timeZone: TimeZone = .current) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        let time = TimeFormat.timeOfDay(date, locale: locale, timeZone: timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return "Checked today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Checked yesterday at \(time)"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return "Checked on \(formatter.string(from: date))"
    }

    // MARK: Installing in place

    public static let downloading = "Downloading…"
    public static let verifying = "Checking the signature…"
    public static let installing = "Installing…"
    public static let reopening = "Reopening Breakpoint…"
    /// The toast the new copy shows once it has started.
    public static func updated(to version: String) -> String { "Breakpoint is now \(version)" }
    /// The toast the old copy shows when it was put back.
    public static func rolledBack(to version: String, from failed: String) -> String {
        "The update to \(failed) didn't start, so Breakpoint is back on \(version)"
    }
    public static func installFailedTitle(version: String) -> String { "Couldn't install \(version)" }
    public static let noKey = "This copy has no release key, so it can tell you about new versions but not install them."
    public static let autoInstallDescription =
        "When a new version is out, Breakpoint installs it at a quiet moment and reopens itself. Off: it asks first."

    /// The automatic-check toggle's description: exactly what leaves the Mac.
    public static let automaticDescription =
        "Once a day, Breakpoint downloads a small file from its GitHub page to see the latest version number. It sends nothing about you or your breaks."
}
