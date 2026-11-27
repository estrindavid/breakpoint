import Foundation

// One type per tool in SPEC §5.5. Hook events and fields: SPEC §5.6. The command strings come from
// `HookCommand` and must stay byte-for-byte stable (Codex trust is keyed to them).

private typealias Entry = JSONSettingsMerger.HookEntry

private func folderExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

// MARK: - Claude Code

/// Claude Code: merge into `hooks` of `~/.claude/settings.json` (strict JSON); all hooks async
/// except `SessionEnd` (sync, timeout 2). Never project `.claude/` files (Copilot CLI reads those).
public struct ClaudeCodeIntegration: Integration {
    public let environment: IntegrationEnvironment
    public init(environment: IntegrationEnvironment) { self.environment = environment }
    public var id: IntegrationID { .claudeCode }
    public var toolFolder: URL { environment.home.appendingPathComponent(".claude", isDirectory: true) }
    public var configFile: URL { toolFolder.appendingPathComponent("settings.json") }
    public func detect() -> Bool { folderExists(toolFolder) }

    static let notificationMatcher = "permission_prompt|elicitation_dialog|elicitation_url_dialog|idle_prompt"

    static func entries(_ paths: BreakpointPaths) -> [JSONSettingsMerger.HookEntry] {
        let source = AgentSource.claudeCode
        func entry(_ event: String, _ kind: AgentEventKind, matcher: String? = nil, extra: [String] = [], sync: Bool = false) -> Entry {
            let command = HookCommand.shell(kind, source: source, extra: extra, paths: paths)
            return Entry(event: event, matcher: matcher,
                         handler: HookHandler.claudeStyle(command, async: !sync, timeout: sync ? 2 : nil))
        }
        return [
            entry("SessionStart", .sessionStarted),
            entry("UserPromptSubmit", .agentStarted),
            entry("PostToolUse", .agentActivity),
            entry("PermissionRequest", .agentNeedsUser, matcher: "*"),
            entry("PreToolUse", .agentNeedsUser, matcher: "AskUserQuestion"),
            entry("Notification", .agentNeedsUser, matcher: notificationMatcher),
            entry("Stop", .agentFinished),
            entry("StopFailure", .agentFinished, extra: ["--detail", "error"]),
            entry("SubagentStop", .subagentFinished),
            entry("SessionEnd", .sessionEnded, sync: true),
        ]
    }

    /// The research draft's StopFailure command (no `--detail`), treated as an older install.
    static func legacyCommands(_ paths: BreakpointPaths) -> Set<String> {
        [HookCommand.shell(.agentFinished, source: .claudeCode, paths: paths)]
    }

    var installer: JSONHookInstaller {
        JSONHookInstaller(id: id, environment: environment, file: configFile, entries: Self.entries(environment.paths),
                          format: .init(layout: .grouped), legacyCommands: Self.legacyCommands(environment.paths))
    }

    public static let installNotes = [
        "Claude Code runs these hooks in folders you have trusted. Open sessions pick them up on their own.",
    ]

    public func status() -> IntegrationInstallState { installer.status(found: detect()) }
    public func install() throws -> InstallReport { try installer.install(found: detect(), notes: Self.installNotes) }
    public func uninstall() throws -> InstallReport { try installer.uninstall() }
}

// MARK: - Cursor

/// Cursor: merge into `~/.cursor/hooks.json` (`"version": 1`); sync, timeout 2; never permission
/// hooks (`preToolUse`, `beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile`,
/// `beforeTabFileRead`, `subagentStart`). No heartbeat.
public struct CursorIntegration: Integration {
    public let environment: IntegrationEnvironment
    public init(environment: IntegrationEnvironment) { self.environment = environment }
    public var id: IntegrationID { .cursor }
    public var toolFolder: URL { environment.home.appendingPathComponent(".cursor", isDirectory: true) }
    public var configFile: URL { toolFolder.appendingPathComponent("hooks.json") }
    public func detect() -> Bool { folderExists(toolFolder) }

