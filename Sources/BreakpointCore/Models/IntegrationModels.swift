import Foundation

/// The installable integrations (SPEC §5.5, §5.8). Raw values are the `breakpoint install <tool>`
/// arguments.
public enum IntegrationID: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case claudeCode = "claude-code"
    case cursor
    case codex
    /// Legacy Codex `notify` line in config.toml (fallback, never together with `codex`).
    case codexNotify = "codex-notify"
    case copilot
    case gemini
    case shell

    public var id: String { rawValue }

    /// The event source this integration reports as.
    public var source: AgentSource {
        switch self {
        case .claudeCode: return .claudeCode
        case .cursor: return .cursor
        case .codex, .codexNotify: return .codex
        case .copilot: return .copilot
        case .gemini: return .gemini
        case .shell: return .shell
        }
    }

    /// "Claude Code", "Cursor", "Codex CLI", …
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex CLI"
        case .codexNotify: return "Codex (legacy notify)"
        case .copilot: return "Copilot CLI"
        case .gemini: return "Gemini CLI"
        case .shell: return "Shell"
        }
    }

    /// Rows shown in Settings → Integrations (legacy notify lives under Codex's Options…).
    public static let settingsRows: [IntegrationID] = [.claudeCode, .cursor, .codex, .copilot, .gemini, .shell]
}

/// What an installer finds on disk (`Integration.status()`).
public enum IntegrationInstallState: Codable, Equatable, Hashable, Sendable {
    /// The tool's folder is absent ("Not found").
    case notFound
    /// The tool is present, Breakpoint's entries are not.
    case notInstalled
    /// Breakpoint's marked entries are present.
    case installed
    /// The file exists but does not parse; installing would be refused. `reason` is one sentence.
    case unreadable(reason: String)
    /// Breakpoint's entries are present but were written by another version (Install updates them).
    case outdated
    /// Breakpoint's entries are present but were edited by hand (Install restores them).
    case modified

    /// True when some of Breakpoint's entries are in the file (installed, outdated or modified), so
    /// the tool sends events. Use this, not `== .installed`, to decide e.g. whether relayed Cursor
    /// events are duplicates.
    public var hasBreakpointEntries: Bool {
        switch self {
        case .installed, .outdated, .modified: return true
        case .notFound, .notInstalled, .unreadable: return false
        }
    }
}

/// The status pill of an integration row (SPEC §5.6): install state merged with what the app
/// verified after Install and its record of the last event from that source.
public enum IntegrationStatus: Codable, Equatable, Hashable, Sendable {
    /// "Not found" (tool folder absent).
    case notFound
    /// "Not installed".
    case notInstalled
    /// Installed and verified (`InstallCheck`): "Connected", with "· last event 2 min ago" once
    /// the tool has sent one. The last event is information, never a condition.
    case connected(lastEvent: Date?)
    /// Something keeps it from working: the file does not parse, the entries are outdated or
    /// edited, or the install check failed. One sentence that says what to do.
    case problem(String)

    /// `checkProblem`: what `InstallCheck` found wrong with an install that reads back as current.
    public init(installState: IntegrationInstallState, lastEvent: Date?, checkProblem: String? = nil) {
        switch installState {
        case .notFound: self = .notFound
        case .notInstalled: self = .notInstalled
        case .unreadable(let reason): self = .problem(reason)
        case .outdated: self = .problem("Installed by another version of Breakpoint. Install again to update it.")
        case .modified: self = .problem("Breakpoint's entries were edited. Install again to restore them.")
        case .installed: self = checkProblem.map { .problem($0) } ?? .connected(lastEvent: lastEvent)
        }
    }

    public var isInstalled: Bool {
        if case .connected = self { return true }
        return false
    }
}
