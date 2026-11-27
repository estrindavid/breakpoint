import Foundation
import Testing
@testable import BreakpointCore

@Suite("Shell installer")
struct ShellInstallerTests {
    let zshrc = """
    # my zshrc
    export PATH="$HOME/bin:$PATH"
    eval "$(starship init zsh)"
    alias gs='git status'

    """
    let bashrc = "[ -f ~/.fzf.bash ] && source ~/.fzf.bash\nexport EDITOR=vim"
    let bashProfile = "if [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n\n\n"

    @Test func freshHomeCreatesAndThenDeletesZshrc() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        let shell = ShellIntegration(environment: home.environment)
        #expect(shell.detect())
        #expect(shell.status() == .notInstalled)
        let report = try shell.install()
        #expect(report.notes.contains { $0.contains("bash was left alone") })
        #expect(home.read(".zshrc") == MarkerBlockEditor.block(body: ShellIntegration.zshBlockBody))
        #expect(!home.exists(".bashrc") && !home.exists(".bash_profile"))
        #expect(home.read(".breakpoint/shell/breakpoint.zsh") == ShellSnippets.zsh)
        #expect(home.read(".breakpoint/shell/breakpoint.bash") == ShellSnippets.bash)
        #expect(shell.status() == .installed)
        #expect(try shell.install().changedFiles.isEmpty)

