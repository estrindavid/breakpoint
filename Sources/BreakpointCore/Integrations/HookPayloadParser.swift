import Foundation

/// A parsed `breakpoint emit` invocation (SPEC §5.3, §5.8). Built by the CLI's argument parser,
/// turned into an `AgentEvent` by `HookPayloadParser`.
public struct EmitRequest: Equatable, Sendable {
    public enum PayloadMode: Equatable, Sendable {
        case none
        /// `--stdin-json`: the payload is stdin, read to EOF (cap 1 MB, 250 ms total).
        case stdinJSON
        /// `--argv-json`: the payload is the last argument (Codex `notify`).
        case argvJSON
    }

    /// From the positional argument; never from the payload (SPEC §5.3 rule 6).
    public var kind: AgentEventKind
    /// `--source`.
    public var source: AgentSource
    public var sessionID: String?
    public var cwd: String?
    public var title: String?
    public var detail: String?
    public var durationMS: Int?
    public var exitCode: Int?
    public var payloadMode: PayloadMode
    /// The raw payload bytes (stdin, or the last argument), if any.
    public var payload: Data?

    public init(kind: AgentEventKind, source: AgentSource, sessionID: String? = nil, cwd: String? = nil,
                title: String? = nil, detail: String? = nil, durationMS: Int? = nil, exitCode: Int? = nil,
                payloadMode: PayloadMode = .none, payload: Data? = nil) {
        self.kind = kind
        self.source = source
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.detail = detail
        self.durationMS = durationMS
        self.exitCode = exitCode
        self.payloadMode = payloadMode
        self.payload = payload
    }

    /// Stdin cap for `--stdin-json`.
    public static let maxPayloadBytes = 1_000_000
    /// Total time allowed for reading stdin.
    public static let stdinTimeout: TimeInterval = 0.25
}

/// Turns hook payloads from each tool into `AgentEvent`s (SPEC §5.4, §5.6). Pure.
///
/// Contract:
/// - The kind always comes from `request.kind`.
/// - Explicit flags (`--session`, `--cwd`, `--title`, `--detail`, …) win over payload fields;
///   payload fields fill the gaps per the SPEC §5.6 field table for the (detected) source:
///   - Claude Code: session `session_id`; folder `$CLAUDE_PROJECT_DIR`, else `cwd`; title `prompt`;
///     detail `notification_type`, or `error` for `StopFailure`, or `background` for a `Stop` whose
///     `background_tasks` still lists work in flight; reason `error` (`StopFailure`); message
///     `last_assistant_message` (`Stop` only: on `StopFailure` it is the raw API error); tool and
///     message from `tool_name` / `tool_input` (`PermissionRequest`, `PreToolUse`, `PostToolUse`;
///     tool only on `agentActivity`); tool `question` for an `elicitation_*` notification.
///   - Cursor: session `conversation_id`, else `session_id`; folder `workspace_roots[0]`, else
///     `$CURSOR_PROJECT_DIR`, else `cwd`; title `prompt`; detail `status` on `agentFinished`.
///   - Codex: session `session_id`, else `thread-id` (notify); folder `cwd`; title `prompt`, else
///     `input-messages[0]` (notify); detail `interrupted` for `Interrupt`; message
///     `last_assistant_message` (`Stop`), else `last-assistant-message` (notify); tool and message
///     from `tool_name` / `tool_input` (`PermissionRequest`).
///   - Copilot: session `sessionId`, else `session_id`; folder `cwd`; title `prompt`; detail the
///     notification type.
///   - Gemini: session `session_id`, else `gemini:<folder>`; folder `cwd`; title `prompt`; detail
///     `notification_type`.
///   - Any other source: `session_id` / `sessionId` / `conversation_id`, `cwd`, `prompt`.
///   - Shell: flags only; the title is reduced to a plain command name.
/// - Host detection: a payload with `cursor_version` is Cursor's. With no JSON payload, the
///   environment's `CURSOR_VERSION` decides, unless `CLAUDECODE=1` is also set (a Claude Code
///   session started in Cursor's terminal inherits `CURSOR_VERSION`). A Cursor event sent with
///   another `--source` gets source `cursor` and `via` `"claude-code-hooks"` (never for shell
///   events or `test` events, which name their row explicitly).
/// - Dropped (`nil`): Claude Code `SubagentStop` with an empty `agent_type`; a Codex notify payload
///   whose `type` is not `agent-turn-complete`; `agentNeedsUser` whose notification type is not one
///   Breakpoint registers for (in case a tool ignores the matcher).
/// - Titles are cleaned with `cleanTitle`, secrets in them are masked, and they are left out
///   entirely when `storePromptSnippets` is false (shell command names are kept).
/// - Messages (the agent's last message, or what a waiting agent asks for) are reduced to one
///   plain line (`cleanMessage`, `RequestSubject`), masked like titles, and left out entirely when
///   `storePromptSnippets` is false. Tool kinds and failure reasons are not sensitive and are kept.
/// - `cwd` values must be absolute paths (`file://` URLs are converted); others are ignored.
/// - Malformed or missing payloads never fail: the event is built from flags alone.
public enum HookPayloadParser {
    public static func event(from request: EmitRequest, environment: [String: String], now: Date) -> AgentEvent? {
        event(from: request, environment: environment, now: now, storePromptSnippets: true)
    }

