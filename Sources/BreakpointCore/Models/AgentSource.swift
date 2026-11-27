import Foundation

/// The tool an event came from, as sent by `breakpoint emit --source` (SPEC §2.6, §5.6).
///
/// Any string is accepted (the "use with any tool" snippet lets users invent sources); the known
/// tools have constants. Encodes as a bare JSON string.
public struct AgentSource: RawRepresentable, Hashable, Codable, Sendable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let claudeCode: AgentSource = "claude-code"
    public static let cursor: AgentSource = "cursor"
    public static let codex: AgentSource = "codex"
    public static let copilot: AgentSource = "copilot"
    public static let gemini: AgentSource = "gemini"
    /// Long-running shell commands (`commandStarted` / `commandFinished`); never an agent session.
    public static let shell: AgentSource = "shell"

    /// Display name per SPEC §2.6: claude-code → Claude, cursor → Cursor, codex → Codex,
    /// copilot → Copilot, gemini → Gemini; any other source string as sent.
    /// `shell` returns "Shell"; use `RunningCommand.displayName` (the command name) for commands.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        case .gemini: return "Gemini"
        case .shell: return "Shell"
        default: return rawValue
        }
    }

    /// True for Claude Code, which sends `agentActivity` on every tool call; drives the 10 min
    /// (instead of 60 min) interrupt fallback (SPEC §2.6).
    public var sendsHeartbeat: Bool { self == .claudeCode }

    public var description: String { rawValue }

    public static func < (lhs: AgentSource, rhs: AgentSource) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension AgentSource: CodingKeyRepresentable {
    public var codingKey: CodingKey { AnyCodingKey(rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

/// A plain string coding key.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
