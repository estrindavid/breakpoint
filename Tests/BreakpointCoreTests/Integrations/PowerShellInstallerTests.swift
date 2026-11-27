import Foundation
import Testing
@testable import BreakpointCore

/// The Windows shell integration (SPEC §5.5): a marker block at the end of each PowerShell's
/// profile and the snippet in `~/.breakpoint/shell/breakpoint.ps1`. The file editing runs on every
/// platform; the snippet itself runs in Windows PowerShell on Windows.
@Suite("PowerShell installer")
struct PowerShellInstallerTests {
    static let profile51 = "Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"
    static let profile7 = "Documents/PowerShell/Microsoft.PowerShell_profile.ps1"
    let starship = "Invoke-Expression (&starship init powershell)\nSet-Alias gs git\n"

    @Test func freshHomeCreatesTheWindowsPowerShellProfileAndRemovesItAgain() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        let shell = PowerShellIntegration(environment: home.environment)
        #expect(shell.detect())
        #expect(shell.status() == .notInstalled)
        let report = try shell.install()
        #expect(report.notes.contains { $0.contains("new PowerShell window") })
        #expect(home.read(Self.profile51) == MarkerBlockEditor.block(body: PowerShellIntegration.blockBody))
        #expect(!home.exists(Self.profile7), "PowerShell 7 is left alone when it has no folder")
        #expect(home.read(".breakpoint/shell/breakpoint.ps1") == PowerShellSnippet.text)
        #expect(shell.status() == .installed)
        #expect(try shell.install().changedFiles.isEmpty)

        _ = try shell.uninstall()
        #expect(!home.exists(Self.profile51))
        #expect(!home.exists("Documents/WindowsPowerShell"), "the folder Breakpoint made is removed")
        #expect(!home.exists(".breakpoint/shell"))
        #expect(shell.status() == .notInstalled)
        #expect(home.ledger.files.isEmpty)
    }

    @Test func bothProfilesAreEditedAtTheirEndAndRestoredExactly() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write(Self.profile7, starship)
        home.write(Self.profile51, "Import-Module posh-git")
        let shell = PowerShellIntegration(environment: home.environment)
        _ = try shell.install()
        for file in [Self.profile7, Self.profile51] {
            let text = try #require(home.read(file))
            #expect(text.hasSuffix(MarkerBlockEditor.block(body: PowerShellIntegration.blockBody)),
                    "the block comes last, after any prompt set up earlier")
        }
        #expect(home.read(Self.profile7)!.hasPrefix(starship))
        #expect(shell.status() == .installed)
        _ = try shell.uninstall()
        #expect(home.read(Self.profile7) == starship)
        // No final newline originally: it comes back with one (same meaning to PowerShell).
        #expect(home.read(Self.profile51) == "Import-Module posh-git\n")
    }

    @Test func editedOutdatedAndMalformedStates() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        let shell = PowerShellIntegration(environment: home.environment)
        _ = try shell.install()
        home.write(".breakpoint/shell/breakpoint.ps1", "# old snippet\n")
        #expect(shell.status() == .outdated)
        _ = try shell.install()
        #expect(shell.status() == .installed)
        home.write(Self.profile51, MarkerBlockEditor.block(body: "# edited by hand"))
        #expect(shell.status() == .modified)
        home.write(Self.profile51, "\(MarkerBlockEditor.beginMarker)\nno end marker\n")
        guard case .unreadable = shell.status() else {
            Issue.record("a block without its end marker reads as unreadable")
            return
        }
        #expect(throws: IntegrationError.self) { try shell.install() }
    }

    @Test func aRedirectedDocumentsFolderIsUsed() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        let oneDrive = home.path("OneDrive/Documents")
        var environment = home.environment
        environment.processEnvironment["BREAKPOINT_DOCUMENTS"] = oneDrive.path
        let shell = PowerShellIntegration(environment: environment)
        _ = try shell.install()
        #expect(home.exists("OneDrive/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"))
        #expect(!home.exists(Self.profile51))
    }

    @Test func theSnippetSendsOnlyTheCommandName() {
        let snippet = PowerShellSnippet.text
        #expect(snippet.contains("PSParser]::Tokenize"))
        #expect(snippet.contains("'--title', $global:__bp.Name"))
        #expect(!snippet.contains("CommandLine)\n"), "the whole line is only tokenized, never sent")
        #expect(snippet.contains("$ms -ge 2000"))
        #expect(snippet.contains("CreateNoWindow = $true"))
        #expect(snippet.hasPrefix(PowerShellSnippet.header))
    }

    #if os(Windows)
    /// Runs the snippet's functions in Windows PowerShell (`-Command`, where the snippet itself
    /// would stand down, so the guard lines are dropped here).
    static func run(_ script: String, home: URL) throws -> CLI.Result {
        let body = PowerShellSnippet.text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("if ($global:__bp_loaded") && !$0.hasPrefix("if ([Environment]::GetCommandLineArgs()") }
            .joined(separator: "\n")
        let (shell, _) = CLI.shellArguments("")
        return try CLI.run(["-NoProfile", "-NonInteractive", "-Command", body + "\n" + script], home: home, executable: shell)
    }

    @Test func commandNamesComeFromPowerShellsOwnTokenizer() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        let cases = [
            "git push --force": "git",
            "$env:TOKEN = 'secret value'; npm run build": "npm",
            "& 'C:\\Program Files\\x\\tool.exe' -a": "",
            "sudo cargo test": "cargo",
            "Get-ChildItem | Select-Object Name": "Get-ChildItem",
            "": "",
        ]
        var script = ""
        for (line, _) in cases {
            let quoted = "'" + line.replacingOccurrences(of: "'", with: "''") + "'"
            script += "Write-Output ('[' + (__bp_command_name \(quoted)) + ']')\n"
        }
        let result = try Self.run(script, home: home.url)
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines == cases.map { "[\($0.value)]" }, "\(result.stdout) \(result.stderr)")
        #expect(!result.stdout.contains("secret"))
    }

    @Test func theSnippetsEmitReachesTheApp() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        try CLIInstaller(paths: f.dir.paths, bundledCLI: CLI.binary).install()
        let result = try Self.run("""
        __bp_emit @('emit', 'commandFinished', '--source', 'shell', '--session', "$PID", '--cwd', 'C:\\work\\my "app"', '--title', 'cargo', '--duration-ms', '4200', '--exit-code', '1')
        Start-Sleep -Milliseconds 300
        """, home: f.dir.url)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(waitUntil { f.inbox.count == 1 })
        let event = try #require(f.inbox.events.first)
        #expect(event.kind == .commandFinished && event.source == .shell && event.title == "cargo")
        #expect(event.cwd == "C:\\work\\my \"app\"")
        #expect(event.durationMS == 4200 && event.exitCode == 1)
    }
    #endif
}
