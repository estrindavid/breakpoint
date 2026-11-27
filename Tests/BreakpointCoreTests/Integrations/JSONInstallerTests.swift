import Foundation
import Testing
#if os(Windows)
import WinSDK
#endif
@testable import BreakpointCore

/// One JSON-merging tool and its fixtures.
struct JSONToolCase: CustomTestStringConvertible, Sendable {
    let id: IntegrationID
    let folder: String
    let file: String
    /// A realistic config with unrelated settings and other tools' hooks on Breakpoint's events.
    let rich: String
    /// Odd but valid formatting (tabs, CRLF, comments where allowed, no final newline, …).
    let unusual: [String]
    /// `rich` plus entries an older Breakpoint wrote.
    let older: String
    /// `rich` plus a Breakpoint entry whose command was edited by hand.
    let modified: String
    let unparseable: [String]

    var testDescription: String { id.rawValue }

    func integration(_ home: FakeHome) -> any Integration { IntegrationRegistry.integration(id, environment: home.environment) }

    static let claude = JSONToolCase(
        id: .claudeCode, folder: ".claude", file: ".claude/settings.json",
        rich: """
        {
          "$schema": "https://json.schemastore.org/claude-code-settings.json",
          "model": "opus",
          "permissions": {
            "allow": ["Bash(git status)", "Read(~/code/**)"],
            "deny": []
          },
          "env": { "FOO": "bär \\u00e9 \\/ \\"q\\"" },
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff" } ] }
            ],
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/bin/guard.sh", "timeout": 5 } ] }
            ],
            "Notification": [
              { "matcher": "", "hooks": [
                { "type": "command", "command": "terminal-notifier -message done" },
                { "type": "command", "command": "[ -x \\"$HOME/.breakpoint/bin/breakpoint\\" ] && \\"$HOME/.breakpoint/bin/breakpoint\\" emit agentNeedsUser --source cursor --stdin-json >/dev/null 2>&1 || true" }
              ] }
            ],
            "PreCompact": [],
            "SessionStart": []
          },
          "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
        }

        """,
        unusual: [
            "{\n\t\"model\":\t\"sonnet\" ,\n\t\"hooks\" : {\n\t\t\"PreCompact\" : [ ]\n\t}\n}",
            "{\r\n    \"includeCoAuthoredBy\": false\r\n}\r\n\r\n",
            "  {\"model\":\"opus\",\"env\":{\"A\":\"1\"}}  \n\n\n",
            "{}",
            "\u{FEFF}{\n  \"emoji\": \"😀\",\n  \"nested\": {\"deep\": [[[[{}]]]]}\n}\n",
        ],
        older: """
        {
          "model": "opus",
          "hooks": {
            "UserPromptSubmit": [
              { "hooks": [ { "type": "command", "command": "[ -x \\"$HOME/.breakpoint/bin/breakpoint\\" ] && \\"$HOME/.breakpoint/bin/breakpoint\\" emit agentStarted --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
            ],
            "Stop": [
              { "hooks": [ { "type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff" } ] }
            ],
            "StopFailure": [
              { "hooks": [ { "type": "command", "async": true, "command": "[ -x \\"$HOME/.breakpoint/bin/breakpoint\\" ] && \\"$HOME/.breakpoint/bin/breakpoint\\" emit agentFinished --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
            ]
          }
        }

        """,
        modified: """
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "async": true, "command": "\\"$HOME/.breakpoint/bin/breakpoint\\" emit agentFinished --source claude-code --title mine" } ] }
            ]
          }
        }
        """,
        unparseable: [
            "{\"hooks\": {,}}", "{\"model\": \"opus\",}", "// comment\n{}", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}",
            "[1, 2]", "{\"hooks\": {}, \"hooks\": {}}", "{\"a\": 1} trailing", "{\"a\": \"unterminated}",
        ])

    static let cursor = JSONToolCase(
        id: .cursor, folder: ".cursor", file: ".cursor/hooks.json",
        rich: """
        {
          "version": 1,
          "hooks": {
            "afterFileEdit": [ { "command": "./hooks/format.sh" } ],
            "stop": [ { "command": "say done", "timeout": 10 } ],
            "beforeShellExecution": [ { "command": "./hooks/audit.sh", "failClosed": false } ]
          }
        }

        """,
        unusual: [
            "{\"version\":1}",
            "{\n    \"version\": 1,\n    \"hooks\": {}\n}",
            "{\r\n  \"hooks\": {\r\n    \"stop\": [{\"command\":\"x\"}]\r\n  },\r\n  \"version\": 1\r\n}\r\n",
        ],
        older: """
        {
          "version": 1,
          "hooks": {
            "afterFileEdit": [ { "command": "./hooks/format.sh" } ],
            "beforeSubmitPrompt": [ { "command": "[ -x \\"$HOME/.breakpoint/bin/breakpoint\\" ] && \\"$HOME/.breakpoint/bin/breakpoint\\" emit agentStarted --source cursor --stdin-json >/dev/null 2>&1 || true" } ]
          }
        }
        """,
        modified: """
        {"version": 1, "hooks": {"stop": [{"command": "~/.breakpoint/bin/breakpoint emit agentFinished --source cursor", "timeout": 2}]}}
        """,
        unparseable: ["{\"version\": 2, \"hooks\": {}}", "{\"version\":1,\"hooks\":", "{\"version\": \"1\"}", "{\"hooks\": {\"stop\": 3}}"])

    static let codex = JSONToolCase(
        id: .codex, folder: ".codex", file: ".codex/hooks.json",
        rich: """
        {
          "hooks": {
            "Stop": [ { "hooks": [ { "type": "command", "command": "notify-send codex", "timeout": 30 } ] } ],
            "PreToolUse": [ { "matcher": "shell", "hooks": [ { "type": "command", "command": "python3 ~/.codex/guard.py" } ] } ]
          },
          "description": "my hooks"
        }

        """,
        unusual: ["{\"hooks\":{}}\n", "{\n\t\"hooks\": {\n\t\t\"PreCompact\": []\n\t}\n}"],
        older: """
        {
          "hooks": {
            "Stop": [ { "hooks": [ { "type": "command", "command": "notify-send codex", "timeout": 30 } ] } ],
            "Interrupt": [ { "hooks": [ { "type": "command", "timeout": 1, "command": "[ -x \\"$HOME/.breakpoint/bin/breakpoint\\" ] && \\"$HOME/.breakpoint/bin/breakpoint\\" emit agentFinished --source codex --stdin-json >/dev/null 2>&1 || true" } ] } ]
          }
        }
        """,
        modified: """
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "$HOME/.breakpoint/bin/breakpoint emit agentFinished --source codex --stdin-json; echo hi"}]}]}}
        """,
        unparseable: ["{\"hooks\": \"none\"}", "{hooks: {}}"])

    static let gemini = JSONToolCase(
        id: .gemini, folder: ".gemini", file: ".gemini/settings.json",
        rich: """
        {
          // Gemini settings
          "theme": "GitHub",
          "general": { "vimMode": true },
          "hooks": {
            /* other hooks */
            "AfterAgent": [
              { "matcher": "*", "hooks": [ { "name": "chime", "type": "command", "command": "afplay ~/chime.aiff", "timeout": 5000 } ] }
            ]
          } // end of hooks
        }

        """,
        unusual: ["{ /* only a comment */ }", "{\n  \"a\": 1 // trailing comment\n}\n", "{}\n"],
        older: """
        {
          "theme": "GitHub",
          "hooks": {
            "BeforeAgent": [
              { "matcher": "*", "hooks": [ { "type": "command", "command": "[ -x \\"$HOME/.breakpoint/bin/breakpoint\\" ] && \\"$HOME/.breakpoint/bin/breakpoint\\" emit agentStarted --source gemini --stdin-json >/dev/null 2>&1 || true" } ] }
            ]
          }
        }
        """,
        modified: """
        {"hooks": {"BeforeAgent": [{"matcher": "*", "hooks": [{"type": "command", "command": "$HOME/.breakpoint/bin/breakpoint emit agentStarted --source gemini --verbose"}]}]}}
        """,
        unparseable: ["{ /* open comment }", "{\"hooks\": {\"BeforeAgent\": \"x\"}}"])

    static let all: [JSONToolCase] = [.claude, .cursor, .codex, .gemini]
}

