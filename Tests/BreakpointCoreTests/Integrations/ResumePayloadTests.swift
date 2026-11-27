import Foundation
import Testing
@testable import BreakpointCore

/// Realistic payloads for the facts the resume card shows (SPEC §3.5, §5.6). Field names are the
/// ones docs/research/agent-integrations.md lists; the shapes inside `tool_input` (`command`,
/// `file_path`, `url`) follow Claude Code's tool reference and are read defensively. The keys and
/// tokens in the `…Secret` payloads are made up and marked FAKE: they only exercise the masking.
enum ResumePayloads {
    static let claudeStopMarkdown = ###"{"session_id":"abc123","transcript_path":"/x.jsonl","cwd":"/Users/me/code/app","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"## Summary\n\nFixed the login redirect: the **OAuth callback** now keeps the original URL, and all 214 tests pass.\n\n- `AuthController.swift`: keep `returnTo`\n- tests updated","background_tasks":[],"session_crons":[]}"###
    static let claudeStopLeadIn = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Here's what I changed:\n\n1. Moved token parsing into [its own module](src/token.ts)\n2. Added tests","background_tasks":[]}"###
    static let claudeStopBackground = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"The test suite is running in the background; I'll report when it finishes.","background_tasks":[{"id":"bash_1","type":"shell","status":"running","description":"swift test"}],"session_crons":[]}"###
    static let claudeStopBackgroundDone = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"All tests pass.","background_tasks":[{"id":"bash_1","type":"shell","status":"completed","description":"swift test"}],"session_crons":[]}"###
    static let claudeStopSecret = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"Stop","last_assistant_message":"Set OPENAI_API_KEY=sk-proj-FAKE-key-for-tests-only in .env and restarted the server.","background_tasks":[]}"###
    static let claudeStopFailureAuth = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"StopFailure","error":"authentication_failed","error_details":"401","last_assistant_message":"API Error: 401 {\"type\":\"error\"}"}"###
    static let claudePermissionSecret = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"curl -H 'Authorization: Bearer ghp_FAKE_token_for_tests_only' https://api.github.com\n  | jq .login","description":"Check the token"}}"###
    static let claudePermissionEdit = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/Users/me/code/app/Sources/Auth/OAuthCallbackController.swift","old_string":"a","new_string":"b"}}"###
    static let claudePermissionFetch = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"PermissionRequest","tool_name":"WebFetch","tool_input":{"url":"https://developer.apple.com/documentation/swiftui","prompt":"summarise"}}"###
    static let claudePermissionMCP = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"PermissionRequest","tool_name":"mcp__github__create_issue","tool_input":{"title":"x"},"mcp_server":"github"}"###
    static let claudeAskQuestion = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?"}]}}"###
    static let claudeElicitation = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"Notification","message":"MCP server needs input","notification_type":"elicitation_dialog"}"###
    static let claudePostToolEdit = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/Users/me/code/app/README.md","content":"# App"},"tool_response":{"success":true},"tool_use_id":"toolu_1"}"###
    static let claudePostToolBash = ###"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"swift build"},"tool_response":{"stdout":"Build complete"},"tool_use_id":"toolu_2"}"###

    static let codexStop = ###"{"session_id":"thr_123","transcript_path":"/workspace/.codex/rollout.jsonl","cwd":"/workspace","hook_event_name":"Stop","model":"o4","turn_id":"t1","stop_hook_active":false,"last_assistant_message":"Renamed `handle` to `handleWebhook` and updated the 6 callers."}"###
    static let codexPermission = ###"{"session_id":"thr_123","cwd":"/workspace","hook_event_name":"PermissionRequest","turn_id":"t2","tool_name":"shell","tool_input":{"command":["bash","-lc","npm install"],"description":"Install dependencies"}}"###
}

@Suite("Hook payloads for the resume card")
struct ResumePayloadTests {
    let now = Date(timeIntervalSince1970: 1_795_400_000)

    func parse(_ kind: AgentEventKind, _ source: AgentSource, _ payload: String, snippets: Bool = true,
               mode: EmitRequest.PayloadMode = .stdinJSON, detail: String? = nil) -> AgentEvent? {
        let request = EmitRequest(kind: kind, source: source, detail: detail, payloadMode: mode, payload: Data(payload.utf8))
        return HookPayloadParser.event(from: request, environment: [:], now: now, storePromptSnippets: snippets)
    }

    // MARK: Claude Code

