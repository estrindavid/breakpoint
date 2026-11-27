import Foundation

/// Creates the opportunities that are not event-driven: `typingPause` and `longCommand`
/// (SPEC §2.5). Deterministic: a value type whose only state is what it already raised.
///
/// Contract:
/// - `longCommand`: once per `RunningCommand`, when it has run ≥ `Timing.longCommandDelay` and its
///   command name is not in `CommandDenylist`. Source `.shell`, session = shell PID,
///   `commandName` = the command.
/// - `typingPause`: when strict mode is off, the user is present, no break surface is showing,
///   the last key press was ≥ `Timing.typingPauseQuiet` ago, and some kind's timer is
///   ≥ 1.5 × its cadence. At most one per continuous typing pause: re-armed only after a key press
///   (`input.secondsSinceKey` drops below the quiet threshold, or the last key press moved
///   between two evaluations).
/// - Called on every coordinator tick; returns only new opportunities.
public struct OpportunityDetector: Equatable, Sendable {
    /// Commands (by shell PID + start time) that already produced a `longCommand`.
    public private(set) var raisedCommands: Set<String>
    /// A `typingPause` was raised during the current typing pause.
    public private(set) var typingPauseRaised: Bool
    /// The last key press seen at the previous evaluation (detects presses between ticks).
    private var lastKeyAt: Date?

    /// Jitter tolerance when comparing key times derived from "seconds since".
    static let keyTolerance: TimeInterval = 0.5

    public init() {
        raisedCommands = []
        typingPauseRaised = false
        lastKeyAt = nil
    }

    /// New opportunities for this tick.
    public mutating func evaluate(_ snapshot: EngineSnapshot, now: Date) -> [Opportunity] {
        var found: [Opportunity] = []

        // longCommand
        let live = Set(snapshot.commands.map(Self.key))
        raisedCommands.formIntersection(live)
        for command in snapshot.commands.sorted(by: { $0.startedAt < $1.startedAt }) {
            let key = Self.key(command)
            guard !raisedCommands.contains(key), !CommandDenylist.contains(command.command),
                  command.elapsed(at: now) >= Timing.longCommandDelay else { continue }
            raisedCommands.insert(key)
            found.append(Opportunity(kind: .longCommand, source: .shell, sessionID: command.shellPID,
                                     commandName: command.command, createdAt: now))
        }

        // typingPause
        let input = snapshot.input
        let keyAt = input.takenAt.addingTimeInterval(-max(0, input.secondsSinceKey))
        let pressedSinceLastLook = lastKeyAt.map { keyAt > $0.addingTimeInterval(Self.keyTolerance) } ?? false
        lastKeyAt = keyAt
        if input.secondsSinceKey < Timing.typingPauseQuiet || pressedSinceLastLook {
            typingPauseRaised = false
        }
        if !typingPauseRaised, input.secondsSinceKey >= Timing.typingPauseQuiet,
           !snapshot.settings.strictAgentOnly, !snapshot.presence.isAway, !snapshot.surfaceVisible,
           Self.isWellOverdue(snapshot.timers, cadence: snapshot.settings.cadence) {
            typingPauseRaised = true
            found.append(Opportunity(kind: .typingPause, createdAt: now))
        }
        return found
    }

    /// Some kind's timer is ≥ 1.5 × its cadence.
    static func isWellOverdue(_ timers: TimerState, cadence: Cadence) -> Bool {
        let factor = Timing.typingPauseCadenceFactor
        return timers.screenTime >= cadence.eyesEvery * factor || timers.stillTime >= cadence.moveEvery * factor
    }

    static func key(_ command: RunningCommand) -> String {
        "\(command.shellPID)@\(command.startedAt.timeIntervalSince1970)"
    }
}

/// Interactive programs that never produce a `longCommand` (SPEC §2.5).
public enum CommandDenylist {
    public static let names: Set<String> = [
        "vim", "nvim", "vi", "nano", "emacs", "less", "more", "man", "ssh", "mosh", "top", "htop",
        "btop", "tmux", "screen", "watch", "tail", "claude", "codex", "cursor-agent", "agent",
        "gemini", "copilot", "aider", "python", "python3", "node", "irb", "psql", "mysql", "sqlite3",
        "fzf",
    ]

    /// Whether `command` (a first word, possibly a path) is interactive.
    public static func contains(_ command: String) -> Bool {
        let name = (command as NSString).lastPathComponent
        return names.contains(name)
    }
}