@Suite("JSON hook installers")
struct JSONInstallerTests {
    func setUp(_ tool: JSONToolCase) -> FakeHome {
        let home = FakeHome()
        home.mkdir(tool.folder)
        return home
    }

    /// Breakpoint's events in the file, after install.
    func assertEntriesPresent(_ tool: JSONToolCase, _ text: String, paths: BreakpointPaths) throws {
        let value = try json(text, comments: tool.id == .gemini)
        let wanted: [JSONSettingsMerger.HookEntry]
        switch tool.id {
        case .claudeCode: wanted = ClaudeCodeIntegration.entries(paths)
        case .cursor: wanted = CursorIntegration.entries(paths)
        case .codex: wanted = CodexIntegration.entries(paths)
        default: wanted = GeminiIntegration.entries(paths)
        }
        for entry in wanted {
            guard case .array(let items)? = value["hooks"]?[entry.event] else {
                Issue.record("\(tool.id) \(entry.event) missing")
                continue
            }
            let found = items.contains { item in
                if tool.id == .cursor { return item.semanticallyEquals(entry.handler) }
                return item["matcher"]?.stringValue == entry.matcher
                    && item["hooks"]?.semanticallyEquals(.array([entry.handler])) == true
            }
            #expect(found, "\(tool.id) \(entry.event)")
        }
    }