    @Test func claudeStopCarriesTheFirstLineOfTheLastMessage() throws {
        let plain = try #require(parse(.agentFinished, .claudeCode, Payloads.claudeStop))
        #expect(plain.message == "I've completed the refactoring..." && plain.detail == nil && plain.reason == nil)
        // The heading is skipped; Markdown markers go.
        let markdown = try #require(parse(.agentFinished, .claudeCode, ResumePayloads.claudeStopMarkdown))
        #expect(markdown.message == "Fixed the login redirect: the OAuth callback now keeps the original URL, and all 214 tests pass.")
        let leadIn = try #require(parse(.agentFinished, .claudeCode, ResumePayloads.claudeStopLeadIn))
        #expect(leadIn.message == "Here's what I changed: Moved token parsing into its own module")
    }

    @Test func secretsInMessagesAreMasked() throws {
        let event = try #require(parse(.agentFinished, .claudeCode, ResumePayloads.claudeStopSecret))
        #expect(event.message == "Set OPENAI_API_KEY=••• in .env and restarted the server.")
    }

    @Test func aStopWithBackgroundWorkIsNotFinished() throws {
        let busy = try #require(parse(.agentFinished, .claudeCode, ResumePayloads.claudeStopBackground))
        #expect(busy.kind == .agentFinished && busy.detail == HookPayloadParser.backgroundDetail)
        // Tasks that are all done no longer hold the run open.
        let done = try #require(parse(.agentFinished, .claudeCode, ResumePayloads.claudeStopBackgroundDone))
        #expect(done.detail == nil && done.message == "All tests pass.")
    }

    @Test func stopFailureCarriesItsReasonNotTheRawError() throws {
        // As installed: StopFailure's hook passes `--detail error`.
        let limit = try #require(parse(.agentFinished, .claudeCode, Payloads.claudeStopFailure, detail: "error"))
        #expect(limit.detail == "error" && limit.reason == "rate_limit" && limit.message == nil)
        let auth = try #require(parse(.agentFinished, .claudeCode, ResumePayloads.claudeStopFailureAuth))
        #expect(auth.reason == "authentication_failed" && auth.message == nil)
    }

    @Test func permissionRequestsSayWhatTheAgentWants() throws {
        let rm = try #require(parse(.agentNeedsUser, .claudeCode, Payloads.claudePermission))
        #expect(rm.tool == .command && rm.message == "rm -rf build")
        // One line, and the token masked.
        let curl = try #require(parse(.agentNeedsUser, .claudeCode, ResumePayloads.claudePermissionSecret))
        #expect(curl.tool == .command && curl.message == "curl -H 'Authorization: Bearer ••• https://api.github.com")
        // A file's name, never its folder.
        let edit = try #require(parse(.agentNeedsUser, .claudeCode, ResumePayloads.claudePermissionEdit))
        #expect(edit.tool == .edit && edit.message == "OAuthCallbackController.swift")
        let fetch = try #require(parse(.agentNeedsUser, .claudeCode, ResumePayloads.claudePermissionFetch))
        #expect(fetch.tool == .fetch && fetch.message == "developer.apple.com")
        let mcp = try #require(parse(.agentNeedsUser, .claudeCode, ResumePayloads.claudePermissionMCP))
        #expect(mcp.tool == .other && mcp.message == nil)
        let ask = try #require(parse(.agentNeedsUser, .claudeCode, ResumePayloads.claudeAskQuestion))
        #expect(ask.tool == .question && ask.message == nil)
        let elicitation = try #require(parse(.agentNeedsUser, .claudeCode, ResumePayloads.claudeElicitation))
        #expect(elicitation.tool == .question && elicitation.detail == "elicitation_dialog")
        // A plain permission notification names no tool (the request already known is kept).
        let notification = try #require(parse(.agentNeedsUser, .claudeCode, Payloads.claudeNotification))
        #expect(notification.tool == nil && notification.message == nil)
    }

    @Test func toolUseHeartbeatsNameTheKindOnly() throws {
        let write = try #require(parse(.agentActivity, .claudeCode, ResumePayloads.claudePostToolEdit))
        #expect(write.tool == .edit && write.message == nil)
        let bash = try #require(parse(.agentActivity, .claudeCode, ResumePayloads.claudePostToolBash))
        #expect(bash.tool == .command && bash.message == nil)
    }

    @Test func snippetsOffKeepsOnlyTheNonSensitiveFacts() throws {
        let stop = try #require(parse(.agentFinished, .claudeCode, ResumePayloads.claudeStopMarkdown, snippets: false))
        #expect(stop.message == nil && stop.title == nil)
        let ask = try #require(parse(.agentNeedsUser, .claudeCode, Payloads.claudePermission, snippets: false))
        #expect(ask.message == nil && ask.tool == .command)
        let failure = try #require(parse(.agentFinished, .claudeCode, Payloads.claudeStopFailure, snippets: false, detail: "error"))
        #expect(failure.reason == "rate_limit")
        let busy = try #require(parse(.agentFinished, .claudeCode, ResumePayloads.claudeStopBackground, snippets: false))
        #expect(busy.detail == HookPayloadParser.backgroundDetail)
    }