        _ = try shell.uninstall()
        #expect(!home.exists(".zshrc"))
        #expect(!home.exists(".breakpoint/shell"))
        #expect(shell.status() == .notInstalled)
        #expect(home.ledger.files.isEmpty)
    }

    @Test func existingRcFilesAreRestoredExactly() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write(".zshrc", zshrc)
        home.write(".bashrc", bashrc)
        home.write(".bash_profile", bashProfile)
        let shell = ShellIntegration(environment: home.environment)
        let report = try shell.install()
        #expect(report.backups.count == 3)
        #expect(home.read(".zshrc")!.hasPrefix(zshrc))
        #expect(try MarkerBlockEditor.body(in: home.read(".bashrc")!) == ShellIntegration.bashBlockBody)
        #expect(try MarkerBlockEditor.body(in: home.read(".bash_profile")!) == ShellIntegration.bashBlockBody)
        #expect(shell.status() == .installed)

        _ = try shell.uninstall()
        #expect(home.read(".zshrc") == zshrc)
        #expect(home.read(".bash_profile") == bashProfile)
        // No final newline originally: it comes back with one (same meaning to the shell).
        #expect(home.read(".bashrc") == bashrc + "\n")
    }

    @Test func emptyZshrcStaysEmpty() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write(".zshrc", "")
        let shell = ShellIntegration(environment: home.environment)
        _ = try shell.install()
        _ = try shell.uninstall()
        #expect(home.read(".zshrc") == "")
    }

    @Test func onlyExistingBashFilesAreEdited() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write(".bashrc", bashrc)
        _ = try ShellIntegration(environment: home.environment).install()
        #expect(!home.exists(".bash_profile"))
        #expect(home.read(".bashrc")!.contains(MarkerBlockEditor.beginMarker))
    }

    @Test func fishSnippetOnlyWhenFishIsConfigured() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        let shell = ShellIntegration(environment: home.environment)
        _ = try shell.install()
        #expect(!home.exists(".config/fish"))
        _ = try shell.uninstall()

        home.mkdir(".config/fish")
        _ = try shell.install()
        #expect(home.read(".config/fish/conf.d/breakpoint.fish") == ShellSnippets.fish)
        #expect(shell.status() == .installed)
        _ = try shell.uninstall()
        #expect(!home.exists(".config/fish/conf.d"))
        #expect(home.exists(".config/fish"))

        home.write(".config/fish/conf.d/other.fish", "set -g x 1\n")
        _ = try shell.install()
        _ = try shell.uninstall()
        #expect(home.read(".config/fish/conf.d/other.fish") == "set -g x 1\n")
    }

    @Test func malformedBlockIsRefusedBeforeAnythingIsWritten() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write(".zshrc", zshrc)
        let broken = "x=1\n# >>> breakpoint >>>\nsource something\n"
        home.write(".bashrc", broken)
        let shell = ShellIntegration(environment: home.environment)
        guard case .unreadable = shell.status() else {
            Issue.record("status \(shell.status())")
            return
        }
        #expect(throws: IntegrationError.self) { try shell.install() }
        #expect(home.read(".zshrc") == zshrc)
        #expect(home.read(".bashrc") == broken)
        #expect(!home.exists(".breakpoint/shell"))
        #expect(home.backups.isEmpty)
    }

    @Test func editedAndOutdatedStates() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write(".zshrc", zshrc)
        let shell = ShellIntegration(environment: home.environment)
        _ = try shell.install()
        home.write(".breakpoint/shell/breakpoint.zsh", "# older snippet\n")
        #expect(shell.status() == .outdated)
        _ = try shell.install()
        #expect(shell.status() == .installed)
        home.write(".zshrc", zshrc + "\n" + MarkerBlockEditor.block(body: "source ~/elsewhere.zsh"))
        #expect(shell.status() == .modified)
        _ = try shell.install()
        #expect(shell.status() == .installed)
        _ = try shell.uninstall()
        #expect(home.read(".zshrc") == zshrc)
    }

    @Test func symlinkedZshrcStaysALink() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write("dotfiles/zshrc", zshrc)
        try FileManager.default.createSymbolicLink(atPath: home.path(".zshrc").path, withDestinationPath: home.path("dotfiles/zshrc").path)
        let shell = ShellIntegration(environment: home.environment)
        _ = try shell.install()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: home.path(".zshrc").path)) != nil)
        #expect(home.read("dotfiles/zshrc")!.contains(MarkerBlockEditor.beginMarker))
        _ = try shell.uninstall()
        #expect(home.read("dotfiles/zshrc") == zshrc)
    }

    @Test func snippetsSendOnlyTheCommandName() {
        for snippet in [ShellSnippets.zsh, ShellSnippets.bash, ShellSnippets.fish] {
            #expect(snippet.contains("--title"))
            #expect(snippet.contains("--source shell"))
            #expect(snippet.contains("--session"))
            #expect(!snippet.contains("--title \"$1\""))
        }
    }

    /// Runs a shell with no startup files, in the fake home, and returns its exit status and output.
    static func runShell(_ executable: String, _ arguments: [String], home: URL) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin", "BREAKPOINT_HOME": home.path]
        process.currentDirectoryURL = home
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    @Test(.disabled(if: BreakpointPlatform.isWindows, "zsh and bash are macOS shells here")) func snippetsPassShellSyntaxChecks() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write("bp.zsh", ShellSnippets.zsh)
        home.write("bp.bash", ShellSnippets.bash)
        let (zshStatus, zshOutput) = try Self.runShell("/bin/zsh", ["-f", "-n", home.path("bp.zsh").path], home: home.url)
        #expect(zshStatus == 0, "\(zshOutput)")
        let (bashStatus, bashOutput) = try Self.runShell("/bin/bash", ["--norc", "--noprofile", "-n", home.path("bp.bash").path], home: home.url)
        #expect(bashStatus == 0, "\(bashOutput)")
        // Sourcing in a non-interactive shell does nothing and prints nothing.
        for (shell, file) in [("/bin/zsh", "bp.zsh"), ("/bin/bash", "bp.bash")] {
            let flags = shell.hasSuffix("zsh") ? ["-f", "-c"] : ["--norc", "--noprofile", "-c"]
            let (status, output) = try Self.runShell(shell, flags + ["source \(home.path(file).path); echo ok"], home: home.url)
            #expect(status == 0)
            #expect(output == "ok\n", "\(shell): \(output)")
        }
    }

    /// Runs an interactive shell that reads `script` from stdin, so prompts are drawn and the
    /// prompt hooks (PROMPT_COMMAND, the DEBUG trap, precmd/preexec) really fire.
    static func runInteractive(_ executable: String, _ arguments: [String], script: String, home: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin", "PS1": "$ "]
        process.currentDirectoryURL = home
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// A stand-in for the CLI copy that records each call's arguments in `calls`.
    static func installRecordingCLI(_ home: FakeHome) throws {
        home.write(".breakpoint/bin/breakpoint", "#!/bin/sh\necho \"$*\" >> \"$HOME/calls\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path(".breakpoint/bin/breakpoint").path)
    }

    /// The user's own PROMPT_COMMAND must keep working after the snippet joins it, whatever it ends
    /// with (`history -a;` is a common idiom; a trailing `;`, `&` or newline used to make every
    /// prompt print a syntax error and stop the user's command from running).
    @Test(.disabled(if: BreakpointPlatform.isWindows, "zsh and bash are macOS shells here"), arguments: ["echo PC-RAN;", "echo PC-RAN ; ", "echo PC-RAN\n", "echo PC-RAN", "echo PC-RAN &", ""])
    func bashSnippetKeepsTheUsersPromptCommandWorking(existing: String) throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write("bp.bash", ShellSnippets.bash)
        try Self.installRecordingCLI(home)
        let script = """
        PROMPT_COMMAND=\(shellQuote(existing))
        source "$HOME/bp.bash"
        uname -s
        sleep 0.3
        exit

        """
        let output = try Self.runInteractive("/bin/bash", ["--norc", "--noprofile", "-i"], script: script, home: home.url)
        #expect(!output.contains("syntax error"), "\(output)")
        if !existing.isEmpty {
            #expect(output.components(separatedBy: "PC-RAN").count > 2, "the user's PROMPT_COMMAND stopped running: \(output)")
        }
        let calls = Self.waitForCalls(home, containing: "--title uname")
        #expect(calls.contains("emit commandStarted --source shell"), "\(output)")
        #expect(calls.contains("--title uname"), "\(calls)")
    }

    /// The recording CLI runs in the background: wait (up to 5 s) for `text` to show up.
    static func waitForCalls(_ home: FakeHome, containing text: String) -> String {
        for _ in 0..<50 {
            if let calls = home.read("calls"), calls.contains(text) { return calls }
            usleep(100_000)
        }
        return home.read("calls") ?? ""
    }

    @Test(.disabled(if: BreakpointPlatform.isWindows, "zsh and bash are macOS shells here")) func zshSnippetHooksFireInAnInteractiveShell() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write("bp.zsh", ShellSnippets.zsh)
        try Self.installRecordingCLI(home)
        let script = """
        source "$HOME/bp.zsh"
        sleep 2.1; false
        sleep 0.3
        exit

        """
        let output = try Self.runInteractive("/bin/zsh", ["-f", "-i"], script: script, home: home.url)
        let calls = Self.waitForCalls(home, containing: "emit commandFinished")
        #expect(calls.contains("emit commandStarted --source shell"), "\(output)")
        #expect(calls.contains("--title sleep"), "\(calls)")
        // The user's status reaches the snippet ($? of `false`), and the duration is measured.
        #expect(calls.contains("emit commandFinished") && calls.contains("--exit-code 1"), "\(calls)")
    }

    static let fishPath = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// fish splits on spaces only, so a quoted assignment must stop the search instead of leaking
    /// part of its value ("horse'" from `PGPASSWORD='correct horse' psql`). Runs only where fish
    /// is installed.
    @Test(.enabled(if: ShellInstallerTests.fishPath != nil)) func fishCommandNameNeverLeaksAQuotedValue() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write("bp.fish", ShellSnippets.fish.replacingOccurrences(of: "status is-interactive; or exit\n", with: ""))
        let cases: [(String, String)] = [
            ("swift test", "swift"),
            ("FOO=1 make -j8", "make"),
            ("PGPASSWORD='correct horse' psql", ""),
            ("TOKEN=\"a b\" npm test", ""),
            ("sudo -E ./build.sh", "./build.sh"),
        ]
        for (line, expected) in cases {
            let script = "source \(home.path("bp.fish").path); printf '%s' (__bp_command_name \(shellQuote(line)))"
            let (status, output) = try Self.runShell(Self.fishPath!, ["--no-config", "-c", script], home: home.url)
            #expect(status == 0, "\(output)")
            #expect(output == expected, "\(line): \(output)")
        }
    }

    @Test(.disabled(if: BreakpointPlatform.isWindows, "zsh and bash are macOS shells here")) func commandNameExtractionInBothShells() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.write("name.sh", ShellSnippets.commandName + "\n")
        let cases: [(String, String)] = [
            ("swift test", "swift"),
            ("  FOO=1 BAR=\"x y\" make -j8", "make"),
            ("sudo -E time nohup ./build.sh --release", "./build.sh"),
            ("API_KEY=sk-secret", ""),
            ("env A=1 cargo build", "cargo"),
            ("TOKEN='abc def' SECRET=\"x;y z\" npm test", "npm"),
            ("A=1; make", ""),
            ("git push | tee log", "git"),
            ("", ""),
        ]
        for (shell, flags) in [("/bin/zsh", ["-f", "-c"]), ("/bin/bash", ["--norc", "--noprofile", "-c"])] {
            for (line, expected) in cases {
                let script = "source \(home.path("name.sh").path); __bp_command_name \(shellQuote(line)); printf '%s' \"$REPLY\""
                let (status, output) = try Self.runShell(shell, flags + [script], home: home.url)
                #expect(status == 0)
                #expect(output == expected, "\(shell) \(line): \(output)")
            }
        }
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