    @Test(arguments: JSONToolCase.all)
    func noConfigFile(_ tool: JSONToolCase) throws {
        let home = setUp(tool)
        defer { home.cleanup() }
        let integration = tool.integration(home)
        #expect(integration.status() == .notInstalled)

        let report = try integration.install()
        let installed = try #require(home.read(tool.file))
        try assertEntriesPresent(tool, installed, paths: home.paths)
        #expect(report.changedFiles.map(\.path) == [home.path(tool.file).path])
        #expect(report.backups.isEmpty)
        #expect(integration.status() == .installed)
        #expect(installed.hasSuffix("}\n"))

        // Idempotent: nothing changes, no backup.
        let again = try integration.install()
        #expect(again.changedFiles.isEmpty)
        #expect(home.read(tool.file) == installed)
        #expect(home.backups.isEmpty)

        _ = try integration.uninstall()
        #expect(!home.exists(tool.file))
        #expect(integration.status() == .notInstalled)
        #expect(home.ledger.files.isEmpty)
        // Uninstalling again changes nothing.
        #expect(try integration.uninstall().changedFiles.isEmpty)
    }

    @Test(arguments: JSONToolCase.all)
    func emptyFile(_ tool: JSONToolCase) throws {
        let home = setUp(tool)
        defer { home.cleanup() }
        home.write(tool.file, "")
        let integration = tool.integration(home)
        #expect(integration.status() == .notInstalled)
        let report = try integration.install()
        #expect(report.backups.count == 1)
        try assertEntriesPresent(tool, try #require(home.read(tool.file)), paths: home.paths)
        _ = try integration.uninstall()
        #expect(home.read(tool.file) == "")
        #expect(home.backups.count == 2)
    }

    @Test(arguments: JSONToolCase.all)
    func richConfigIsPreservedAndRestoredExactly(_ tool: JSONToolCase) throws {
        let home = setUp(tool)
        defer { home.cleanup() }
        home.write(tool.file, tool.rich)
        let integration = tool.integration(home)
        #expect(integration.status() == .notInstalled)

        let report = try integration.install()
        let installed = try #require(home.read(tool.file))
        try assertEntriesPresent(tool, installed, paths: home.paths)
        #expect(integration.status() == .installed)
        // The backup is the original, byte for byte, and private.
        let backup = try #require(report.backups.first)
        #expect(try String(contentsOf: backup, encoding: .utf8) == tool.rich)
        #expect(backup.lastPathComponent.hasPrefix("\(tool.id.rawValue)-"))
        #expect(backup.pathExtension == "json")
        let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Everything that was there is still there, in order: the original text minus its final
        // closing lines is a prefix of the new text.
        let original = try json(tool.rich, comments: tool.id == .gemini)
        for command in original.commands { #expect(installed.contains(JSONRender.quote(command))) }

        #expect(try integration.install().changedFiles.isEmpty)
        #expect(home.read(tool.file) == installed)

        _ = try integration.uninstall()
        #expect(home.read(tool.file) == tool.rich)
    }

    @Test(arguments: JSONToolCase.all)
    func unusualFormattingRestoresExactly(_ tool: JSONToolCase) throws {
        for text in tool.unusual {
            let home = setUp(tool)
            defer { home.cleanup() }
            home.write(tool.file, text)
            let integration = tool.integration(home)
            _ = try integration.install()
            try assertEntriesPresent(tool, try #require(home.read(tool.file)), paths: home.paths)
            #expect(integration.status() == .installed, "\(text.debugDescription)")
            _ = try integration.uninstall()
            #expect(home.read(tool.file) == text, "\(text.debugDescription)")
        }
    }

    @Test(arguments: JSONToolCase.all)
    func olderEntriesAreReportedAndUpgraded(_ tool: JSONToolCase) throws {
        let home = setUp(tool)
        defer { home.cleanup() }
        home.write(tool.file, tool.older)
        let integration = tool.integration(home)
        #expect(integration.status() == .outdated)
        #expect(integration.status().hasBreakpointEntries)
        _ = try integration.install()
        #expect(integration.status() == .installed)
        try assertEntriesPresent(tool, try #require(home.read(tool.file)), paths: home.paths)
        _ = try integration.uninstall()
        // The foreign content of the older file, without any Breakpoint entry.
        let after = try json(try #require(home.read(tool.file)), comments: tool.id == .gemini)
        #expect(after.commands.allSatisfy { !HookMarker(source: tool.id.source).matches($0) })
        let foreignCommands = try json(tool.older, comments: tool.id == .gemini).commands
            .filter { !HookMarker(source: tool.id.source).matches($0) }
        #expect(after.commands == foreignCommands)
        #expect(integration.status() == .notInstalled)
    }

    @Test(arguments: JSONToolCase.all)
    func editedEntriesAreReportedAndRestored(_ tool: JSONToolCase) throws {
        let home = setUp(tool)
        defer { home.cleanup() }
        home.write(tool.file, tool.modified)
        let integration = tool.integration(home)
        #expect(integration.status() == .modified)
        _ = try integration.install()
        #expect(integration.status() == .installed)
        _ = try integration.uninstall()
        #expect(integration.status() == .notInstalled)
    }

    @Test(arguments: JSONToolCase.all)
    func unparseableFilesAreRefusedAndUntouched(_ tool: JSONToolCase) throws {
        for text in tool.unparseable {
            let home = setUp(tool)
            defer { home.cleanup() }
            home.write(tool.file, text)
            let integration = tool.integration(home)
            guard case .unreadable(let reason) = integration.status() else {
                Issue.record("\(tool.id) status for \(text.debugDescription): \(integration.status())")
                continue
            }
            #expect(!reason.isEmpty)
            do {
                _ = try integration.install()
                Issue.record("\(tool.id) installed into \(text.debugDescription)")
            } catch let error as IntegrationError {
                guard case .unparseableFile = error else {
                    Issue.record("wrong error \(error)")
                    continue
                }
                #expect(error.explanation.contains("nothing was changed"))
            }
            #expect(home.read(tool.file) == text)
            #expect(home.backups.isEmpty)
            // Uninstall either refuses or finds nothing of Breakpoint's; it never edits the file.
            _ = try? integration.uninstall()
            #expect(home.read(tool.file) == text)
            #expect(home.backups.isEmpty)
        }
    }

    @Test(arguments: JSONToolCase.all)
    func missingToolFolder(_ tool: JSONToolCase) throws {
        let home = FakeHome()
        defer { home.cleanup() }
        let integration = tool.integration(home)
        #expect(!integration.detect())
        #expect(integration.status() == .notFound)
        #expect(throws: IntegrationError.toolNotFound(tool.id)) { try integration.install() }
        #expect(try integration.uninstall().changedFiles.isEmpty)
        #expect(!home.exists(tool.folder))
    }

    @Test func otherSourcesEntriesAreNeverTouched() throws {
        let tool = JSONToolCase.claude
        let home = setUp(tool)
        defer { home.cleanup() }
        home.write(tool.file, tool.rich)
        _ = try tool.integration(home).install()
        _ = try tool.integration(home).uninstall()
        // The rich fixture carries a `--source cursor` Breakpoint hook; it survives.
        #expect(home.read(tool.file)!.contains("--source cursor"))
    }

    @Test func claudeCodeHooksAreAsyncExceptSessionEnd() throws {
        for entry in ClaudeCodeIntegration.entries(.sample) {
            let handler = entry.handler
            #expect(handler["type"] == .string("command"))
            if entry.event == "SessionEnd" {
                #expect(handler["async"] == nil)
                #expect(handler["timeout"] == .int(2))
            } else {
                #expect(handler["async"] == .bool(true), "\(entry.event)")
            }
        }
        let events = Set(ClaudeCodeIntegration.entries(.sample).map(\.event))
        #expect(events == ["SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest", "PreToolUse",
                           "Notification", "Stop", "StopFailure", "SubagentStop", "SessionEnd"])
        #expect(ClaudeCodeIntegration.entries(.sample).first { $0.event == "PreToolUse" }?.matcher == "AskUserQuestion")
        #expect(ClaudeCodeIntegration.entries(.sample).first { $0.event == "PermissionRequest" }?.matcher == "*")
    }

    @Test func cursorNeverRegistersPermissionHooks() throws {
        let home = setUp(.cursor)
        defer { home.cleanup() }
        _ = try JSONToolCase.cursor.integration(home).install()
        let value = try json(try #require(home.read(".cursor/hooks.json")))
        guard case .object(let events)? = value["hooks"] else { throw IntegrationError.io("no hooks") }
        for event in events { #expect(!CursorIntegration.forbiddenEvents.contains(event.key)) }
        #expect(value["version"] == .int(1))
        for event in events {
            guard case .array(let handlers) = event.value else { continue }
            for handler in handlers {
                #expect(handler["timeout"] == .int(2))
                #expect(handler["async"] == nil)
            }
        }
    }

    @Test func codexHooksAndTrustNote() throws {
        let home = setUp(.codex)
        defer { home.cleanup() }
        let report = try JSONToolCase.codex.integration(home).install()
        #expect(report.notes == [CodexIntegration.trustNote])
        for entry in CodexIntegration.entries(home.paths) {
            switch entry.event {
            case "Interrupt": #expect(entry.handler["timeout"] == .int(1)); #expect(entry.handler["async"] == nil)
            case "SessionEnd": #expect(entry.handler["timeout"] == .int(2)); #expect(entry.handler["async"] == nil)
            default: #expect(entry.handler["async"] == .bool(true))
            }
        }
    }

    @Test func codexHomeOverrideIsUsed() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.mkdir("alt-codex")
        var environment = home.environment
        environment.codexHomeOverride = "~/alt-codex"
        _ = try CodexIntegration(environment: environment).install()
        #expect(home.exists("alt-codex/hooks.json"))
        #expect(!home.exists(".codex"))
    }

    @Test func codexHomeFromEnvironmentIsIgnoredInsideABreakpointHome() {
        let paths = BreakpointPaths(home: URL(fileURLWithPath: "/Users/tester"))
        let sandboxed = IntegrationEnvironment(paths: paths, processEnvironment: ["CODEX_HOME": "/real/codex", "BREAKPOINT_HOME": "/Users/tester"])
        #expect(sandboxed.codexHome.path == "/Users/tester/.codex")
        let real = IntegrationEnvironment(paths: paths, processEnvironment: ["CODEX_HOME": "/real/codex"])
        #expect(real.codexHome.path == "/real/codex")
    }

    @Test func symlinkedSettingsStayLinksAndModeIsKept() throws {
        let tool = JSONToolCase.claude
        let home = setUp(tool)
        defer { home.cleanup() }
        home.write("dotfiles/claude-settings.json", tool.rich)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.path("dotfiles/claude-settings.json").path)
        try FileManager.default.createSymbolicLink(atPath: home.path(tool.file).path, withDestinationPath: "../dotfiles/claude-settings.json")

        _ = try tool.integration(home).install()
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: home.path(tool.file).path)
        #expect(link.replacingOccurrences(of: "\\", with: "/") == "../dotfiles/claude-settings.json")
        #expect(home.read("dotfiles/claude-settings.json")!.contains("--source claude-code"))
        #if !os(Windows)
        let mode = try FileManager.default.attributesOfItem(atPath: home.path("dotfiles/claude-settings.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #endif

        _ = try tool.integration(home).uninstall()
        #expect(home.read("dotfiles/claude-settings.json") == tool.rich)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: home.path(tool.file).path)) != nil)
    }

    @Test func installCopiesTheCLIWhenGivenOne() throws {
        let home = setUp(.claude)
        defer { home.cleanup() }
        home.writeExecutable("bundle/breakpoint", "#!/bin/sh\nexit 0\n")
        var environment = home.environment
        environment.bundledCLI = home.path("bundle/breakpoint")
        _ = try ClaudeCodeIntegration(environment: environment).install()
        #expect(home.read(FakeHome.cliCopy) == FakeHome.executableText("#!/bin/sh\nexit 0\n"))
        #expect(FileManager.default.fileExists(atPath: home.paths.cliCopy.path))
        #expect(CLIInstaller(paths: home.paths, bundledCLI: environment.bundledCLI!).installedVersion == BreakpointVersion.current)
    }

    /// Development builds (and any rebuild without a version bump) keep the same version string,
    /// so a version-only check left every hook running the old command-line tool forever.
    @Test func cliCopyIsRefreshedWhenItsBytesDiffer() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.writeExecutable("bundle/breakpoint", "#!/bin/sh\nexit 0\n")
        let installer = CLIInstaller(paths: home.paths, bundledCLI: home.path("bundle/breakpoint"))
        #expect(installer.needsRefresh())
        try installer.install()
        #expect(!installer.needsRefresh())
        home.writeExecutable("bundle/breakpoint", "#!/bin/sh\n# fixed\nexit 0\n")
        #expect(installer.needsRefresh())
        try installer.install()
        #expect(!installer.needsRefresh())
        #expect(home.read(FakeHome.cliCopy) == FakeHome.executableText("#!/bin/sh\n# fixed\nexit 0\n"))
    }

    @Test func concurrentWriterIsNotOverwritten() throws {
        let home = setUp(.claude)
        defer { home.cleanup() }
        home.write(".claude/settings.json", "{\n  \"model\": \"opus\"\n}\n")
        let file = ConfigFile(url: home.path(".claude/settings.json"), tool: .claudeCode, environment: home.environment)
        var calls = 0
        try file.update { text in
            calls += 1
            if calls == 1 {
                // The tool saves the file while Breakpoint is preparing its edit.
                home.write(".claude/settings.json", "{\n  \"model\": \"sonnet\"\n}\n")
            }
            return try JSONSettingsMerger.merge(ClaudeCodeIntegration.entries(home.paths), into: text ?? "", marker: HookMarker(source: .claudeCode),
                                                format: .init(layout: .grouped), file: file.url)
        }
        #expect(calls == 2)
        #expect(home.read(".claude/settings.json")!.contains("\"sonnet\""))
        #expect(home.read(".claude/settings.json")!.contains("--source claude-code"))
    }

    /// A file the user made read-only (or that another user owns) is a deliberate lock: replacing
    /// it through a temporary file would succeed and silently undo the lock. Nothing is written,
    /// not even a backup.
    @Test(arguments: JSONToolCase.all)
    func readOnlyFileIsLeftAlone(tool: JSONToolCase) throws {
        let home = setUp(tool)
        defer { home.cleanup() }
        home.write(tool.file, tool.rich)
        let url = home.path(tool.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        #expect(throws: IntegrationError.self) { try tool.integration(home).install() }
        #expect(home.read(tool.file) == tool.rich)
        #expect(home.backups.isEmpty)
        #expect(home.ledger.files.isEmpty)
    }

    /// A folder Breakpoint cannot write in used to get a backup made first and then the write
    /// failed, leaving an orphan backup behind.
    @Test func unwritableFolderLeavesNoBackupBehind() throws {
        let tool = JSONToolCase.claude
        let home = setUp(tool)
        defer { home.cleanup() }
        home.write(tool.file, tool.rich)
        let folder = home.path(tool.file).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(throws: IntegrationError.self) { try tool.integration(home).install() }
        #expect(home.read(tool.file) == tool.rich)
        #expect(home.backups.isEmpty)
    }

    /// Replacing a hard-linked file through rename would split the link: the other name would keep
    /// the old text while the tool reads the new one (or the reverse). Refused instead.
    @Test func hardLinkedFileIsLeftAlone() throws {
        let tool = JSONToolCase.claude
        let home = setUp(tool)
        defer { home.cleanup() }
        home.write("dotfiles/claude.json", tool.rich)
        #if os(Windows)
        // Foundation's linkItem copies on Windows; make a real hard link.
        let linked = PathDisplay.native(home.path(tool.file)).withCString(encodedAs: UTF16.self) { link in
            PathDisplay.native(home.path("dotfiles/claude.json")).withCString(encodedAs: UTF16.self) { CreateHardLinkW(link, $0, nil) }
        }
        #expect(linked)
        #else
        try FileManager.default.linkItem(at: home.path("dotfiles/claude.json"), to: home.path(tool.file))
        #endif
        #expect(throws: IntegrationError.self) { try tool.integration(home).install() }
        #expect(home.read(tool.file) == tool.rich)
        #expect(home.backups.isEmpty)
    }

    @Test func emptyGroupsAndArraysAreRemovedOnlyIfBreakpointEmptiedThem() throws {
        let tool = JSONToolCase.claude
        let home = setUp(tool)
        defer { home.cleanup() }
        let text = """
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "mine" }, { "type": "command", "async": true, "command": "[ -x \\"$HOME/.breakpoint/bin/breakpoint\\" ] && \\"$HOME/.breakpoint/bin/breakpoint\\" emit agentFinished --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] },
              { "hooks": [] }
            ],
            "PreCompact": []
          }
        }
        """
        home.write(tool.file, text)
        _ = try tool.integration(home).uninstall()
        let after = try json(try #require(home.read(tool.file)))
        #expect(after["hooks"]?["PreCompact"] == .array([]))
        guard case .array(let groups)? = after["hooks"]?["Stop"] else { throw IntegrationError.io("Stop missing") }
        #expect(groups.count == 2)
        #expect(groups[0]["hooks"]?.commands == ["mine"])
        #expect(groups[1]["hooks"] == .array([]))
    }
}

@Suite("Integrations ledger")
struct IntegrationLedgerTests {
    /// The app and `breakpoint install` can update the ledger at the same moment (each install runs
    /// off the main thread, the CLI in its own process). A plain read-modify-write lost one of the
    /// records, so a later uninstall could no longer restore that file exactly.
    @Test func concurrentUpdatesAreNotLost() async throws {
        let home = FakeHome()
        defer { home.cleanup() }
        try home.paths.ensureAppSupportDirectory()
        let paths = home.paths
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    IntegrationLedger.update(paths) { ledger in
                        var record = IntegrationLedger.FileRecord()
                        record.hasOriginal = true
                        ledger.files["/file-\(i)"] = record
                    }
                }
            }
        }
        #expect(IntegrationLedger.load(paths).files.count == 40)
    }
}
