import Foundation

/// What kind of natural pause created an opportunity (SPEC §2.5). Raw values are stable on disk.
public enum OpportunityKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// An `agentStarted` event arrived.
    case agentStarted
    /// A shell command has run ≥ 20 s and is not on the interactive denylist.
    case longCommand
    /// Strict mode off, no key press for ≥ 8 s, present, a timer ≥ 1.5 × cadence.
    case typingPause
    /// The user chose Take a break; bypasses the engine and starts the overlay directly.
    case manual
}

/// A moment at which a break may be offered (SPEC §2.5). Expires 30 s after creation; an expired
/// opportunity is dropped silently.
public struct Opportunity: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: OpportunityKind
    /// The agent (or `.shell`) behind it, if any.
    public var source: AgentSource?
    /// The session behind it (shell PID for `longCommand`).
    public var sessionID: String?
    /// For `longCommand`: the command name, used in "swift is running".
    public var commandName: String?
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        id: UUID = UUID(),
        kind: OpportunityKind,
        source: AgentSource? = nil,
        sessionID: String? = nil,
        commandName: String? = nil,
        createdAt: Date,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.sessionID = sessionID
        self.commandName = commandName
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Timing.opportunityLifetime)
    }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }

    /// The session key, when the opportunity came from an agent session.
    public var sessionKey: SessionKey? {
        guard let source, let sessionID, source != .shell else { return nil }
        return SessionKey(source: source, sessionID: sessionID)
    }
}
