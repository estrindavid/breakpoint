import Foundation
import Testing
@testable import BreakpointCore

/// What the app verifies on disk after Install (SPEC §5.6): no waiting for the tool, and one
/// sentence that says what to do when something is in the way. The end-to-end half (the hook
/// command reaching the socket) is in CLITests.
@Suite("Install check")
struct InstallCheckTests {
    /// A fake CLI copy: any executable file at `~/.breakpoint/bin/breakpoint`.
    func placeCLICopy(_ home: FakeHome) {
        home.write(".breakpoint/bin/breakpoint", "#!/bin/sh\necho breakpoint 0.0.0\n")
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.paths.cliCopy.path)
    }

    @Test func anInstallThatReadsBackWithItsCommandInPlaceHasNoProblem() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        home.mkdir(".claude")
        home.mkdir(".copilot")
        _ = try ClaudeCodeIntegration(environment: home.environment).install()
        _ = try CopilotIntegration(environment: home.environment).install()
        placeCLICopy(home)
        for id in [IntegrationID.claudeCode, .copilot] {
            let state = IntegrationRegistry.integration(id, environment: home.environment).status()
            #expect(state == .installed)
            #expect(InstallCheck.problem(for: id, state: state, environment: home.environment) == nil)
            #expect(IntegrationStatus(installState: state, lastEvent: nil,
                                      checkProblem: InstallCheck.problem(for: id, state: state, environment: home.environment))
                    == .connected(lastEvent: nil))
        }
    }

    @Test func aMissingOrNonExecutableCommandIsNamedWithWhatToDo() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        let missing = InstallCheck.problem(for: .cursor, state: .installed, environment: home.environment)
        #expect(missing == "The command its hooks call is missing from ~/.breakpoint/bin. Install again to put it back.")
        home.write(".breakpoint/bin/breakpoint", "not executable")
        #expect(InstallCheck.problem(for: .cursor, state: .installed, environment: home.environment) == missing)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.paths.cliCopy.path)
        #expect(InstallCheck.problem(for: .cursor, state: .installed, environment: home.environment) == nil)
    }

    @Test func onlyAnInstallThatReadsBackAsCurrentIsChecked() {
        let home = FakeHome()
        defer { home.cleanup() }
        // No CLI copy here, but these states already say what is wrong (or that nothing is installed).
        for state: IntegrationInstallState in [.notFound, .notInstalled, .outdated, .modified, .unreadable(reason: "x")] {
            #expect(InstallCheck.problem(for: .claudeCode, state: state, environment: home.environment) == nil)
        }
    }

    @Test func claudeCodeWithHooksTurnedOffIsNotShownAsConnected() throws {
        let home = FakeHome()
        defer { home.cleanup() }
        placeCLICopy(home)
        home.write(".claude/settings.json", "{\n  \"disableAllHooks\": true\n}\n")
        _ = try ClaudeCodeIntegration(environment: home.environment).install()
        let state = ClaudeCodeIntegration(environment: home.environment).status()
        #expect(state == .installed)
        let problem = InstallCheck.problem(for: .claudeCode, state: state, environment: home.environment)
        #expect(problem == "Claude Code’s settings have disableAllHooks on. Turn it off, then install again.")
        #expect(problem == InstallCheck.claudeHooksOff)
        #expect(InstallCheck.toolProblem(for: .claudeCode, environment: home.environment) == problem)
        // false, absent, or another tool's file: nothing in the way.
        home.write(".claude/settings.json", "{ \"disableAllHooks\": false }")
        #expect(InstallCheck.toolProblem(for: .claudeCode, environment: home.environment) == nil)
        home.write(".gemini/settings.json", "{ \"disableAllHooks\": true }")
        #expect(InstallCheck.toolProblem(for: .gemini, environment: home.environment) == nil)
    }

    @Test func aCheckThatTimesOutSaysWhichPartFailed() {
        let home = FakeHome()
        defer { home.cleanup() }
        #expect(InstallCheck.unreachableProblem(cliRuns: false, environment: home.environment)
                == "The command its hooks call, in ~/.breakpoint/bin, doesn’t run on this Mac. Install again to replace it.")
        #expect(InstallCheck.unreachableProblem(cliRuns: true, environment: home.environment)
                == "Its hooks can’t reach Breakpoint. To see why, run ~/.breakpoint/bin/breakpoint doctor.")
        // A copy that runs but is not Breakpoint's CLI does not count as running.
        placeCLICopy(home)
        home.write(".breakpoint/bin/breakpoint", "#!/bin/sh\necho something else\n")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.paths.cliCopy.path)
        #expect(!InstallCheck.cliRuns(paths: home.paths))
    }

    @Test func theCheckRunsTheHookCommandFormWithKindTest() {
        let command = InstallCheck.hookCommand(for: .claudeCode)
        #expect(command == HookCommand.shell(.test, source: .claudeCode))
        #expect(command.contains("emit test --source claude-code"))
        #expect(InstallCheck.hookCommand(for: .codexNotify).contains("--source codex"))
        let process = InstallCheck.hookProcess(for: .shell, paths: BreakpointPaths(home: URL(fileURLWithPath: "/tmp/h")),
                                               environment: ["HOME": "/elsewhere", "PATH": "/usr/bin:/bin"])
        #expect(process.executableURL?.path == "/bin/sh")
        #expect(process.arguments == ["-c", HookCommand.shell(.test, source: .shell)])
        #expect(process.environment?["HOME"] == "/tmp/h")
        #expect(process.environment?["PATH"] == "/usr/bin:/bin")
    }
}