    /// Events Breakpoint must never register on (they block on bad output).
    public static let forbiddenEvents: Set<String> = [
        "preToolUse", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "beforeTabFileRead", "subagentStart",
    ]

    static func entries(_ paths: BreakpointPaths) -> [JSONSettingsMerger.HookEntry] {
        func entry(_ event: String, _ kind: AgentEventKind) -> Entry {
            Entry(event: event, handler: .object([
                JMember("command", .string(HookCommand.shell(kind, source: .cursor, paths: paths))),
                JMember("timeout", .int(2)),
            ]))
        }
        return [
            entry("sessionStart", .sessionStarted),
            entry("beforeSubmitPrompt", .agentStarted),
            entry("stop", .agentFinished),
            entry("subagentStop", .subagentFinished),
            entry("sessionEnd", .sessionEnded),
        ]
    }

    var installer: JSONHookInstaller {
        var installer = JSONHookInstaller(id: id, environment: environment, file: configFile, entries: Self.entries(environment.paths),
                                          format: .init(layout: .flat, skeleton: [JMember("version", .int(1))]),
                                          legacyCommands: [])
        let file = configFile
        installer.validate = { doc in
            if let version = doc.node(at: ["version"]), !version.value.semanticallyEquals(.int(1)) {
                throw IntegrationError.unparseableFile(file, reason: "it has a \"version\" other than 1")
            }
        }
        return installer
    }

    public static let installNotes = ["If Cursor does not pick the hooks up, restart it."]

    public func status() -> IntegrationInstallState { installer.status(found: detect()) }
    public func install() throws -> InstallReport { try installer.install(found: detect(), notes: Self.installNotes) }
    public func uninstall() throws -> InstallReport { try installer.uninstall() }
}

// MARK: - Codex CLI

/// Codex CLI hooks: merge into `$CODEX_HOME/hooks.json`. Async except `Interrupt` (sync, timeout 1)
/// and `SessionEnd` (sync, timeout 2). After install, the report's notes tell the user to trust the
/// entries in `/hooks`. Never installed together with `codex-notify`.
public struct CodexIntegration: Integration {
    public let environment: IntegrationEnvironment
    public init(environment: IntegrationEnvironment) { self.environment = environment }
    public var id: IntegrationID { .codex }
    public var toolFolder: URL { environment.codexHome }
    public var configFile: URL { toolFolder.appendingPathComponent("hooks.json") }
    public func detect() -> Bool { folderExists(toolFolder) }

    static func entries(_ paths: BreakpointPaths) -> [JSONSettingsMerger.HookEntry] {
        func entry(_ event: String, _ kind: AgentEventKind, extra: [String] = [], syncTimeout: Int? = nil) -> Entry {
            let command = HookCommand.shell(kind, source: .codex, extra: extra, paths: paths)
            return Entry(event: event, handler: HookHandler.claudeStyle(command, async: syncTimeout == nil, timeout: syncTimeout))
        }
        return [
            entry("SessionStart", .sessionStarted),
            entry("UserPromptSubmit", .agentStarted),
            entry("PermissionRequest", .agentNeedsUser),
            entry("Stop", .agentFinished),
            entry("Interrupt", .agentFinished, extra: ["--detail", "interrupted"], syncTimeout: 1),
            entry("SubagentStop", .subagentFinished),
            entry("SessionEnd", .sessionEnded, syncTimeout: 2),
        ]
    }

    /// The research draft's Interrupt command (no `--detail`), treated as an older install.
    static func legacyCommands(_ paths: BreakpointPaths) -> Set<String> {
        [HookCommand.shell(.agentFinished, source: .codex, paths: paths)]
    }

    var installer: JSONHookInstaller {
        JSONHookInstaller(id: id, environment: environment, file: configFile, entries: Self.entries(environment.paths),
                          format: .init(layout: .grouped), legacyCommands: Self.legacyCommands(environment.paths))
    }

