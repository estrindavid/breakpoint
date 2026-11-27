import Foundation

// The resume card's wording (SPEC §3.5): what happened while you were away, in one strong line and
// at most one supporting line. Kept apart from Copy.swift so the card's sentences live together.

extension Copy {
    /// Why a run failed, in plain words, from the tool's error type (Claude Code `StopFailure`
    /// `error`): "Claude hit the usage limit", "Claude stopped: server error". Unknown or missing
    /// reasons: "Claude stopped with an error".
    public static func resumeFailureTitle(agent: String, reason: String?) -> String {
        switch reason {
        case "rate_limit": return "\(agent) hit the usage limit"
        case "authentication_failed", "oauth_org_not_allowed", "cloud_credential_error": return "\(agent) could not sign in"
        case "billing_error": return "\(agent) stopped: billing problem"
        case "account_on_hold": return "\(agent) stopped: account on hold"
        case "server_error": return "\(agent) stopped: server error"
        case "max_output_tokens": return "\(agent) stopped: reply too long"
        case "model_not_found": return "\(agent) stopped: model not available"
        case "invalid_request": return "\(agent) stopped: request refused"
        default: return resumeTitle(agent: agent, ending: .failed) ?? agent
        }
    }

    /// The short form for a row on a card with several rows: "usage limit", "sign-in", "error".
    public static func resumeFailureShort(reason: String?) -> String {
        switch reason {
        case "rate_limit": return "usage limit"
        case "authentication_failed", "oauth_org_not_allowed", "cloud_credential_error": return "sign-in"
        default: return "error"
        }
    }

    /// "needs you" (row status).
    public static let resumeNeedsYouStatus = "needs you"
    /// "failed" (row status of a command that failed).
    public static let resumeFailedStatus = "failed"

    /// What a waiting agent asks for. With the subject (snippets on): "Wants to run `npm install`";
    /// without: "Wants to run a command".
    public static func resumeRequestLine(_ request: AgentRequest) -> ResumeLine {
        let subject = request.subject.flatMap { $0.isEmpty ? nil : $0 }
        switch request.tool {
        case .command: return subject.map { ResumeLine("Wants to run", code: $0) } ?? ResumeLine("Wants to run a command")
        case .edit: return subject.map { ResumeLine("Wants to edit", code: $0) } ?? ResumeLine("Wants to edit a file")
        case .fetch: return subject.map { ResumeLine("Wants to open", code: $0) } ?? ResumeLine("Wants to open a web page")
        case .question: return ResumeLine("Has a question for you")
        case .plan: return ResumeLine("Has a plan for you to review")
        case .other: return ResumeLine("Wants to use a tool")
        }
    }

    /// "7 edits · 12 commands", "1 edit", "3 commands"; `nil` when there is nothing to count.
    public static func resumeCounts(edits: Int, commands: Int) -> String? {
        var parts: [String] = []
        if edits > 0 { parts.append(edits == 1 ? "1 edit" : "\(edits) edits") }
        if commands > 0 { parts.append(commands == 1 ? "1 command" : "\(commands) commands") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A long shell command that ended: "swift failed after 4 min", "swift finished in 6 min".
    public static func resumeCommandTitle(command: String, result: CommandResult) -> String {
        let duration = resumeCommandDuration(result.duration)
        return result.failed ? "\(command) failed after \(duration)" : "\(command) finished in \(duration)"
    }

    /// "45 s" under a minute (long commands start at 20 s), else "6 min", "1 h 5 min".
    public static func resumeCommandDuration(_ seconds: TimeInterval) -> String {
        if seconds < 59.5 { return "\(Int(max(0, seconds).rounded())) s" }
        return DurationFormat.minutes(seconds, rounding: .nearest)
    }

    /// Title of a card with several rows. Any needs you: "Claude needs you" (one) or "2 agents need
    /// you". Otherwise "3 agents finished", "2 commands finished", or "3 runs finished" for a mix.
    public static func resumeSeveralTitle(_ rows: [ResumeFacts]) -> String {
        let waiting = rows.filter(\.needsYou)
        if waiting.count == 1 { return needsYou(agent: waiting[0].name) }
        if waiting.count > 1 { return "\(waiting.count) agents need you" }
        let commands = rows.filter { if case .command = $0.outcome { return true } else { return false } }.count
        if commands == 0 { return agentsFinished(rows.count) }
        if commands == rows.count { return "\(rows.count) commands finished" }
        return "\(rows.count) runs finished"
    }
}
