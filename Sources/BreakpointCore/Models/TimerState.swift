import Foundation

/// The two counters kept by `ActivityClock` (SPEC §2.3). Both accrue only while the user is present.
public struct TimerState: Codable, Equatable, Hashable, Sendable {
    /// Drives `eyes`.
    public var screenTime: TimeInterval
    /// Drives `move` (and `walk`, `breathe`, which are offered in its place).
    public var stillTime: TimeInterval

    public init(screenTime: TimeInterval = 0, stillTime: TimeInterval = 0) {
        self.screenTime = screenTime
        self.stillTime = stillTime
    }

    public static let zero = TimerState()

    /// The counter that drives `kind`: screen time for `eyes`, still time otherwise.
    public func value(for kind: BreakKind) -> TimeInterval {
        kind == .eyes ? screenTime : stillTime
    }

    /// Both counters plus `seconds` (used by Undo, which adds the away time back).
    public func adding(_ seconds: TimeInterval) -> TimerState {
        TimerState(screenTime: screenTime + seconds, stillTime: stillTime + seconds)
    }
}

/// A decision Breakpoint made on its own, shown with one sentence and undoable for 10 min
/// (SPEC §2.3, §3.8, §7.1).
public struct AutoDecision: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Hashable, Sendable {
        /// Away time long enough to count as these due breaks; `credited` entries were recorded.
        case creditedAway([BreakKind], duration: TimeInterval)
        /// Away time reset timers that were not yet due; nothing recorded.
        case timersReset(duration: TimeInterval)

        public var awayDuration: TimeInterval {
            switch self {
            case .creditedAway(_, let duration), .timersReset(let duration): return duration
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var madeAt: Date
    /// One sentence naming the cause: "Counted your 6 min away as a break" /
    /// "Reset timers after 4 min away".
    public var sentence: String
    /// Timers before the decision, restored by Undo.
    public var previous: TimerState
    /// `credited` history entries to delete on Undo.
    public var historyEntryIDs: [UUID]
    /// madeAt + 600 s.
    public var undoExpiresAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        madeAt: Date,
        sentence: String,
        previous: TimerState,
        historyEntryIDs: [UUID] = [],
        undoExpiresAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.madeAt = madeAt
        self.sentence = sentence
        self.previous = previous
        self.historyEntryIDs = historyEntryIDs
        self.undoExpiresAt = undoExpiresAt ?? madeAt.addingTimeInterval(Timing.undoWindow)
    }

    public func isUndoable(at now: Date) -> Bool { now < undoExpiresAt }

    /// The credited kinds (empty for `timersReset`).
    public var creditedKinds: [BreakKind] {
        if case .creditedAway(let kinds, _) = kind { return kinds }
        return []
    }
}