    // MARK: Codex

    @Test func codexStopAndPermission() throws {
        let stop = try #require(parse(.agentFinished, .codex, ResumePayloads.codexStop))
        #expect(stop.message == "Renamed handle to handleWebhook and updated the 6 callers.")
        let ask = try #require(parse(.agentNeedsUser, .codex, ResumePayloads.codexPermission))
        #expect(ask.tool == .command && ask.message == "npm install")
        let notify = try #require(parse(.agentFinished, .codex, Payloads.codexNotify, mode: .argvJSON))
        #expect(notify.message == "Done.")
        let interrupt = try #require(parse(.agentFinished, .codex, Payloads.codexInterrupt))
        #expect(interrupt.message == nil && interrupt.detail == "interrupted")
    }

    // MARK: Other tools and the shell

    @Test func otherToolsSendNoMessage() throws {
        #expect(parse(.agentFinished, .cursor, Payloads.cursorStop)?.message == nil)
        #expect(parse(.agentFinished, .copilot, Payloads.copilotStop)?.message == nil)
        #expect(parse(.agentFinished, .gemini, Payloads.geminiNoSession)?.message == nil)
    }

    @Test func shellOutcomeComesFromFlags() throws {
        let request = EmitRequest(kind: .commandFinished, source: .shell, sessionID: "4242", title: "swift",
                                  durationMS: 241_000, exitCode: 1)
        let event = try #require(HookPayloadParser.event(from: request, environment: [:], now: now))
        #expect(event.title == "swift" && event.durationMS == 241_000 && event.exitCode == 1 && event.message == nil)
    }

    // MARK: Cleaning

    @Test(arguments: [
        ("Done.", "Done."),
        ("# Title\n\nBody", "Body"),
        ("## Done", "Done"),
        ("```swift\nlet x = 1\n```\nCompiled cleanly.", "Compiled cleanly."),
        ("---\n> **Note:** the cache was stale", "Note: the cache was stale"),
        ("- [x] Wrote tests", "Wrote tests"),
        ("| a | b |\n|---|---|\nTable above.", "Table above."),
        ("See [the docs](https://example.com) for more.", "See the docs for more."),
        ("Steps:", "Steps:"),
        ("   \n\n", nil),
        ("```\nonly code\n```", nil),
    ] as [(String, String?)])
    func cleanMessage(_ raw: String, _ expected: String?) {
        #expect(HookPayloadParser.cleanMessage(raw) == expected)
    }

    @Test func longMessagesAreTrimmed() throws {
        let long = String(repeating: "word ", count: 60)
        let cleaned = try #require(HookPayloadParser.cleanMessage(long))
        #expect(cleaned.count <= HookPayloadParser.messageLimit + 1 && cleaned.hasSuffix("…"))
        let command = try #require(RequestSubject.command(String(repeating: "x ", count: 50)))
        #expect(command.count <= RequestSubject.limit + 1 && command.hasSuffix("…"))
    }

    @Test(arguments: [
        ("Bash", AgentToolKind.command), ("Edit", .edit), ("MultiEdit", .edit), ("Write", .edit), ("NotebookEdit", .edit),
        ("WebFetch", .fetch), ("AskUserQuestion", .question), ("ExitPlanMode", .plan), ("apply_patch", .edit),
        ("shell", .command), ("Task", .other), ("mcp__github__create_issue", .other),
    ])
    func toolKinds(_ name: String, _ kind: AgentToolKind) {
        #expect(AgentToolKind(toolName: name) == kind)
    }

    // MARK: Wire

    @Test func newFieldsRoundTripAndAreOptional() throws {
        let event = AgentEvent(kind: .agentNeedsUser, source: .claudeCode, sessionID: "s", timestamp: now,
                               message: "npm install", tool: .command, reason: nil)
        let data = try JSONEncoder().encode(event)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"message\":\"npm install\"") && text.contains("\"tool\":\"command\"") && !text.contains("reason"))
        #expect(try JSONDecoder().decode(AgentEvent.self, from: data) == event)
        // Older lines without the fields, and a tool kind from a newer version.
        let old = #"{"kind":"agentFinished","source":"codex","ts":1795400000}"#
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: Data(old.utf8))
        #expect(decoded.message == nil && decoded.tool == nil && decoded.reason == nil)
        let newer = #"{"kind":"agentActivity","source":"codex","ts":1795400000,"tool":"teleport"}"#
        #expect(try JSONDecoder().decode(AgentEvent.self, from: Data(newer.utf8)).tool == .other)
        // A plain event is written exactly as before.
        let plain = String(decoding: try JSONEncoder().encode(AgentEvent(kind: .agentStarted, source: .codex, timestamp: now)), as: UTF8.self)
        #expect(!plain.contains("message") && !plain.contains("tool"))
    }
}