    /// Codex skips hooks until the user trusts them (SPEC §5.5).
    public static let trustNote = "Open /hooks in Codex and trust the Breakpoint entries. Codex skips them until you do."

    public func status() -> IntegrationInstallState { installer.status(found: detect()) }

    public func install() throws -> InstallReport {
        if CodexNotifyIntegration(environment: environment).status().hasBreakpointEntries {
            throw IntegrationError.conflictsWith(.codexNotify)
        }
        let report = try installer.install(found: detect(), notes: [])
        // The trust step applies whenever the definitions were (re)written; repeat it if unsure.
        return InstallReport(changedFiles: report.changedFiles, backups: report.backups, notes: [Self.trustNote])
    }

    public func uninstall() throws -> InstallReport { try installer.uninstall() }
}

// MARK: - Gemini CLI

/// Gemini CLI: merge into `hooks` of `~/.gemini/settings.json` (JSON with comments); sync,
/// `timeout` 2000 ms. Needs Gemini's hooks on (older versions may have them off; SPEC §5.7).
public struct GeminiIntegration: Integration {
    public let environment: IntegrationEnvironment
    public init(environment: IntegrationEnvironment) { self.environment = environment }
    public var id: IntegrationID { .gemini }
    public var toolFolder: URL { environment.home.appendingPathComponent(".gemini", isDirectory: true) }
    public var configFile: URL { toolFolder.appendingPathComponent("settings.json") }
    public func detect() -> Bool { folderExists(toolFolder) }

    static func entries(_ paths: BreakpointPaths) -> [JSONSettingsMerger.HookEntry] {
        func entry(_ event: String, _ kind: AgentEventKind) -> Entry {
            Entry(event: event, matcher: "*", handler: .object([
                JMember("name", .string("breakpoint")),
                JMember("type", .string("command")),
                JMember("command", .string(HookCommand.shell(kind, source: .gemini, paths: paths))),
                JMember("timeout", .int(2000)),
            ]))
        }
        return [
            entry("BeforeAgent", .agentStarted),
            entry("AfterAgent", .agentFinished),
            entry("Notification", .agentNeedsUser),
        ]
    }

    var installer: JSONHookInstaller {
        JSONHookInstaller(id: id, environment: environment, file: configFile, entries: Self.entries(environment.paths),
                          format: .init(layout: .grouped, allowsComments: true), legacyCommands: [])
    }

    public static let installNotes = ["Gemini CLI runs hooks only in versions that have them turned on."]

    public func status() -> IntegrationInstallState { installer.status(found: detect()) }
    public func install() throws -> InstallReport { try installer.install(found: detect(), notes: Self.installNotes) }
    public func uninstall() throws -> InstallReport { try installer.uninstall() }
}

// MARK: - Copilot CLI

/// Copilot CLI: an owned file `~/.copilot/hooks/breakpoint.json`; sync, `timeoutSec` 2, fails open.
/// Never `preToolUse` (it fails closed).
public struct CopilotIntegration: Integration {
    public let environment: IntegrationEnvironment
    public init(environment: IntegrationEnvironment) { self.environment = environment }
    public var id: IntegrationID { .copilot }
    public var toolFolder: URL { environment.home.appendingPathComponent(".copilot", isDirectory: true) }
    public var hooksFolder: URL { toolFolder.appendingPathComponent("hooks", isDirectory: true) }
    public var configFile: URL { hooksFolder.appendingPathComponent("breakpoint.json") }
    public func detect() -> Bool { folderExists(toolFolder) }

    static let notificationMatcher = "permission_prompt|elicitation_dialog"

