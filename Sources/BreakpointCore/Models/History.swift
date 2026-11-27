import Foundation

/// One line of `history.jsonl`: one per offer or break (SPEC §2.7).
public struct HistoryEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: BreakKind
    public var outcome: BreakOutcome
    /// What created the offer; `nil` for `credited` entries.
    public var opportunityKind: OpportunityKind?
    /// The agent behind the opportunity, if any.
    public var source: AgentSource?
    /// When the offer appeared or the break (or away period) started.
    public var start: Date
    /// Seconds the break lasted (0 for `declined` and `ignored`; the away time for `credited`).
    public var duration: TimeInterval
    /// AirPods movement check (SPEC §2.9) crossed its threshold during the break.
    public var movementDetected: Bool

    public init(
        id: UUID = UUID(),
        kind: BreakKind,
        outcome: BreakOutcome,
        opportunityKind: OpportunityKind? = nil,
        source: AgentSource? = nil,
        start: Date,
        duration: TimeInterval = 0,
        movementDetected: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.outcome = outcome
        self.opportunityKind = opportunityKind
        self.source = source
        self.start = start
        self.duration = duration
        self.movementDetected = movementDetected
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, outcome, opportunityKind, source, start, duration, movementDetected
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(BreakKind.self, forKey: .kind)
        outcome = try c.decode(BreakOutcome.self, forKey: .outcome)
        opportunityKind = try? c.decodeIfPresent(OpportunityKind.self, forKey: .opportunityKind)
        source = try c.decodeIfPresent(AgentSource.self, forKey: .source)
        start = try c.decode(Date.self, forKey: .start)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        movementDetected = try c.decodeIfPresent(Bool.self, forKey: .movementDetected) ?? false
    }
}

/// Breaks taken in one Breakpoint day (05:00–05:00) (SPEC §2.7; the debug harness reports it).
/// No score, streak or skipped count, by design (SPEC principle 5). The popover shows the
/// all-time `HistoryTotals` instead.
public struct DaySummary: Codable, Equatable, Hashable, Sendable {
    /// 05:00 local on the day summarised.
    public var dayStart: Date
    /// completed + credited.
    public var breaksTaken: Int
    /// Breaks taken per kind (for history views; never shows refusals).
    public var takenByKind: [BreakKind: Int]

    public init(dayStart: Date, breaksTaken: Int = 0, takenByKind: [BreakKind: Int] = [:]) {
        self.dayStart = dayStart
        self.breaksTaken = breaksTaken
        self.takenByKind = takenByKind
    }

    /// Summary of `entries` (any order; entries outside the day are ignored).
    public static func summarize(_ entries: [HistoryEntry], dayStart: Date, calendar: Calendar = .current) -> DaySummary {
        let day = BreakpointDay.interval(containing: dayStart, calendar: calendar)
        var byKind: [BreakKind: Int] = [:]
        var taken = 0
        for entry in entries where entry.start >= day.start && entry.start < day.end && entry.outcome.countsAsTaken {
            taken += 1
            byKind[entry.kind, default: 0] += 1
        }
        return DaySummary(dayStart: day.start, breaksTaken: taken, takenByKind: byKind)
    }
}
