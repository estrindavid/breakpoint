import Foundation

/// The event kinds of the wire format (SPEC §6). The raw value is the wire string.
public enum AgentEventKind: String, Codable, Sendable, CaseIterable, Hashable {
    case sessionStarted
    case agentStarted
    case agentActivity
    case agentNeedsUser
    case agentFinished
    case subagentFinished
    case sessionEnded
    case commandStarted
    case commandFinished
    /// The app's own check after Install (`InstallCheck`, SPEC §5.6), or a developer's
    /// `breakpoint emit test`. Never changes sessions and never counts as the tool's own event.
    case test

    /// True for the shell's command events, which become `RunningCommand`s, not sessions.
    public var isCommandEvent: Bool { self == .commandStarted || self == .commandFinished }
}

/// One event from a coding tool, as delivered by `breakpoint emit` over the socket (SPEC §6, §7.1).
///
/// Wire keys: `kind`, `source`, `sessionID`, `cwd`, `title`, `detail`, `via`, `ts` (seconds since
/// 1970 as a JSON number), and the optional `durationMS`, `exitCode`, `message`, `tool`, `reason`.
/// `sessionID`, `cwd`, `title`, `detail` and `via` are always written (as `null` when absent) to
/// match the SPEC §6 example; the optional keys are written only when present. Decoding ignores unknown keys and
/// throws `WireError.unknownEventKind` for an unknown kind (callers drop such events silently).
public struct AgentEvent: Codable, Equatable, Hashable, Sendable {
    public var kind: AgentEventKind
    public var source: AgentSource
    /// The tool's session id. For shell command events, the shell's PID.
    public var sessionID: String?
    /// Project folder (absolute path).
    public var cwd: String?
    /// Prompt snippet (first line, ≤ 80 characters; already cleaned by `emit`). For shell
    /// command events: the command's first word.
    public var title: String?
    /// Kind-specific detail: e.g. `idle_prompt`, `permission_prompt` for `agentNeedsUser`;
    /// `aborted`, `interrupted`, `error`, `completed`, `background` (background work still running,
    /// SPEC §2.6) for `agentFinished`.
    public var detail: String?
    /// `"claude-code-hooks"` when a Cursor event was relayed through Claude Code's hooks (SPEC §5.4).
    public var via: String?
    public var timestamp: Date
    public var durationMS: Int?
    public var exitCode: Int?
    /// Sensitive text, kept only under "Keep prompt snippets" and already cleaned and masked by
    /// `emit` (SPEC §5.6): on `agentFinished`, the first line of the agent's last message; on
    /// `agentNeedsUser`, what the agent asks for (the command, file name or host).
    public var message: String?
    /// The kind of tool an `agentNeedsUser` asks to use, or an `agentActivity` just used.
    public var tool: AgentToolKind?
    /// Why a run failed (`agentFinished` with detail `error`), as the tool names it: `rate_limit`, …
    public var reason: String?

    public init(
        kind: AgentEventKind,
        source: AgentSource,
        sessionID: String? = nil,
        cwd: String? = nil,
        title: String? = nil,
        detail: String? = nil,
        via: String? = nil,
        timestamp: Date,
        durationMS: Int? = nil,
        exitCode: Int? = nil,
        message: String? = nil,
        tool: AgentToolKind? = nil,
        reason: String? = nil
    ) {
        self.kind = kind
        self.source = source
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.detail = detail
        self.via = via
        self.timestamp = timestamp
        self.durationMS = durationMS
        self.exitCode = exitCode
        self.message = message
        self.tool = tool
        self.reason = reason
    }

    /// The `via` value marking a Cursor event relayed through Claude Code's hooks.
    public static let viaClaudeCodeHooks = "claude-code-hooks"

    /// The project folder's last path component, if any ("breakpoint" for "/Users/x/breakpoint").
    public var projectName: String? { cwd.flatMap(PathDisplay.folderName) }

    enum CodingKeys: String, CodingKey {
        case kind, source, sessionID, cwd, title, detail, via
        case timestamp = "ts"
        case durationMS, exitCode, message, tool, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try c.decode(String.self, forKey: .kind)
        guard let kind = AgentEventKind(rawValue: rawKind) else {
            throw WireError.unknownEventKind(rawKind)
        }
        self.kind = kind
        source = try c.decode(AgentSource.self, forKey: .source)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        via = try c.decodeIfPresent(String.self, forKey: .via)
        let seconds = try c.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: seconds)
        durationMS = try c.decodeIfPresent(Int.self, forKey: .durationMS)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        tool = try c.decodeIfPresent(String.self, forKey: .tool).map { AgentToolKind(rawValue: $0) ?? .other }
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(source, forKey: .source)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(title, forKey: .title)
        try c.encode(detail, forKey: .detail)
        try c.encode(via, forKey: .via)
        try c.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
        try c.encodeIfPresent(durationMS, forKey: .durationMS)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(tool?.rawValue, forKey: .tool)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
}

/// What a tool call does, as far as the resume card cares (SPEC §3.5). The raw value is the wire
/// string; unknown strings decode as `other`.
public enum AgentToolKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Runs a shell command (Claude Code `Bash`, Codex shell tools).
    case command
    /// Edits or writes a file.
    case edit
    /// Opens a web page.
    case fetch
    /// Asks the user a question (Claude Code `AskUserQuestion`, MCP elicitation).
    case question
    /// Presents a plan for approval (Claude Code `ExitPlanMode`).
    case plan
    /// Any other tool.
    case other
}