    public static func event(from request: EmitRequest, environment: [String: String], now: Date,
                             storePromptSnippets: Bool) -> AgentEvent? {
        let payload = request.payload.flatMap(Self.object)
        let p = Payload(payload ?? [:])

        var source = request.source
        var via: String?
        let isCursorHost: Bool
        if payload != nil {
            isCursorHost = p.string("cursor_version") != nil
        } else {
            isCursorHost = !(environment["CURSOR_VERSION"] ?? "").isEmpty && environment["CLAUDECODE"] != "1"
        }
        if isCursorHost, source != .cursor, source != .shell, request.kind != .test {
            via = AgentEvent.viaClaudeCodeHooks
            source = .cursor
        }

        var sessionID: String?
        var cwd: String?
        var title: String?
        var detail: String?
        var message: String?
        var tool: AgentToolKind?
        var reason: String?
        let hookEvent = p.string("hook_event_name")

        switch source {
        case .claudeCode:
            if request.kind == .subagentFinished, p.has("agent_type"), (p.string("agent_type") ?? "").isEmpty { return nil }
            sessionID = p.string("session_id")
            cwd = environment["CLAUDE_PROJECT_DIR"].flatMap(absolutePath) ?? p.path("cwd")
            title = p.string("prompt")
            if hookEvent == "StopFailure" { detail = "error" } else { detail = p.string("notification_type") }
            if request.kind == .agentNeedsUser, let type = p.string("notification_type"),
               !["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "idle_prompt"].contains(type) {
                return nil
            }
            switch request.kind {
            case .agentFinished:
                if hookEvent == "StopFailure" || request.detail == "error" {
                    reason = p.string("error").flatMap(Self.cleanReason)
                } else {
                    message = p.string("last_assistant_message").flatMap(Self.cleanMessage)
                    if p.backgroundTasksInFlight > 0 { detail = Self.backgroundDetail }
                }
            case .agentNeedsUser:
                if let name = p.string("tool_name") {
                    tool = AgentToolKind(toolName: name)
                    message = RequestSubject.subject(tool: tool ?? .other, input: p.dict["tool_input"])
                } else if let type = p.string("notification_type"), type.hasPrefix("elicitation") {
                    tool = .question
                }
            case .agentActivity:
                tool = p.string("tool_name").map(AgentToolKind.init(toolName:))
            default:
                break
            }
        case .cursor:
            sessionID = p.string("conversation_id") ?? p.string("session_id")
            cwd = p.firstPath("workspace_roots") ?? environment["CURSOR_PROJECT_DIR"].flatMap(absolutePath) ?? p.path("cwd")
            title = p.string("prompt")
            if request.kind == .agentFinished { detail = p.string("status") }
        case .codex:
            if request.payloadMode == .argvJSON, let type = p.string("type"), type != "agent-turn-complete" { return nil }
            sessionID = p.string("session_id") ?? p.string("thread-id")
            cwd = p.path("cwd")
            title = p.string("prompt") ?? p.firstMessage("input-messages")
            if hookEvent == "Interrupt" { detail = "interrupted" }
            switch request.kind {
            case .agentFinished where hookEvent != "Interrupt":
                message = (p.string("last_assistant_message") ?? p.string("last-assistant-message")).flatMap(Self.cleanMessage)
            case .agentNeedsUser:
                if let name = p.string("tool_name") {
                    tool = AgentToolKind(toolName: name)
                    message = RequestSubject.subject(tool: tool ?? .other, input: p.dict["tool_input"])
                }
            default:
                break
            }
        case .copilot:
            sessionID = p.string("sessionId") ?? p.string("session_id")
            cwd = p.path("cwd")
            title = p.string("prompt")
            let type = p.string("notification_type") ?? p.string("notificationType")
            detail = type
            if request.kind == .agentNeedsUser, let type, !["permission_prompt", "elicitation_dialog"].contains(type) { return nil }
        case .gemini:
            cwd = p.path("cwd")
            sessionID = p.string("session_id")
            title = p.string("prompt")
            detail = p.string("notification_type")
            if request.kind == .agentNeedsUser, let type = detail, type != "ToolPermission" { return nil }
        case .shell:
            break
        default:
            sessionID = p.string("session_id") ?? p.string("sessionId") ?? p.string("conversation_id")
            cwd = p.path("cwd")
            title = p.string("prompt")
        }

        // Explicit flags win.
        sessionID = nonEmpty(request.sessionID) ?? sessionID
        cwd = request.cwd.flatMap(absolutePath) ?? cwd
        title = nonEmpty(request.title) ?? title
        detail = nonEmpty(request.detail) ?? detail
        if source == .gemini, sessionID == nil, let folder = cwd { sessionID = "gemini:\(folder)" }

        if request.kind.isCommandEvent || source == .shell {
            title = title.flatMap(TitleSanitizer.commandName)
        } else if storePromptSnippets {
            title = title.map(cleanTitle).flatMap { $0.isEmpty ? nil : $0 }
        } else {
            title = nil
        }
        if !storePromptSnippets || request.kind.isCommandEvent || source == .shell { message = nil }

        return AgentEvent(
            kind: request.kind,
            source: source,
            sessionID: sessionID.map { String($0.prefix(256)) },
            cwd: cwd,
            title: title,
            detail: detail.map { String($0.prefix(64)) },
            via: via,
            timestamp: now,
            durationMS: request.durationMS,
            exitCode: request.exitCode,
            message: message,
            tool: tool,
            reason: reason)
    }