    /// On Windows Copilot CLI runs the `powershell` field (PowerShell 7); elsewhere `bash`.
    static func document(_ paths: BreakpointPaths) -> JValue {
        func handler(_ kind: AgentEventKind, matcher: String? = nil) -> JValue {
            let command = HookCommand.shell(kind, source: .copilot, paths: paths)
            var members = [JMember("type", .string("command")), JMember("bash", .string(command))]
            #if os(Windows)
            members.append(JMember("powershell", .string(command)))
            #endif
            members.append(JMember("timeoutSec", .int(2)))
            if let matcher { members.append(JMember("matcher", .string(matcher))) }
            return .object(members)
        }
        return .object([
            JMember("version", .int(1)),
            JMember("hooks", .object([
                JMember("sessionStart", .array([handler(.sessionStarted)])),
                JMember("userPromptSubmitted", .array([handler(.agentStarted)])),
                JMember("notification", .array([handler(.agentNeedsUser, matcher: notificationMatcher)])),
                JMember("agentStop", .array([handler(.agentFinished)])),
                JMember("sessionEnd", .array([handler(.sessionEnded)])),
            ])),
        ])
    }

    static func fileText(_ paths: BreakpointPaths) -> String {
        JSONRender.render(document(paths), indent: "", unit: "  ", newline: "\n", compact: false) + "\n"
    }

    private var marker: HookMarker { HookMarker(source: .copilot) }
    private var file: ConfigFile { ConfigFile(url: configFile, tool: id, environment: environment) }

    private enum Contents { case absent, ours(JValue), foreign }

    private func contents() throws -> Contents {
        guard let text = try file.read() else { return .absent }
        let value: JValue
        do {
            value = try JValue.parse(text)
        } catch let error as JSONSyntaxError {
            throw IntegrationError.unparseableFile(configFile, reason: error.reason)
        }
        return text.contains(HookMarker.binaryFragment) && marked(value) ? .ours(value) : .foreign
    }

    private func marked(_ value: JValue) -> Bool {
        guard case .object(let events)? = value["hooks"] else { return false }
        return events.contains { member in
            guard case .array(let handlers) = member.value else { return false }
            return handlers.contains { ($0["bash"]?.stringValue ?? $0["command"]?.stringValue).map(marker.matches) ?? false }
        }
    }

    public func status() -> IntegrationInstallState {
        guard detect() else { return .notFound }
        do {
            switch try contents() {
            case .absent, .foreign: return .notInstalled
            case .ours(let value):
                if value.semanticallyEquals(Self.document(environment.paths)) { return .installed }
                let known = Set(Self.document(environment.paths).commands)
                return value.commands.allSatisfy(known.contains) ? .outdated : .modified
            }
        } catch let error as IntegrationError {
            return .unreadable(reason: error.statusSentence)
        } catch {
            return .unreadable(reason: "\(configFile.lastPathComponent) could not be read.")
        }
    }

    public func install() throws -> InstallReport {
        guard detect() else { throw IntegrationError.toolNotFound(id) }
        if case .foreign = try contents() {
            throw IntegrationError.io("\(PathDisplay.abbreviatingHome(configFile.path, home: environment.home.path)) belongs to something else, so Breakpoint left it alone.")
        }
        try environment.ensureCLICopy()
        try CreatedDirectory.ensure(hooksFolder, environment: environment)
        let change = try file.update { text in
            if let text, let value = try? JValue.parse(text), value.semanticallyEquals(Self.document(environment.paths)) { return text }
            return Self.fileText(environment.paths)
        }
        return InstallReport(changedFiles: change.map { [$0.file] } ?? [], backups: change?.backup.map { [$0] } ?? [])
    }

    public func uninstall() throws -> InstallReport {
        guard case .ours = try contents() else { return InstallReport() }
        let change = try file.update { _ in nil }
        CreatedDirectory.removeIfEmpty(hooksFolder, environment: environment)
        return InstallReport(changedFiles: change.map { [$0.file] } ?? [], backups: change?.backup.map { [$0] } ?? [])
    }
}

extension JValue {
    /// Every `command` / `bash` string in the value.
    var commands: [String] {
        switch self {
        case .object(let members):
            return members.flatMap { member -> [String] in
                if member.key == "command" || member.key == "bash" || member.key == "powershell",
                   let s = member.value.stringValue { return [s] }
                return member.value.commands
            }
        case .array(let items): return items.flatMap(\.commands)
        default: return []
        }
    }
}
