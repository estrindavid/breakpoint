import Foundation
import Testing
@testable import BreakpointCore

/// Hook payloads as documented in docs/research/agent-integrations.md (fetched 2026-11-22).
enum Payloads {
    static let claudeSessionStart = #"{"session_id":"abc123","transcript_path":"/Users/me/.claude/projects/p/00893aaf.jsonl","cwd":"/Users/me/code/app/src","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5"}"#
    static let claudePrompt = #"{"session_id":"abc123","transcript_path":"/x.jsonl","cwd":"/Users/me/code/app","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"Write a function to calculate the factorial of a number"}"#
    static let claudeStop = #"{"session_id":"abc123","transcript_path":"/x.jsonl","cwd":"/Users/me/code/app","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"I've completed the refactoring...","background_tasks":[],"session_crons":[]}"#
    static let claudeStopFailure = #"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"API Error"}"#
    static let claudeNotification = #"{"session_id":"abc123","transcript_path":"/x.jsonl","cwd":"/Users/me/code/app","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#
    static let claudeIdle = #"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"Notification","message":"Claude is waiting","notification_type":"idle_prompt"}"#
    static let claudeAuth = #"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"Notification","notification_type":"auth_success"}"#
    static let claudePermission = #"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
    static let claudeSubagentInternal = #"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"","stop_hook_active":false}"#
    static let claudeSubagent = #"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"Explore","stop_hook_active":false}"#
    static let claudeSessionEnd = #"{"session_id":"abc123","cwd":"/Users/me/code/app","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#

    static let cursorPrompt = #"{"conversation_id":"conv-1","generation_id":"gen-1","model":"gpt-5","model_id":"m","model_params":[],"hook_event_name":"beforeSubmitPrompt","cursor_version":"2.1.0","workspace_roots":["/Users/me/code/web","/Users/me/code/lib"],"user_email":null,"transcript_path":null,"prompt":"fix the login redirect","attachments":[]}"#
    static let cursorStop = #"{"conversation_id":"conv-1","generation_id":"gen-2","hook_event_name":"stop","cursor_version":"2.1.0","workspace_roots":["/Users/me/code/web"],"status":"aborted","loop_count":0}"#
    static let cursorSessionStart = #"{"session_id":"sess-9","conversation_id":"","hook_event_name":"sessionStart","cursor_version":"2.1.0","workspace_roots":[],"is_background_agent":false,"composer_mode":"agent"}"#
    /// Cursor running Claude Code's user hooks (third-party hooks): Cursor's payload shape.
    static let cursorRelayedPrompt = #"{"conversation_id":"conv-7","hook_event_name":"UserPromptSubmit","cursor_version":"2.1.0","workspace_roots":["/Users/me/code/web"],"prompt":"add tests"}"#

    static let codexPrompt = #"{"session_id":"thr_123","transcript_path":"/workspace/.codex/rollout.jsonl","cwd":"/workspace","hook_event_name":"UserPromptSubmit","model":"o4","turn_id":"t1","permission_mode":"default","prompt":"refactor the parser"}"#
    static let codexInterrupt = #"{"session_id":"thr_123","cwd":"/workspace","hook_event_name":"Interrupt","turn_id":"t1","permission_mode":"default"}"#
    static let codexSessionEnd = #"{"session_id":"thr_123","transcript_path":"/workspace/.codex/rollout.jsonl","cwd":"/workspace","hook_event_name":"SessionEnd","reason":"other"}"#
    static let codexNotify = #"{"type":"agent-turn-complete","thread-id":"thr_456","turn-id":"t9","cwd":"/workspace/api","client":"codex-tui","input-messages":["Rename the handler\nand update callers"],"last-assistant-message":"Done."}"#
    static let codexNotifyOther = #"{"type":"approval-requested","thread-id":"thr_456","cwd":"/workspace/api"}"#

    static let copilotPrompt = #"{"sessionId":"cp-1","timestamp":1795400000000,"cwd":"/Users/me/code/cli","prompt":"explain this error"}"#
    static let copilotNotification = #"{"sessionId":"cp-1","cwd":"/Users/me/code/cli","notification_type":"permission_prompt","message":"Approve?"}"#
    static let copilotIdle = #"{"sessionId":"cp-1","cwd":"/Users/me/code/cli","notification_type":"agent_idle"}"#
    static let copilotStop = #"{"sessionId":"cp-1","cwd":"/Users/me/code/cli","stopReason":"end_turn"}"#

