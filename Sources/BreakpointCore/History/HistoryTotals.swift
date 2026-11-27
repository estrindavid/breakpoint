import Foundation

/// The popover's three figures (SPEC §2.7, §3.8): the person's own all-time totals, counted from
/// `history.jsonl` since its first entry. They only grow (until Delete all data). Nothing here
/// counts an offer that was declined or ignored, and nothing is a target or a score.
///
/// What counts:
/// - **moving**: the real elapsed time of every `move` (stretch) and `walk` break the person
///   started (`completed` or `endedEarly`), however short: a 5-second stretch adds 5 seconds.
///   Each break adds at most `Timing.walkCeiling` (a guard against a damaged line).
/// - **stretches**: `move` breaks counted as moving. **walks**: `walk` breaks counted as moving.
/// - **eye rests**: every `eyes` break the person started (`completed` or `endedEarly`).
/// - Never counted: `breathe` (done sitting down), `credited` away time (nobody knows what you did
///   while away), `declined`, `ignored`, `skipped` (only in history from earlier versions, which
///   recorded a short break ended with Skip that way), and Settings previews (never recorded).
///
/// Kept incrementally: the app scans the file once at launch (`HistoryStore.totals()`), then
/// `add`s each entry it records, so opening the popover costs nothing.
public struct HistoryTotals: Codable, Equatable, Hashable, Sendable {
    /// Seconds spent moving (stretches and walks).
    public var movingSeconds: TimeInterval
    public var stretches: Int
    public var walks: Int
    public var eyeRests: Int
    /// Start of the earliest entry of any kind: the totals are "since" its day.
    public var firstEntry: Date?
    /// `movingSeconds` before the latest stretch or walk was added. The example line marks an
    /// example as new while the latest stretch or walk is the one that reached it.
    public var movingBeforeLatest: TimeInterval

    public init(movingSeconds: TimeInterval = 0, stretches: Int = 0, walks: Int = 0, eyeRests: Int = 0,
                firstEntry: Date? = nil, movingBeforeLatest: TimeInterval? = nil) {
        self.movingSeconds = movingSeconds
        self.stretches = stretches
        self.walks = walks
        self.eyeRests = eyeRests
        self.firstEntry = firstEntry
        self.movingBeforeLatest = movingBeforeLatest ?? movingSeconds
    }

    public static let empty = HistoryTotals()

    /// The totals of `entries`, added in the order given (the file's order).
    public static func counting<S: Sequence>(_ entries: S) -> HistoryTotals where S.Element == HistoryEntry {
        var totals = HistoryTotals()
        for entry in entries { totals.add(entry) }
        return totals
    }

    /// The moving time `entry` adds, or `nil` when it is not a stretch or walk that counts.
    public static func movingSeconds(of entry: HistoryEntry) -> TimeInterval? {
        movingSeconds(kind: entry.kind, outcome: entry.outcome, duration: entry.duration)
    }

    static func movingSeconds(kind: BreakKind, outcome: BreakOutcome, duration: TimeInterval) -> TimeInterval? {
        guard kind == .move || kind == .walk, wasTaken(outcome) else { return nil }
        return min(max(0, duration), Timing.walkCeiling)
    }

    /// A break the person started: completed, or ended early however soon.
    static func wasTaken(_ outcome: BreakOutcome) -> Bool { outcome == .completed || outcome == .endedEarly }

    /// Adds one recorded entry.
    public mutating func add(_ entry: HistoryEntry) {
        add(kind: entry.kind, outcome: entry.outcome, duration: entry.duration, start: entry.start)
    }

    /// Adds an entry's counted fields (`start` nil: the caller tracks the first entry itself).
    mutating func add(kind: BreakKind, outcome: BreakOutcome, duration: TimeInterval, start: Date?) {
        if let start, firstEntry.map({ start < $0 }) ?? true { firstEntry = start }
        if let moving = Self.movingSeconds(kind: kind, outcome: outcome, duration: duration) {
            movingBeforeLatest = movingSeconds
            movingSeconds += moving
            if kind == .move { stretches += 1 } else { walks += 1 }
        } else if kind == .eyes, Self.wasTaken(outcome) {
            eyeRests += 1
        }
    }

    /// True once anything has been recorded.
    public var hasHistory: Bool { firstEntry != nil }
}