    /// `detail` of an `agentFinished` sent while background work is still running (a Claude Code
    /// `Stop` with `background_tasks` in flight): the session stays working (SPEC §2.6).
    public static let backgroundDetail = "background"
    /// Longest kept message (the card shows one line; this leaves room for a wide card).
    public static let messageLimit = 120

    /// The agent's last message as one plain line (SPEC §3.5): the first line that says something,
    /// with Markdown markers removed (quotes, list bullets, emphasis, inline code, links) and
    /// headings, code blocks, rules and table rows skipped (a heading is used only when nothing
    /// else is left). A lead-in ending in ":" ("Here's what changed:")
    /// takes the next line with it. Secrets are masked; at most `messageLimit` characters (with "…").
    /// `nil` when nothing is left.
    public static func cleanMessage(_ raw: String) -> String? {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var picked: [String] = []
        var firstHeading: String?
        var inFence = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            guard let plain = plainMarkdownLine(line) else { continue }
            // A heading ("## Summary") says less than the line under it; it is kept only as a last resort.
            if line.hasPrefix("#") {
                if firstHeading == nil { firstHeading = plain }
                continue
            }
            picked.append(plain)
            if picked.count == 1, plain.hasSuffix(":") { continue }
            break
        }
        if picked.isEmpty, let firstHeading { picked = [firstHeading] }
        guard !picked.isEmpty else { return nil }
        let joined = picked.joined(separator: " ")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let collapsed = String(String.UnicodeScalarView(joined))
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        return TextFormat.truncated(TitleSanitizer.maskSecrets(collapsed), limit: messageLimit)
    }

    /// One Markdown line as plain text; `nil` for lines that carry no words (rules, table rows,
    /// HTML tags, empty after cleaning).
    static func plainMarkdownLine(_ line: String) -> String? {
        if line.hasPrefix("|") || line.hasPrefix("<") { return nil }
        if line.range(of: #"^([-*_=]\s*){3,}$"#, options: .regularExpression) != nil { return nil }
        var text = line
        let rules: [(String, String)] = [
            (#"^#{1,6}\s+"#, ""),                 // headings
            (#"^(>\s?)+"#, ""),                   // quotes
            (#"^([-*+•]|\d{1,3}[.)])\s+"#, ""),    // list items
            (#"^\[[ xX]\]\s+"#, ""),               // task boxes
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),     // links and images → their text
            (#"(\*\*|__|~~)"#, ""),                // bold, strike
            (#"`+"#, ""),                          // inline code
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// A failure reason as sent by the tool, reduced to a short identifier (`rate_limit`).
    static func cleanReason(_ raw: String) -> String? {
        let kept = raw.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) && $0.isASCII || CharacterSet.decimalDigits.contains($0) || $0 == "_" }
        let reason = String(String.UnicodeScalarView(kept.prefix(40)))
        return reason.isEmpty ? nil : reason
    }

    /// SPEC §5.3 rule 7: the first line, minus `<pasted_content…>` wrappers, ≤ 80 characters
    /// (with "…" when cut). Pasted blocks are skipped with their contents (pasted text is the most
    /// likely place for a token); secret-looking words are masked. Empty when nothing is left.
    public static func cleanTitle(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // Whole pasted blocks, possibly spanning lines.
        text = text.replacingOccurrences(of: #"<pasted_content[^>]*>[\s\S]*?</pasted_content>"#, with: " ",
                                         options: [.regularExpression, .caseInsensitive])
        // Unbalanced wrapper tags.
        text = text.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        let line = TextFormat.firstLine(text)
            .replacingOccurrences(of: "\t", with: " ")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let collapsed = String(String.UnicodeScalarView(line)).replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        return TextFormat.truncated(TitleSanitizer.maskSecrets(collapsed), limit: 80)
    }

    // MARK: Helpers

    static func object(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    static func absolutePath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { path = url.path }
        guard PathDisplay.isAbsolute(path), !path.contains("\0") else { return nil }
        return path
    }

    private struct Payload {
        let dict: [String: Any]
        init(_ dict: [String: Any]) { self.dict = dict }

        func has(_ key: String) -> Bool { dict[key] != nil }

        func string(_ key: String) -> String? {
            switch dict[key] {
            case let s as String: return s.isEmpty ? nil : s
            case let n as NSNumber where key.lowercased().contains("id"): return n.stringValue
            default: return nil
            }
        }

        func path(_ key: String) -> String? { string(key).flatMap(HookPayloadParser.absolutePath) }

        func firstPath(_ key: String) -> String? {
            (dict[key] as? [Any])?.first.flatMap { $0 as? String }.flatMap(HookPayloadParser.absolutePath)
        }

        /// Claude Code `Stop`: background tasks still in flight (entries whose `status`, if any, is
        /// not a finished one).
        var backgroundTasksInFlight: Int {
            guard let tasks = dict["background_tasks"] as? [Any] else { return 0 }
            let finished: Set<String> = ["completed", "complete", "done", "failed", "killed", "stopped", "cancelled", "canceled"]
            return tasks.filter { task in
                guard let status = (task as? [String: Any])?["status"] as? String else { return true }
                return !finished.contains(status.lowercased())
            }.count
        }

        /// The first message of a list of strings or `{text|content: …}` objects.
        func firstMessage(_ key: String) -> String? {
            guard let first = (dict[key] as? [Any])?.first else { return nil }
            if let s = first as? String { return s }
            if let d = first as? [String: Any] { return (d["text"] as? String) ?? (d["content"] as? String) }
            return nil
        }
    }
}

extension AgentToolKind {
    /// The kind of a tool from its name as the tools send it (`tool_name`). Claude Code names are
    /// from its tool reference; Codex's shell and patch tools are matched by their usual names.
    public init(toolName: String) {
        switch toolName.lowercased() {
        case "bash", "shell", "local_shell", "exec_command", "unified_exec", "container.exec", "run_shell_command":
            self = .command
        case "edit", "write", "multiedit", "notebookedit", "apply_patch", "write_file", "replace":
            self = .edit
        case "webfetch", "web_fetch":
            self = .fetch
        case "askuserquestion":
            self = .question
        case "exitplanmode":
            self = .plan
        default:
            self = .other
        }
    }
}

/// What a waiting agent asks for, from a permission request's `tool_input` (SPEC §3.5): the
/// command line (one line, masked, ≤ 60 characters), the file's name (never its folder), or the
/// web page's host. Sensitive: kept only under "Keep prompt snippets". Missing or unexpected input
/// gives `nil` and the card falls back to the kind alone ("Wants to run a command").
public enum RequestSubject {
    public static let limit = 60

    public static func subject(tool: AgentToolKind, input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }
        switch tool {
        case .command:
            return command(input["command"] ?? input["cmd"])
        case .edit:
            let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String
            return path.flatMap { fileName($0) }
        case .fetch:
            return (input["url"] as? String).flatMap { URL(string: $0)?.host }.flatMap { clean($0) }
        case .question, .plan, .other:
            return nil
        }
    }

    /// A command string, or an argv array (`["bash", "-lc", "npm install"]` → "npm install").
    static func command(_ value: Any?) -> String? {
        if let text = value as? String { return clean(text) }
        if var argv = value as? [String], !argv.isEmpty {
            if argv.count >= 3, ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains(argv[0]),
               argv[1].hasPrefix("-"), argv[1].contains("c") {
                argv = Array(argv[2...])
            }
            return clean(argv.joined(separator: " "))
        }
        return nil
    }

    static func fileName(_ path: String) -> String? {
        clean(PathDisplay.lastComponent(path))
    }

    /// First line, control characters removed, spaces collapsed, secrets masked, ≤ `limit`.
    static func clean(_ raw: String) -> String? {
        let line = TextFormat.firstLine(raw.replacingOccurrences(of: "\r\n", with: "\n"))
            .replacingOccurrences(of: "\t", with: " ")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let collapsed = String(String.UnicodeScalarView(line))
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        return TextFormat.truncated(TitleSanitizer.maskSecrets(collapsed), limit: limit)
    }
}

/// Keeps secrets out of titles: masks credential-looking words in prompt snippets and reduces
/// shell titles to a bare command name.
public enum TitleSanitizer {
    static let mask = "•••"

    /// Words that look like secrets become "•••"; `key=value` pairs with a secret-sounding key keep
    /// the key.
    public static func maskSecrets(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            maskWord(String(word))
        }.joined(separator: " ")
    }

    private static let secretKey = try! NSRegularExpression(
        pattern: #"(pass(word|wd)?|pwd|secret|token|api[_-]?key|apikey|auth|credential|private[_-]?key|access[_-]?key|session[_-]?key)"#,
        options: [.caseInsensitive])
    private static let tokenPrefix = try! NSRegularExpression(
        pattern: #"^["'(<]?(sk-|sk_live_|sk_test_|rk_live_|pk_live_|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|glpat-|xox[abprs]-|AKIA[0-9A-Z]{12,}|ASIA[0-9A-Z]{12,}|AIza[0-9A-Za-z_-]{10,}|ya29\.|eyJ[0-9A-Za-z_-]{8,}\.|-----BEGIN)"#)
    private static let credentialURL = try! NSRegularExpression(pattern: #"^([a-z][a-z0-9+.-]*://)[^/@\s:]+:[^/@\s]+@"#, options: [.caseInsensitive])

    static func maskWord(_ word: String) -> String {
        guard !word.isEmpty else { return word }
        let range = NSRange(word.startIndex..., in: word)
        if tokenPrefix.firstMatch(in: word, range: range) != nil { return mask }
        if let match = credentialURL.firstMatch(in: word, range: range), let scheme = Range(match.range(at: 1), in: word) {
            return String(word[scheme]) + mask + "@" + word[Range(match.range, in: word)!.upperBound...]
        }
        if let separator = word.firstIndex(where: { $0 == "=" || $0 == ":" }) {
            let key = String(word[..<separator])
            let value = word[word.index(after: separator)...]
            if !value.isEmpty, secretKey.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil {
                return key + String(word[separator]) + mask
            }
        }
        if looksRandom(word) { return mask }
        return word
    }

    /// A long run of token characters with letters and digits mixed (API keys, JWTs, hashes).
    static func looksRandom(_ word: String) -> Bool {
        let core = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>,.;:!?"))
        guard core.count >= 32 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-"))
        guard core.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return false }
        let digits = core.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let letters = core.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return digits >= 4 && letters >= 4
    }

    /// The command's name from a shell title: the first word that is not a `VAR=value` assignment
    /// or an option, without quotes; nil if nothing usable is left or it looks like a secret.
    public static func commandName(_ raw: String) -> String? {
        var raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A quoted name ("./my script.sh") is one word.
        if let quote = raw.first, quote == "\"" || quote == "'", let close = raw.dropFirst().firstIndex(of: quote) {
            raw = String(raw[raw.index(after: raw.startIndex)..<close])
            guard !raw.isEmpty, !raw.contains("=") else { return nil }
            let name = String(raw.prefix(64))
            return name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) && maskWord(name) == name ? name : nil
        }
        for word in raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`\\"))
            if trimmed.isEmpty || trimmed.contains("=") || trimmed.hasPrefix("-") { continue }
            let name = String(trimmed.prefix(64))
            guard name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  maskWord(name) == name else { return nil }
            return name
        }
        return nil
    }
}