    static let geminiBeforeAgent = #"{"session_id":"g-1","cwd":"/Users/me/code/ml","hook_event_name":"BeforeAgent","prompt":"plot the loss"}"#
    static let geminiNoSession = #"{"cwd":"/Users/me/code/ml","hook_event_name":"AfterAgent"}"#
    static let geminiNotification = #"{"session_id":"g-1","cwd":"/Users/me/code/ml","hook_event_name":"Notification","notification_type":"ToolPermission","message":"Allow?"}"#
}

@Suite("Hook payload parser")
struct HookPayloadParserTests {
    let now = Date(timeIntervalSince1970: 1_795_400_000)

    func parse(_ kind: AgentEventKind, _ source: AgentSource, _ payload: String?, env: [String: String] = [:],
               mode: EmitRequest.PayloadMode = .stdinJSON, flags: (EmitRequest) -> EmitRequest = { $0 }) -> AgentEvent? {
        let request = flags(EmitRequest(kind: kind, source: source, payloadMode: mode, payload: payload.map { Data($0.utf8) }))
        return HookPayloadParser.event(from: request, environment: env, now: now)
    }

    @Test func claudeCode() throws {
        let start = try #require(parse(.sessionStarted, .claudeCode, Payloads.claudeSessionStart))
        #expect(start.sessionID == "abc123")
        #expect(start.cwd == "/Users/me/code/app/src")
        #expect(start.source == .claudeCode && start.via == nil)

        let prompt = try #require(parse(.agentStarted, .claudeCode, Payloads.claudePrompt, env: ["CLAUDE_PROJECT_DIR": "/Users/me/code/app", "CLAUDECODE": "1"]))
        #expect(prompt.kind == .agentStarted)
        #expect(prompt.title == "Write a function to calculate the factorial of a number")
        #expect(prompt.cwd == "/Users/me/code/app")
        #expect(prompt.timestamp == now)

        #expect(parse(.agentFinished, .claudeCode, Payloads.claudeStop)?.detail == nil)
        #expect(parse(.agentFinished, .claudeCode, Payloads.claudeStopFailure)?.detail == "error")
        #expect(parse(.agentNeedsUser, .claudeCode, Payloads.claudeNotification)?.detail == "permission_prompt")
        #expect(parse(.agentNeedsUser, .claudeCode, Payloads.claudeIdle)?.detail == "idle_prompt")
        #expect(parse(.agentNeedsUser, .claudeCode, Payloads.claudeAuth) == nil)
        #expect(parse(.agentNeedsUser, .claudeCode, Payloads.claudePermission)?.sessionID == "abc123")
        #expect(parse(.subagentFinished, .claudeCode, Payloads.claudeSubagentInternal) == nil)
        #expect(parse(.subagentFinished, .claudeCode, Payloads.claudeSubagent) != nil)
        #expect(parse(.sessionEnded, .claudeCode, Payloads.claudeSessionEnd)?.kind == .sessionEnded)
    }

    @Test func kindAlwaysComesFromTheArgument() {
        // A Stop payload sent to an agentStarted hook stays agentStarted.
        #expect(parse(.agentStarted, .claudeCode, Payloads.claudeStop)?.kind == .agentStarted)
    }

    @Test func cursorNativeAndRelayed() throws {
        let prompt = try #require(parse(.agentStarted, .cursor, Payloads.cursorPrompt))
        #expect(prompt.source == .cursor && prompt.via == nil)
        #expect(prompt.sessionID == "conv-1")
        #expect(prompt.cwd == "/Users/me/code/web")
        #expect(prompt.title == "fix the login redirect")
        #expect(parse(.agentFinished, .cursor, Payloads.cursorStop)?.detail == "aborted")
        let start = try #require(parse(.sessionStarted, .cursor, Payloads.cursorSessionStart, env: ["CURSOR_PROJECT_DIR": "/Users/me/code/web"]))
        #expect(start.sessionID == "sess-9")
        #expect(start.cwd == "/Users/me/code/web")

        // Claude Code's hook running inside Cursor: counted once, as Cursor, marked as relayed.
        let relayed = try #require(parse(.agentStarted, .claudeCode, Payloads.cursorRelayedPrompt, env: ["CLAUDE_PROJECT_DIR": "/Users/me/code/web"]))
        #expect(relayed.source == .cursor)
        #expect(relayed.via == AgentEvent.viaClaudeCodeHooks)
        #expect(relayed.sessionID == "conv-7")
        #expect(relayed.cwd == "/Users/me/code/web")
    }

