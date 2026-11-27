import Foundation

/// One line of text on a resume card, with an optional piece shown in code type after the text:
/// "Wants to run" + `npm install`.
public struct ResumeLine: Equatable, Hashable, Sendable {
    public var text: String
    /// Shown in monospaced type after `text` (a command, file name or host).
    public var code: String?

    public init(_ text: String, code: String? = nil) {
        self.text = text
        self.code = code
    }

    /// The whole line as plain text ("Wants to run npm install").
    public var plain: String { code.map { "\(text) \($0)" } ?? text }
}

/// What one row of a resume card says (SPEC §3.5): built by the coordinator from an agent session
/// or a long shell command that ended while the user was away. Pure, so the wording is tested in
/// Core; the view only lays it out.
///
/// Privacy: `message`, `snippet` and a request's subject are sensitive and are present only when
/// "Keep prompt snippets" is on (`keepSnippets`). Everything else (outcome, duration, failure
/// reason, the kind of request, counts, folder, command name) is shown either way.
public struct ResumeFacts: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The run finished normally after `duration` seconds (wall time).
        case finished(duration: TimeInterval)
        /// The run stopped with an error; `reason` as the tool names it (`rate_limit`, …).
        case failed(reason: String?)
        /// The agent is waiting for the user, optionally saying for what.
        case needsYou(AgentRequest?)
        /// A long shell command ended.
        case command(CommandResult)
    }

    /// "Claude", or the command's name ("swift").
    public var name: String
    /// Project folder name.
    public var folder: String?
    public var outcome: Outcome
    /// First line of the agent's last message (snippets on only).
    public var message: String?
    /// The prompt snippet (snippets on only).
    public var snippet: String?
    /// Files edited and commands run during the run.
    public var edits: Int
    public var commands: Int

    public init(name: String, folder: String?, outcome: Outcome, message: String? = nil, snippet: String? = nil,
                edits: Int = 0, commands: Int = 0) {
        self.name = name
        self.folder = folder
        self.outcome = outcome
        self.message = message
        self.snippet = snippet
        self.edits = edits
        self.commands = commands
    }

    // MARK: Building

    /// The facts for a session's resume card row, or `nil` when there is nothing to say: the session
    /// is working again, or its latest run was cancelled.
    public static func session(_ session: AgentSession, keepSnippets: Bool) -> ResumeFacts? {
        let report = keepSnippets ? session.report : session.report.withoutSensitiveText
        let outcome: Outcome
        switch session.state {
        case .working:
            return nil
        case .waiting:
            outcome = .needsYou(report.request)
        case .idle:
            switch session.lastRunEnding {
            case .finished(let duration): outcome = .finished(duration: duration)
            case .failed: outcome = .failed(reason: report.failure)
            case .cancelled, .none: return nil
            }
        }
        return ResumeFacts(name: session.displayName, folder: session.projectName, outcome: outcome,
                           message: report.message.flatMap(Self.nonEmpty),
                           snippet: keepSnippets ? session.title.flatMap(Self.nonEmpty).map { TextFormat.truncated($0, limit: 80) } : nil,
                           edits: report.edits, commands: report.commands)
    }

    /// The facts for a long shell command that ended (the command name is never sensitive: the
    /// shell sends nothing else).
    public static func command(_ command: RunningCommand, result: CommandResult) -> ResumeFacts {
        ResumeFacts(name: command.displayName, folder: command.projectName, outcome: .command(result))
    }

    /// Whether a shell command that ended belongs on the resume card: it ran at least as long as a
    /// command has to run to count as long (`Timing.longCommandDelay`) and was not interrupted.
    public static func commandIsWorthShowing(_ result: CommandResult) -> Bool {
        result.duration >= Timing.longCommandDelay && !result.wasInterrupted
    }

    // MARK: What the card says

    public var needsYou: Bool { if case .needsYou = outcome { return true } else { return false } }

    /// The run or command ended badly (shown with "!" instead of "✓").
    public var failed: Bool {
        switch outcome {
        case .failed: return true
        case .command(let result): return result.failed
        case .finished, .needsYou: return false
        }
    }

    /// Rows are listed needs-you first, then failures, then everything else (SPEC §3.5).
    public var sortRank: Int { needsYou ? 0 : failed ? 1 : 2 }

    /// The strong line: "Claude finished · ran 6 min", "Claude hit the usage limit",
    /// "Claude needs you", "swift failed after 4 min".
    public var headline: String {
        switch outcome {
        case .finished(let duration): return Copy.resumeTitle(agent: name, ending: .finished(duration: duration)) ?? name
        case .failed(let reason): return Copy.resumeFailureTitle(agent: name, reason: reason)
        case .needsYou: return Copy.needsYou(agent: name)
        case .command(let result): return Copy.resumeCommandTitle(command: name, result: result)
        }
    }

    /// The one supporting line of a single-row card, or `nil`:
    /// - needs you: what it asks for ("Wants to run `npm install`"), else the prompt snippet;
    /// - finished: the agent's last message, else the prompt snippet, else the counts;
    /// - failed: the prompt snippet, else the counts;
    /// - a command: nothing (the title says it all).
    public var detail: ResumeLine? {
        switch outcome {
        case .needsYou(let request):
            if let request { return Copy.resumeRequestLine(request) }
            return snippet.map { ResumeLine($0) }
        case .finished:
            if let message { return ResumeLine(message) }
            if let snippet { return ResumeLine(snippet) }
            return Copy.resumeCounts(edits: edits, commands: commands).map { ResumeLine($0) }
        case .failed:
            if let snippet { return ResumeLine(snippet) }
            return Copy.resumeCounts(edits: edits, commands: commands).map { ResumeLine($0) }
        case .command:
            return nil
        }
    }

    /// The right-hand status of a row on a card with several rows: "6 min", "usage limit",
    /// "needs you", "failed".
    public var shortStatus: String {
        switch outcome {
        case .finished(let duration): return DurationFormat.minutes(duration, rounding: .nearest)
        case .failed(let reason): return Copy.resumeFailureShort(reason: reason)
        case .needsYou: return Copy.resumeNeedsYouStatus
        case .command(let result): return result.failed ? Copy.resumeFailedStatus : Copy.resumeCommandDuration(result.duration)
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
