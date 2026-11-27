import Foundation

/// A session's state (SPEC §2.6).
public enum AgentState: String, Codable, Sendable, Hashable, CaseIterable {
    /// Running a prompt.
    case working
    /// Needs the user (permission prompt, question, likely interrupt).
    case waiting
    /// Between prompts.
    case idle

    /// Urgency for "most urgent session" choices: waiting > working > idle (SPEC §3.3 row 1).
    public var urgency: Int {
        switch self {
        case .waiting: return 2
        case .working: return 1
        case .idle: return 0
        }
    }
}

/// Identity of an agent session: (source, sessionID) (SPEC §2.6).
public struct SessionKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var source: AgentSource
    public var sessionID: String

    public init(source: AgentSource, sessionID: String) {
        self.source = source
        self.sessionID = sessionID
    }

    public var description: String { "\(source.rawValue)/\(sessionID)" }

    public static func < (lhs: SessionKey, rhs: SessionKey) -> Bool {
        (lhs.source.rawValue, lhs.sessionID) < (rhs.source.rawValue, rhs.sessionID)
    }
}

/// How the most recent run of a session ended. Drives the resume card title (SPEC §3.5).
public enum RunEnding: Codable, Equatable, Hashable, Sendable {
    /// Finished normally after running `duration` seconds ("Claude finished · ran 6 min").
    case finished(duration: TimeInterval)
    /// Finished with an error (`StopFailure`, Cursor `status: error`): "Claude stopped with an error".
    /// The run is not recorded for the run-length estimator.
    case failed
    /// Aborted or interrupted by the user, superseded by a new prompt, or ended by the interrupt
    /// fallback. Not recorded; no resume card.
    case cancelled
}

/// What a waiting agent asks for (SPEC §3.5): "Wants to run `npm install`".
public struct AgentRequest: Codable, Equatable, Hashable, Sendable {
    public var tool: AgentToolKind
    /// The command, file name or host; only with "Keep prompt snippets" on (masked, one line).
    public var subject: String?

    public init(tool: AgentToolKind, subject: String? = nil) {
        self.tool = tool
        self.subject = subject
    }
}

/// Facts about a session's current or latest run, for the resume card (SPEC §3.5). Reset when a
/// run starts. The sensitive ones (`message`, `request.subject`) exist only while "Keep prompt
/// snippets" is on, in memory only.
public struct RunReport: Codable, Equatable, Hashable, Sendable {
    /// Files edited and commands run during the run (from `agentActivity` events that name a tool).
    public var edits: Int
    public var commands: Int
    /// First line of the agent's last message (sensitive).
    public var message: String?
    /// Why the run failed, as the tool names it (`rate_limit`, …); not sensitive.
    public var failure: String?
    /// What the agent asks for while `waiting`.
    public var request: AgentRequest?

    public init(edits: Int = 0, commands: Int = 0, message: String? = nil, failure: String? = nil,
                request: AgentRequest? = nil) {
        self.edits = edits
        self.commands = commands
        self.message = message
        self.failure = failure
        self.request = request
    }

    public static let empty = RunReport()

    /// The same facts without anything sensitive.
    public var withoutSensitiveText: RunReport {
        var copy = self
        copy.message = nil
        copy.request?.subject = nil
        return copy
    }
}

/// A coding-agent session tracked by `SessionTracker` (SPEC §2.6).
public struct AgentSession: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var key: SessionKey
    public var state: AgentState
    /// Project folder (absolute path), from the latest event that carried one.
    public var cwd: String?
    /// Prompt snippet of the current or latest run; `nil` when "Keep prompt snippets" is off.
    public var title: String?
    public var createdAt: Date
    /// Time of the latest event of any kind for this session (drives the stale fallback).
    public var lastEventAt: Date
    /// Start of the current run while `state` is `.working` or `.waiting`; `nil` when idle.
    public var runStartedAt: Date?
    /// When the session last entered `.waiting`.
    public var waitingSince: Date?
    /// How the latest completed run ended, if any.
    public var lastRunEnding: RunEnding?
    /// When the latest run ended.
    public var lastRunEndedAt: Date?
    /// `AgentEvent.via` of the latest event (relay detection, SPEC §5.4).
    public var via: String?
    /// Facts about the current or latest run (resume card, SPEC §3.5).
    public var report: RunReport

    public init(
        key: SessionKey,
        state: AgentState = .idle,
        cwd: String? = nil,
        title: String? = nil,
        createdAt: Date,
        lastEventAt: Date? = nil,
        runStartedAt: Date? = nil,
        waitingSince: Date? = nil,
        lastRunEnding: RunEnding? = nil,
        lastRunEndedAt: Date? = nil,
        via: String? = nil,
        report: RunReport = .empty
    ) {
        self.key = key
        self.state = state
        self.cwd = cwd
        self.title = title
        self.createdAt = createdAt
        self.lastEventAt = lastEventAt ?? createdAt
        self.runStartedAt = runStartedAt
        self.waitingSince = waitingSince
        self.lastRunEnding = lastRunEnding
        self.lastRunEndedAt = lastRunEndedAt
        self.via = via
        self.report = report
    }

    public var id: SessionKey { key }
    public var source: AgentSource { key.source }
    /// "Claude", "Cursor", … (SPEC §2.6).
    public var displayName: String { key.source.displayName }
    /// Last path component of `cwd`.
    public var projectName: String? { cwd.flatMap(PathDisplay.folderName) }

    /// Seconds the current run has been going at `now`, or `nil` when idle.
    public func runElapsed(at now: Date) -> TimeInterval? {
        runStartedAt.map { max(0, now.timeIntervalSince($0)) }
    }
}

/// A shell command that sent `commandStarted` and no `commandFinished` yet (SPEC §2.5, §2.6).
public struct RunningCommand: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The shell's PID as sent in `--session`.
    public var shellPID: String
    /// The command's first word only (the shell snippet never sends more).
    public var command: String
    public var cwd: String?
    public var startedAt: Date

    public init(shellPID: String, command: String, cwd: String? = nil, startedAt: Date) {
        self.shellPID = shellPID
        self.command = command
        self.cwd = cwd
        self.startedAt = startedAt
    }

    /// One command runs per shell at a time, so the PID identifies it.
    public var id: String { shellPID }
    /// The command name ("swift"), per SPEC §2.6.
    public var displayName: String { command }
    public var projectName: String? { cwd.flatMap(PathDisplay.folderName) }

    public func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(startedAt)) }
}

/// How a shell command ended, as the shell reported it (`commandFinished` with `--exit-code` and
/// `--duration-ms`). Attached to `SessionTransition.commandFinished` when the shell sent it.
public struct CommandResult: Codable, Equatable, Hashable, Sendable {
    /// The command's exit status, if the shell sent one.
    public var exitCode: Int?
    /// How long it ran: the shell's own measurement, else the time since `commandStarted`.
    public var duration: TimeInterval

    public init(exitCode: Int?, duration: TimeInterval) {
        self.exitCode = exitCode
        self.duration = duration
    }

    /// Exit status 130 is the shell's code for an interrupt (Control-C): not a failure.
    public static let interruptedExitCode = 130

    public var wasInterrupted: Bool { exitCode == Self.interruptedExitCode }
    public var failed: Bool { (exitCode ?? 0) != 0 && !wasInterrupted }
}