    @Test func cursorEnvironmentWithoutPayload() {
        let relayed = parse(.agentStarted, .claudeCode, nil, env: ["CURSOR_VERSION": "2.1.0"], mode: .none)
        #expect(relayed?.source == .cursor && relayed?.via == AgentEvent.viaClaudeCodeHooks)
        // Claude Code started in Cursor's terminal inherits CURSOR_VERSION, but CLAUDECODE says who runs the hook.
        let claude = parse(.agentStarted, .claudeCode, nil, env: ["CURSOR_VERSION": "2.1.0", "CLAUDECODE": "1"], mode: .none)
        #expect(claude?.source == .claudeCode && claude?.via == nil)
        // A real Claude Code payload is never Cursor's, whatever the environment.
        #expect(parse(.agentStarted, .claudeCode, Payloads.claudePrompt, env: ["CURSOR_VERSION": "2.1.0"])?.source == .claudeCode)
        // Shell and test events keep their source.
        #expect(parse(.commandStarted, .shell, nil, env: ["CURSOR_VERSION": "2"], mode: .none)?.source == .shell)
        #expect(parse(.test, .claudeCode, nil, env: ["CURSOR_VERSION": "2"], mode: .none)?.source == .claudeCode)
    }

    @Test func codexHooksAndNotify() throws {
        let prompt = try #require(parse(.agentStarted, .codex, Payloads.codexPrompt))
        #expect(prompt.sessionID == "thr_123" && prompt.cwd == "/workspace" && prompt.title == "refactor the parser")
        #expect(parse(.agentFinished, .codex, Payloads.codexInterrupt)?.detail == "interrupted")
        #expect(parse(.agentFinished, .codex, Payloads.codexInterrupt, flags: { var r = $0; r.detail = "interrupted"; return r })?.detail == "interrupted")
        #expect(parse(.sessionEnded, .codex, Payloads.codexSessionEnd)?.sessionID == "thr_123")

        let notify = try #require(parse(.agentFinished, .codex, Payloads.codexNotify, mode: .argvJSON))
        #expect(notify.sessionID == "thr_456")
        #expect(notify.cwd == "/workspace/api")
        #expect(notify.title == "Rename the handler")
        #expect(parse(.agentFinished, .codex, Payloads.codexNotifyOther, mode: .argvJSON) == nil)
    }

    @Test func copilot() throws {
        let prompt = try #require(parse(.agentStarted, .copilot, Payloads.copilotPrompt))
        #expect(prompt.sessionID == "cp-1" && prompt.cwd == "/Users/me/code/cli" && prompt.title == "explain this error")
        #expect(parse(.agentNeedsUser, .copilot, Payloads.copilotNotification)?.detail == "permission_prompt")
        #expect(parse(.agentNeedsUser, .copilot, Payloads.copilotIdle) == nil)
        #expect(parse(.agentFinished, .copilot, Payloads.copilotStop)?.sessionID == "cp-1")
    }

    @Test func gemini() throws {
        let start = try #require(parse(.agentStarted, .gemini, Payloads.geminiBeforeAgent))
        #expect(start.sessionID == "g-1" && start.title == "plot the loss")
        #expect(parse(.agentFinished, .gemini, Payloads.geminiNoSession)?.sessionID == "gemini:/Users/me/code/ml")
        #expect(parse(.agentNeedsUser, .gemini, Payloads.geminiNotification)?.detail == "ToolPermission")
    }

