import Foundation
import Testing
@testable import BreakpointCore

@Suite("Marker blocks and TOML")
struct MarkerBlockTests {
    @Test(arguments: ["", "export A=1\n", "export A=1\n\n", "\n", "# only a comment\nalias ll='ls -l'\n\n\n"])
    func appendThenRemoveRestoresExactly(_ original: String) throws {
        let added = try MarkerBlockEditor.upsertChecked(body: "line one\nline two", in: original)
        #expect(added.hasPrefix(original))
        #expect(added.hasSuffix(MarkerBlockEditor.block(body: "line one\nline two")))
        #expect(try MarkerBlockEditor.body(in: added) == "line one\nline two")
        #expect(try MarkerBlockEditor.removeChecked(from: added) == original)
        // Idempotent.
        #expect(try MarkerBlockEditor.upsertChecked(body: "line one\nline two", in: added) == added)
    }

    @Test func missingFinalNewlineIsRestoredWithOne() throws {
        let added = try MarkerBlockEditor.upsertChecked(body: "x", in: "export A=1")
        #expect(added == "export A=1\n\n# >>> breakpoint >>>\nx\n# <<< breakpoint <<<\n")
        #expect(try MarkerBlockEditor.removeChecked(from: added) == "export A=1\n")
    }

    @Test func upsertReplacesTheBodyInPlace() throws {
        let text = "a\n\n# >>> breakpoint >>>\nold\n# <<< breakpoint <<<\n\nb\n"
        #expect(try MarkerBlockEditor.upsertChecked(body: "new", in: text) == "a\n\n# >>> breakpoint >>>\nnew\n# <<< breakpoint <<<\n\nb\n")
        #expect(try MarkerBlockEditor.removeChecked(from: text) == "a\n\nb\n")
    }

    @Test func duplicateBlocksCollapseToOne() throws {
        let block = MarkerBlockEditor.block(body: "x")
        let text = "a\n\n" + block + "\nb\n\n" + block
        let result = try MarkerBlockEditor.upsertChecked(body: "y", in: text)
        #expect(result.components(separatedBy: MarkerBlockEditor.beginMarker).count == 2)
        #expect(try MarkerBlockEditor.removeChecked(from: text) == "a\n\nb\n")
    }

    @Test(arguments: [
        "a\n# >>> breakpoint >>>\nx\n",
        "a\n# <<< breakpoint <<<\n",
        "# >>> breakpoint >>>\n# >>> breakpoint >>>\n# <<< breakpoint <<<\n",
    ])
    func unbalancedMarkersAreRefused(_ text: String) {
        #expect(throws: MarkerBlockEditor.Malformed.self) { try MarkerBlockEditor.upsertChecked(body: "x", in: text) }
        #expect(throws: MarkerBlockEditor.Malformed.self) { try MarkerBlockEditor.removeChecked(from: text) }
        #expect(MarkerBlockEditor.remove(from: text) == text)
    }

    @Test func markersMustBeWholeLines() throws {
        let text = "echo '# >>> breakpoint >>>'\n"
        #expect(try MarkerBlockEditor.body(in: text) == nil)
        #expect(try MarkerBlockEditor.removeChecked(from: text) == text)
    }