    @Test func flagsWinOverThePayload() {
        let event = parse(.agentStarted, .claudeCode, Payloads.claudePrompt) { request in
            var r = request
            r.sessionID = "flag-session"
            r.cwd = "/flag/dir"
            r.title = "flag title"
            r.detail = "flag detail"
            return r
        }
        #expect(event?.sessionID == "flag-session")
        #expect(event?.cwd == "/flag/dir")
        #expect(event?.title == "flag title")
        #expect(event?.detail == "flag detail")
    }

    @Test(arguments: ["", "not json", "[1,2]", "\"string\"", "{\"session_id\": 5}", "{\"cwd\": \"relative/path\"}", "{", String(repeating: "x", count: 10_000)])
    func malformedPayloadsFallBackToFlags(_ payload: String) {
        let event = parse(.agentFinished, .claudeCode, payload) { var r = $0; r.sessionID = "s"; return r }
        #expect(event?.kind == .agentFinished)
        #expect(event?.sessionID == "s")
        #expect(event?.cwd == nil)
    }

    @Test func shellTitlesAreCommandNamesOnly() {
        func title(_ raw: String) -> String? {
            parse(.commandStarted, .shell, nil, mode: .none) { var r = $0; r.title = raw; r.sessionID = "123"; return r }?.title
        }
        #expect(title("swift") == "swift")
        #expect(title("swift test --filter Wire") == "swift")
        #expect(title("API_KEY=sk-123 make") == "make")
        #expect(title("\"./my script.sh\" --flag") == "./my script.sh")
        #expect(title("ghp_FAKE_token_for_tests_only") == nil)  // not a real token (see secretsAreMaskedInTitles)
        #expect(title("-rf") == nil)
    }

    @Test func promptSnippetsCanBeTurnedOff() {
        let request = EmitRequest(kind: .agentStarted, source: .claudeCode, payloadMode: .stdinJSON, payload: Data(Payloads.claudePrompt.utf8))
        #expect(HookPayloadParser.event(from: request, environment: [:], now: now, storePromptSnippets: false)?.title == nil)
        #expect(HookPayloadParser.event(from: request, environment: [:], now: now, storePromptSnippets: true)?.title != nil)
    }

    @Test func cleanTitle() {
        #expect(HookPayloadParser.cleanTitle("  fix the bug\nmore detail") == "fix the bug")
        #expect(HookPayloadParser.cleanTitle("<pasted_content id=\"1\">\nsecret stuff\n</pasted_content>\nsummarise this") == "summarise this")
        #expect(HookPayloadParser.cleanTitle("review <pasted_content id=2>token abc</pasted_content> please") == "review please")
        #expect(HookPayloadParser.cleanTitle("<pasted_content id=3>\nonly paste\n</pasted_content>") == "")
        let long = String(repeating: "word ", count: 40)
        let cleaned = HookPayloadParser.cleanTitle(long)
        #expect(cleaned.count <= 81)
        #expect(cleaned.hasSuffix("…"))
        #expect(HookPayloadParser.cleanTitle("/deploy staging") == "/deploy staging")
        #expect(HookPayloadParser.cleanTitle("tab\there") == "tab here")
    }

    // Every key and token below is made up: shaped like the real thing so the masking can be
    // tested, but marked FAKE (or AWS's documented example key ID) so no one mistakes it for a
    // leaked secret, and so secret scanners can tell.
    @Test func secretsAreMaskedInTitles() {
        #expect(HookPayloadParser.cleanTitle("use key sk-proj-FAKE-key-for-tests to call") == "use key ••• to call")
        #expect(HookPayloadParser.cleanTitle("set API_KEY=hunter2 and PASSWORD:swordfish") == "set API_KEY=••• and PASSWORD:•••")
        #expect(HookPayloadParser.cleanTitle("clone https://bob:pa55@github.com/x/y") == "clone https://•••@github.com/x/y")
        #expect(HookPayloadParser.cleanTitle("token ghp_FAKE_token_for_tests_only leaked") == "token ••• leaked")
        #expect(HookPayloadParser.cleanTitle("AKIAIOSFODNN7EXAMPLE is the id") == "••• is the id")
        #expect(HookPayloadParser.cleanTitle("hash 9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddcc") == "hash •••")
        // Ordinary words survive.
        #expect(HookPayloadParser.cleanTitle("rename authorDisplayName to authorName: done") == "rename authorDisplayName to authorName: done")
    }
}