    @Test func tomlFindsTopLevelKeysAndTheFirstTable() throws {
        let text = #"""
        model = "o4"
        "quoted.key" = 1
        dotted.key = { a = 1 }
        approvals = [
          "a", # comment with [brackets]
          [1, 2],
        ]
        prompt = """
        [not a table]
        notify = "inside a string"
        """
        literal = '''
        [also not]'''

        # Profiles below
        [profiles.fast]
        notify = ["x"]
        [[mcp.servers]]
        name = "s"
        """#
        let result = try TOMLScan.scan(text)
        #expect(result.topLevelKeys == ["model", "quoted.key", "dotted.key", "approvals", "prompt", "literal"])
        let offset = try #require(result.insertionOffset)
        #expect(String(text.utf8.dropFirst(offset))!.hasPrefix("# Profiles below\n[profiles.fast]"))
    }

    @Test(arguments: [
        "a = \"open", "a = [1, 2", "a = \"\"\"never closed", "just words", "a =", "[table", "a = ]",
    ])
    func tomlRejectsBrokenText(_ text: String) {
        #expect(throws: TOMLScan.SyntaxError.self) { try TOMLScan.scan(text) }
    }
}

@Suite("Codex legacy notify installer")
struct CodexNotifyInstallerTests {
    func setUp() -> FakeHome {
        let home = FakeHome()
        home.mkdir(".codex")
        return home
    }

    /// The CLI path is the one value from the machine written into a tool's config: a home folder
    /// with spaces, quotes, backslashes or a newline stays one TOML string and cannot add a key.
    @Test func anOddHomeFolderStaysOneString() throws {
        let path = "/Users/a b\"]\nevil = [\"x\\y\"]\t#/.breakpoint/bin/breakpoint"
        let quoted = TOMLScan.basicString(path)
        #expect(quoted == "\"/Users/a b\\\"]\\nevil = [\\\"x\\\\y\\\"]\\t#/.breakpoint/bin/breakpoint\"")
        let line = "notify = [" + quoted + ", \"emit\"]\n"
        #expect(try TOMLScan.scan(line).topLevelKeys == ["notify"])
    }

    @Test func noConfigFile() throws {
        let home = setUp()
        defer { home.cleanup() }
        let integration = CodexNotifyIntegration(environment: home.environment)
        #expect(integration.status() == .notInstalled)
        _ = try integration.install()
        let text = try #require(home.read(".codex/config.toml"))
        #expect(text.contains(integration.notifyLine))
        #expect(integration.notifyLine == "notify = [\"\(home.paths.cliCopy.path)\", \"emit\", \"agentFinished\", \"--source\", \"codex\", \"--argv-json\"]")
        #expect(try TOMLScan.scan(text).topLevelKeys == ["notify"])
        #expect(integration.status() == .installed)
        #expect(try integration.install().changedFiles.isEmpty)
        _ = try integration.uninstall()
        #expect(!home.exists(".codex/config.toml"))
    }

    @Test(arguments: [
        "",
        "model = \"o4\"\n",
        "model = \"o4\"\n\n[profiles.fast]\nmodel = \"o4-mini\"\n",
        "# Codex config\n[tui]\nnotifications = true\n",
        "model = \"o4\"\n# comment above\n[mcp_servers.x]\ncommand = \"npx\"\nargs = [\n  \"-y\",\n  \"[pkg]\",\n]\n",
        "approval_policy = \"on-request\"\r\nsandbox_mode = \"workspace-write\"\r\n",
    ])
    func installAndUninstallRestoreExactly(_ original: String) throws {
        let home = setUp()
        defer { home.cleanup() }
        home.write(".codex/config.toml", original)
        let integration = CodexNotifyIntegration(environment: home.environment)
        let report = try integration.install()
        #expect(report.backups.count == 1)
        let text = try #require(home.read(".codex/config.toml"))
        // notify sits among the top-level keys, never inside a table.
        let scan = try TOMLScan.scan(text)
        #expect(scan.topLevelKeys.contains("notify"))
        #expect(integration.status() == .installed)
        _ = try integration.uninstall()
        #expect(home.read(".codex/config.toml") == original)
    }

    @Test func refusesAnExistingNotify() throws {
        let home = setUp()
        defer { home.cleanup() }
        let original = "notify = [\"terminal-notifier\"]\n[tui]\nx = 1\n"
        home.write(".codex/config.toml", original)
        let integration = CodexNotifyIntegration(environment: home.environment)
        #expect(throws: IntegrationError.notifyAlreadySet(home.path(".codex/config.toml"))) { try integration.install() }
        #expect(home.read(".codex/config.toml") == original)
        #expect(home.backups.isEmpty)
        #expect(integration.status() == .notInstalled)
    }

    @Test func notifyInsideATableIsNotTopLevel() throws {
        let home = setUp()
        defer { home.cleanup() }
        home.write(".codex/config.toml", "[profiles.x]\nnotify = [\"a\"]\n")
        _ = try CodexNotifyIntegration(environment: home.environment).install()
        let text = try #require(home.read(".codex/config.toml"))
        #expect(text.hasPrefix(MarkerBlockEditor.beginMarker))
    }

    @Test(arguments: ["model = \"unterminated\n", "[profiles\n", "notify = [\n"])
    func refusesUnparseableToml(_ original: String) throws {
        let home = setUp()
        defer { home.cleanup() }
        home.write(".codex/config.toml", original)
        let integration = CodexNotifyIntegration(environment: home.environment)
        guard case .unreadable = integration.status() else {
            Issue.record("status \(integration.status())")
            return
        }
        #expect(throws: IntegrationError.self) { try integration.install() }
        #expect(home.read(".codex/config.toml") == original)
    }

    @Test func hooksAndNotifyAreMutuallyExclusive() throws {
        let home = setUp()
        defer { home.cleanup() }
        _ = try CodexIntegration(environment: home.environment).install()
        #expect(throws: IntegrationError.conflictsWith(.codex)) { try CodexNotifyIntegration(environment: home.environment).install() }
        _ = try CodexIntegration(environment: home.environment).uninstall()
        _ = try CodexNotifyIntegration(environment: home.environment).install()
        #expect(throws: IntegrationError.conflictsWith(.codexNotify)) { try CodexIntegration(environment: home.environment).install() }
    }

    @Test func editedBlockIsReported() throws {
        let home = setUp()
        defer { home.cleanup() }
        home.write(".codex/config.toml", MarkerBlockEditor.block(body: "notify = [\"/somewhere/else\"]"))
        #expect(CodexNotifyIntegration(environment: home.environment).status() == .modified)
        home.write(".codex/config.toml", MarkerBlockEditor.block(body: "notify = [\"/x/.breakpoint/bin/breakpoint\", \"--argv-json\"]"))
        #expect(CodexNotifyIntegration(environment: home.environment).status() == .outdated)
        _ = try CodexNotifyIntegration(environment: home.environment).install()
        #expect(CodexNotifyIntegration(environment: home.environment).status() == .installed)
    }
}

@Suite("Copilot CLI installer")
struct CopilotInstallerTests {
    @Test func ownsOneFileAndRemovesItCleanly() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.mkdir(".copilot")
        let integration = CopilotIntegration(environment: home.environment)
        #expect(integration.status() == .notInstalled)
        _ = try integration.install()
        let text = try #require(home.read(".copilot/hooks/breakpoint.json"))
        let value = try json(text)
        #expect(value["version"] == .int(1))
        guard case .object(let events)? = value["hooks"] else { throw IntegrationError.io("hooks") }
        #expect(events.map(\.key) == ["sessionStart", "userPromptSubmitted", "notification", "agentStop", "sessionEnd"])
        #expect(!events.contains { $0.key == "preToolUse" })
        for event in events {
            guard case .array(let handlers) = event.value else { continue }
            for handler in handlers {
                #expect(handler["timeoutSec"] == .int(2))
                #expect(handler["bash"]?.stringValue.map(HookMarker(source: .copilot).matches) == true)
            }
        }
        #expect(integration.status() == .installed)
        #expect(try integration.install().changedFiles.isEmpty)
        _ = try integration.uninstall()
        #expect(!home.exists(".copilot/hooks"))
        #expect(home.exists(".copilot"))
        #expect(integration.status() == .notInstalled)
    }

    @Test func keepsAnExistingHooksFolderAndOtherFiles() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write(".copilot/hooks/mine.json", "{\"version\":1,\"hooks\":{}}")
        let integration = CopilotIntegration(environment: home.environment)
        _ = try integration.install()
        _ = try integration.uninstall()
        #expect(home.read(".copilot/hooks/mine.json") == "{\"version\":1,\"hooks\":{}}")
        #expect(!home.exists(".copilot/hooks/breakpoint.json"))
        // Uninstall backed the file up before deleting it.
        #expect(home.backups.count == 1)
    }

    @Test func refusesAForeignFileWithTheSameName() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write(".copilot/hooks/breakpoint.json", "{\"version\":1,\"hooks\":{\"agentStop\":[{\"bash\":\"say hi\"}]}}")
        let integration = CopilotIntegration(environment: home.environment)
        #expect(integration.status() == .notInstalled)
        #expect(throws: IntegrationError.self) { try integration.install() }
        #expect(try integration.uninstall().changedFiles.isEmpty)
        #expect(home.exists(".copilot/hooks/breakpoint.json"))
    }

    @Test func reportsOutdatedEditedAndUnreadable() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        let integration = CopilotIntegration(environment: home.environment)
        #expect(integration.status() == .notFound)
        home.mkdir(".copilot")
        let command = HookCommand.shell(.agentFinished, source: .copilot, paths: home.paths)
        home.write(".copilot/hooks/breakpoint.json", "{\"version\":1,\"hooks\":{\"agentStop\":[{\"type\":\"command\",\"bash\":\(JSONRender.quote(command)),\"timeoutSec\":5}]}}")
        #expect(integration.status() == .outdated)
        home.write(".copilot/hooks/breakpoint.json", "{\"version\":1,\"hooks\":{\"agentStop\":[{\"bash\":\"~/.breakpoint/bin/breakpoint emit agentFinished --source copilot --x\"}]}}")
        #expect(integration.status() == .modified)
        _ = try integration.install()
        #expect(integration.status() == .installed)
        home.write(".copilot/hooks/breakpoint.json", "{not json")
        guard case .unreadable = integration.status() else {
            Issue.record("expected unreadable")
            return
        }
        #expect(throws: IntegrationError.self) { try integration.install() }
        #expect(home.read(".copilot/hooks/breakpoint.json") == "{not json")
    }
}
