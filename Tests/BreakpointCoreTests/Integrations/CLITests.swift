import Foundation
import Testing
@testable import BreakpointCore

/// Runs the built `breakpoint` executable as hooks do. Every run gets a temporary HOME and
/// BREAKPOINT_HOME and a minimal environment (no CLAUDECODE, CURSOR_VERSION, CODEX_HOME… from the
/// machine running the tests).
enum CLI {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let binary = packageRoot.appendingPathComponent(".build/debug/breakpoint")

    /// Fails the test when the binary is missing or older than the sources it is built from.
    static func requireFreshBinary() throws {
        let fm = FileManager.default
        guard let built = (try? fm.attributesOfItem(atPath: binary.path))?[.modificationDate] as? Date else {
            Issue.record("No \(binary.path). Run scripts/test.sh (it builds the CLI first).")
            throw CancellationError()
        }
        for folder in ["Sources/breakpoint-cli", "Sources/BreakpointCore"] {
            let root = packageRoot.appendingPathComponent(folder)
            for case let file as URL in fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])! {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified > built {
                    Issue.record("\(binary.path) is older than \(file.lastPathComponent). Run scripts/test.sh (it builds the CLI first).")
                    throw CancellationError()
                }
            }
        }
    }

    enum Stdin {
        case data(Data)
        case devNull
        /// A pipe whose write end stays open (a hook runner that never closes stdin).
        case leftOpen
        /// A terminal (a person running the command by hand).
        case terminal
    }

    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var seconds: TimeInterval
    }

    static func run(_ arguments: [String], home: URL, stdin: Stdin = .devNull, extraEnvironment: [String: String] = [:],
                    executable: URL = binary) throws -> Result {
        // The child may exit before reading all of stdin (the 1 MB cap); writing then must not kill us.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ["HOME": home.path, "BREAKPOINT_HOME": home.path, "PATH": "/usr/bin:/bin"]
        environment.merge(extraEnvironment) { $1 }
        process.environment = environment
        process.currentDirectoryURL = home
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        var keepOpen: Pipe?
        var terminal: (Int32, Int32)?
        switch stdin {
        case .data(let data):
            let pipe = Pipe()
            process.standardInput = pipe
            if data.count <= 8 * 1024 {
                // Fits in the pipe buffer: written before the child starts, as hook runners do.
                try? pipe.fileHandleForWriting.write(contentsOf: data)
                try? pipe.fileHandleForWriting.close()
            } else {
                DispatchQueue.global().async {
                    try? pipe.fileHandleForWriting.write(contentsOf: data)
                    try? pipe.fileHandleForWriting.close()
                }
            }
        case .devNull:
            process.standardInput = FileHandle.nullDevice
        case .leftOpen:
            let pipe = Pipe()
            keepOpen = pipe
            process.standardInput = pipe
        case .terminal:
            var master: Int32 = 0
            var slave: Int32 = 0
            guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw IntegrationError.io("openpty failed") }
            terminal = (master, slave)
            process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        }
        let start = Date()
        try process.run()
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let seconds = Date().timeIntervalSince(start)
        try? keepOpen?.fileHandleForWriting.close()
        if let (master, slave) = terminal { close(master); close(slave) }
        return Result(status: process.terminationStatus, stdout: String(decoding: stdoutData, as: UTF8.self),
                      stderr: String(decoding: stderrData, as: UTF8.self), seconds: seconds)
    }

    /// Asserts the `emit` contract: silent, exit 0.
    static func expectSilentSuccess(_ result: Result, _ context: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result.status == 0, "\(context): exit \(result.status)", sourceLocation: sourceLocation)
        #expect(result.stdout.isEmpty, "\(context): stdout \(result.stdout.debugDescription)", sourceLocation: sourceLocation)
        #expect(result.stderr.isEmpty, "\(context): stderr \(result.stderr.debugDescription)", sourceLocation: sourceLocation)
    }
}

@Suite("breakpoint emit (subprocess)", .serialized)
struct EmitSubprocessTests {
    /// Each tool's hook as installed (kind, source) with a representative payload.
    static let hookCases: [(kind: AgentEventKind, source: AgentSource, payload: String, check: @Sendable (AgentEvent) -> Bool)] = [
        (.sessionStarted, .claudeCode, Payloads.claudeSessionStart, { $0.source == .claudeCode && $0.sessionID == "abc123" }),
        (.agentStarted, .claudeCode, Payloads.claudePrompt, { $0.title == "Write a function to calculate the factorial of a number" && $0.cwd == "/Users/me/code/app" }),
        (.agentNeedsUser, .claudeCode, Payloads.claudeNotification, { $0.detail == "permission_prompt" }),
        (.agentFinished, .claudeCode, Payloads.claudeStopFailure, { $0.detail == "error" }),
        (.agentStarted, .cursor, Payloads.cursorPrompt, { $0.source == .cursor && $0.via == nil && $0.sessionID == "conv-1" }),
        (.agentStarted, .claudeCode, Payloads.cursorRelayedPrompt, { $0.source == .cursor && $0.via == "claude-code-hooks" }),
        (.agentFinished, .cursor, Payloads.cursorStop, { $0.detail == "aborted" }),
        (.agentStarted, .codex, Payloads.codexPrompt, { $0.sessionID == "thr_123" && $0.cwd == "/workspace" }),
        (.sessionEnded, .codex, Payloads.codexSessionEnd, { $0.kind == .sessionEnded }),
        (.agentStarted, .copilot, Payloads.copilotPrompt, { $0.sessionID == "cp-1" }),
        (.agentNeedsUser, .copilot, Payloads.copilotNotification, { $0.detail == "permission_prompt" }),
        (.agentStarted, .gemini, Payloads.geminiBeforeAgent, { $0.sessionID == "g-1" }),
        (.agentFinished, .gemini, Payloads.geminiNoSession, { $0.sessionID == "gemini:/Users/me/code/ml" }),
    ]

    @Test func everyToolsPayloadArrivesExactlyOnce() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        for (index, hook) in Self.hookCases.enumerated() {
            let result = try CLI.run(["emit", hook.kind.rawValue, "--source", hook.source.rawValue, "--stdin-json"],
                                     home: f.dir.url, stdin: .data(Data(hook.payload.utf8)))
            CLI.expectSilentSuccess(result, "\(hook.source) \(hook.kind)")
            #expect(waitUntil { f.inbox.count == index + 1 }, "\(hook.source) \(hook.kind)")
            let event = try #require(f.inbox.events.last)
            #expect(event.kind == hook.kind)
            #expect(hook.check(event), "\(hook.source) \(hook.kind): \(event)")
        }
        usleep(100_000)
        #expect(f.inbox.count == Self.hookCases.count)
    }

    @Test func dropsWhatMustBeDropped() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        let cases: [[String]] = [
            ["emit"], ["emit", "bogusKind", "--source", "x"], ["emit", "agentStarted"], ["emit", "agentStarted", "--source"],
            ["emit", "agentStarted", "--source", ""], ["emit", "subagentFinished", "--source", "claude-code", "--stdin-json"],
        ]
        for arguments in cases {
            let stdin: CLI.Stdin = arguments.contains("--stdin-json") ? .data(Data(Payloads.claudeSubagentInternal.utf8)) : .devNull
            CLI.expectSilentSuccess(try CLI.run(arguments, home: f.dir.url, stdin: stdin), "\(arguments)")
        }
        usleep(150_000)
        #expect(f.inbox.count == 0)
    }

    @Test func badAndOddInputsStaySilent() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        let base = ["emit", "agentFinished", "--source", "claude-code", "--session", "s", "--stdin-json"]
        let inputs: [(String, CLI.Stdin)] = [
            ("empty", .data(Data())),
            ("malformed", .data(Data("{not json".utf8))),
            ("binary", .data(Data((0..<255).map { UInt8($0) }))),
            ("dev null", .devNull),
            ("huge", .data(Data(repeating: UInt8(ascii: "x"), count: 2_000_000))),
        ]
        for (name, stdin) in inputs {
            let result = try CLI.run(base, home: f.dir.url, stdin: stdin)
            CLI.expectSilentSuccess(result, name)
            #expect(result.seconds < 2, "\(name) took \(result.seconds)")
        }
        #expect(waitUntil { f.inbox.count == inputs.count })
        #expect(f.inbox.events.allSatisfy { $0.sessionID == "s" && $0.kind == .agentFinished })
    }

    @Test func stdinLeftOpenOrATerminalNeverBlocks() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        let open = try CLI.run(["emit", "agentStarted", "--source", "codex", "--session", "o", "--stdin-json"], home: f.dir.url, stdin: .leftOpen)
        CLI.expectSilentSuccess(open, "stdin left open")
        #expect(open.seconds < 1.0, "took \(open.seconds)")
        let tty = try CLI.run(["emit", "agentStarted", "--source", "codex", "--session", "t", "--stdin-json"], home: f.dir.url, stdin: .terminal)
        CLI.expectSilentSuccess(tty, "terminal")
        #expect(tty.seconds < 0.2, "took \(tty.seconds)")
        #expect(waitUntil { f.inbox.count == 2 })
    }

    @Test func noAppRunningOrAStaleSocket() throws {
        try CLI.requireFreshBinary()
        let dir = ShortTemporaryDirectory()
        defer { dir.cleanup() }
        let arguments = ["emit", "agentStarted", "--source", "claude-code", "--stdin-json"]
        let missing = try CLI.run(arguments, home: dir.url, stdin: .data(Data(Payloads.claudePrompt.utf8)))
        CLI.expectSilentSuccess(missing, "no socket")
        #expect(missing.seconds < 0.5)

        // A socket file left by a crashed app.
        let socket = SocketPath(paths: dir.paths)
        try FileManager.default.createDirectory(at: socket.directory, withIntermediateDirectories: true)
        let fd = try #require(UnixSocket.makeSocket())
        #expect(UnixSocket.bind(fd, UnixSocket.address(socket.path)!) == 0)
        close(fd)
        let stale = try CLI.run(arguments, home: dir.url, stdin: .data(Data(Payloads.claudePrompt.utf8)))
        CLI.expectSilentSuccess(stale, "stale socket")
        #expect(stale.seconds < 0.5)

        // Something that is not a socket at all.
        unlink(socket.path)
        try Data("x".utf8).write(to: socket.url)
        CLI.expectSilentSuccess(try CLI.run(arguments, home: dir.url, stdin: .devNull), "not a socket")
    }

    /// A hung (or stopped) app: the socket is listening but nobody accepts or reads. The listen
    /// queue fills up; every hook must still return at once, silently, with status 0.
    @Test func hungAppNeverBlocksTheHook() throws {
        try CLI.requireFreshBinary()
        let dir = ShortTemporaryDirectory()
        defer { dir.cleanup() }
        let socket = SocketPath(paths: dir.paths)
        try FileManager.default.createDirectory(at: socket.directory, withIntermediateDirectories: true)
        let fd = try #require(UnixSocket.makeSocket())
        defer { close(fd) }
        #expect(UnixSocket.bind(fd, UnixSocket.address(socket.path)!) == 0)
        #expect(listen(fd, 1) == 0)
        // A payload larger than the socket buffer, so a connection that is accepted by the kernel
        // but never read cannot take the whole line either.
        let big = "{\"session_id\":\"h\",\"prompt\":\"" + String(repeating: "x", count: 60_000) + "\"}"
        var slowest: TimeInterval = 0
        for _ in 0..<6 {
            let result = try CLI.run(["emit", "agentStarted", "--source", "claude-code", "--stdin-json"], home: dir.url,
                                     stdin: .data(Data(big.utf8)))
            CLI.expectSilentSuccess(result, "hung app")
            slowest = max(slowest, result.seconds)
        }
        #expect(slowest < 1.0, "slowest emit took \(slowest) s")
    }

    @Test func codexNotifyArgvPayload() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        CLI.expectSilentSuccess(try CLI.run(["emit", "agentFinished", "--source", "codex", "--argv-json", Payloads.codexNotify], home: f.dir.url), "notify")
        CLI.expectSilentSuccess(try CLI.run(["emit", "agentFinished", "--source", "codex", "--argv-json", Payloads.codexNotifyOther], home: f.dir.url), "other type")
        CLI.expectSilentSuccess(try CLI.run(["emit", "agentFinished", "--source", "codex", "--argv-json"], home: f.dir.url), "no payload")
        #expect(waitUntil { f.inbox.count == 2 })
        #expect(f.inbox.events.first?.sessionID == "thr_456")
        #expect(f.inbox.events.first?.title == "Rename the handler")
    }

    @Test func promptSnippetsOffWithholdsTheTitle() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        try FileManager.default.createDirectory(at: f.dir.paths.appSupport, withIntermediateDirectories: true)
        try Data("{\"version\":1,\"storePromptSnippets\":false}".utf8).write(to: f.dir.paths.settingsFile)
        CLI.expectSilentSuccess(try CLI.run(["emit", "agentStarted", "--source", "claude-code", "--stdin-json"], home: f.dir.url,
                                            stdin: .data(Data(Payloads.claudePrompt.utf8))), "snippets off")
        CLI.expectSilentSuccess(try CLI.run(["emit", "commandStarted", "--source", "shell", "--session", "1", "--title", "make"], home: f.dir.url), "shell")
        #expect(waitUntil { f.inbox.count == 2 })
        // The agent's last message and what it asks to run are withheld the same way (SPEC §3.9).
        CLI.expectSilentSuccess(try CLI.run(["emit", "agentFinished", "--source", "claude-code", "--stdin-json"], home: f.dir.url,
                                            stdin: .data(Data(Payloads.claudeStop.utf8))), "stop, snippets off")
        CLI.expectSilentSuccess(try CLI.run(["emit", "agentNeedsUser", "--source", "claude-code", "--stdin-json"], home: f.dir.url,
                                            stdin: .data(Data(Payloads.claudePermission.utf8))), "permission, snippets off")
        #expect(waitUntil { f.inbox.count == 4 })
        #expect(f.inbox.events[0].title == nil)
        #expect(f.inbox.events[0].sessionID == "abc123")
        #expect(f.inbox.events[1].title == "make")
        #expect(f.inbox.events[2].message == nil && f.inbox.events[2].kind == .agentFinished)
        #expect(f.inbox.events[3].message == nil && f.inbox.events[3].tool == .command)
    }

    @Test func messagesTravelWithSnippetsOn() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        CLI.expectSilentSuccess(try CLI.run(["emit", "agentFinished", "--source", "claude-code", "--stdin-json"], home: f.dir.url,
                                            stdin: .data(Data(Payloads.claudeStop.utf8))), "stop")
        CLI.expectSilentSuccess(try CLI.run(["emit", "agentFinished", "--source", "claude-code", "--detail", "error", "--stdin-json"],
                                            home: f.dir.url, stdin: .data(Data(Payloads.claudeStopFailure.utf8))), "stop failure")
        CLI.expectSilentSuccess(try CLI.run(["emit", "commandFinished", "--source", "shell", "--session", "7", "--title", "swift",
                                             "--duration-ms", "241000", "--exit-code", "1"], home: f.dir.url), "shell")
        #expect(waitUntil { f.inbox.count == 3 })
        #expect(f.inbox.events[0].message == "I've completed the refactoring...")
        #expect(f.inbox.events[1].reason == "rate_limit" && f.inbox.events[1].message == nil && f.inbox.events[1].detail == "error")
        #expect(f.inbox.events[2].durationMS == 241_000 && f.inbox.events[2].exitCode == 1 && f.inbox.events[2].message == nil)
    }

    @Test func installedHookCommandRunsThroughTheShell() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        let command = HookCommand.shell(.agentStarted, source: .claudeCode)
        // Without the CLI copy: a silent no-op.
        let missing = try CLI.run(["-c", command], home: f.dir.url, stdin: .data(Data(Payloads.claudePrompt.utf8)),
                                  executable: URL(fileURLWithPath: "/bin/sh"))
        CLI.expectSilentSuccess(missing, "hook without CLI")
        // With the copy that `install` makes.
        try CLIInstaller(paths: f.dir.paths, bundledCLI: CLI.binary).install()
        let present = try CLI.run(["-c", command], home: f.dir.url, stdin: .data(Data(Payloads.claudePrompt.utf8)),
                                  executable: URL(fileURLWithPath: "/bin/sh"))
        CLI.expectSilentSuccess(present, "hook with CLI")
        #expect(waitUntil { f.inbox.count == 1 })
        #expect(f.inbox.events.first?.kind == .agentStarted)
    }

    /// The app's check after Install (§5.6): the hook command form, run the way a tool runs it,
    /// delivers a `test` event for each tool once the CLI copy is in place, and nothing without it.
    @Test func installCheckRunsTheHookCommandEndToEnd() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        let environment = ["BREAKPOINT_HOME": f.dir.url.path, "PATH": "/usr/bin:/bin", "CURSOR_VERSION": "1"]
        func runChecks() {
            for id in IntegrationID.allCases {
                let process = InstallCheck.hookProcess(for: id, paths: f.dir.paths, environment: environment)
                #expect(process.environment?["HOME"] == f.dir.url.path)
                try? process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0, "\(id.rawValue)")
            }
        }
        // No CLI copy yet: the hook form is a silent no-op, so nothing arrives.
        runChecks()
        Thread.sleep(forTimeInterval: 0.3)
        #expect(f.inbox.count == 0)
        #expect(!InstallCheck.cliRuns(paths: f.dir.paths))

        try CLIInstaller(paths: f.dir.paths, bundledCLI: CLI.binary).install()
        #expect(InstallCheck.cliRuns(paths: f.dir.paths))
        runChecks()
        #expect(waitUntil { f.inbox.count == IntegrationID.allCases.count })
        #expect(f.inbox.events.allSatisfy { $0.kind == .test })
        // Run from inside Cursor (CURSOR_VERSION), a test event still keeps its own source.
        #expect(Set(f.inbox.events.map(\.source)) == Set(IntegrationID.allCases.map(\.source)))
    }

    @Test func shellSnippetsSendCommandEventsEndToEnd() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        try CLIInstaller(paths: f.dir.paths, bundledCLI: CLI.binary).install()
        _ = try ShellIntegration(environment: IntegrationEnvironment(paths: f.dir.paths)).install()
        let zsh = """
        source "$HOME/.breakpoint/shell/breakpoint.zsh"
        __bp_preexec 'TOKEN="s e c" make -j8 test'
        __bp_t0=$(( EPOCHREALTIME - 3 ))
        false
        __bp_precmd
        print -r -- "status=$?"
        sleep 0.5
        """
        let zshResult = try CLI.run(["-f", "-i", "-c", zsh], home: f.dir.url, executable: URL(fileURLWithPath: "/bin/zsh"))
        #expect(zshResult.stdout.contains("status=1"), "\(zshResult.stdout) \(zshResult.stderr)")
        #expect(waitUntil { f.inbox.count == 2 })
        // Both are sent in the background, so they may arrive in either order.
        let zshEvents = f.inbox.events.sorted { $0.kind == .commandStarted && $1.kind != .commandStarted }
        #expect(zshEvents.map(\.kind) == [.commandStarted, .commandFinished])
        let folder = f.dir.url.lastPathComponent
        #expect(zshEvents.allSatisfy { $0.title == "make" && $0.source == .shell && $0.cwd?.hasSuffix("/" + folder) == true }, "\(zshEvents)")
        #expect(zshEvents.last?.exitCode == 1)
        #expect((zshEvents.last?.durationMS ?? 0) >= 2000)
        #expect(zshEvents.first?.sessionID == zshEvents.last?.sessionID)

        let bash = """
        source "$HOME/.breakpoint/shell/breakpoint.bash"
        __bp_preexec 'cargo build --release'
        __bp_t0=$(( __bp_t0 - 5000 ))
        false
        __bp_precmd
        echo "status=$?"
        sleep 0.5
        """
        let bashResult = try CLI.run(["--norc", "--noprofile", "-i", "-c", bash], home: f.dir.url, executable: URL(fileURLWithPath: "/bin/bash"))
        #expect(bashResult.stdout.contains("status=1"), "\(bashResult.stdout) \(bashResult.stderr)")
        #expect(waitUntil { f.inbox.count == 4 })
        let bashEvents = Array(f.inbox.events.dropFirst(2)).sorted { $0.kind == .commandStarted && $1.kind != .commandStarted }
        #expect(bashEvents.map(\.kind) == [.commandStarted, .commandFinished])
        #expect(bashEvents.allSatisfy { $0.title == "cargo" })
        #expect(bashEvents.last?.exitCode == 1)
    }

    @Test func emitIsFast() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        var times: [TimeInterval] = []
        for _ in 0..<15 {
            let result = try CLI.run(["emit", "agentStarted", "--source", "claude-code", "--stdin-json"], home: f.dir.url,
                                     stdin: .data(Data(Payloads.claudePrompt.utf8)))
            CLI.expectSilentSuccess(result, "timing")
            times.append(result.seconds)
        }
        times.sort()
        // Loose bound for a busy test machine; see the report for real measurements.
        #expect(times[times.count / 2] < 0.25, "median \(times[times.count / 2])")
    }
}

@Suite("breakpoint commands (subprocess)", .serialized)
struct CommandSubprocessTests {
    @Test func installUninstallInATemporaryHome() throws {
        try CLI.requireFreshBinary()
        let home = FakeHome()
        defer { home.cleanup() }
        home.write(".claude/settings.json", JSONToolCase.claude.rich)
        let install = try CLI.run(["install", "claude-code"], home: home.url)
        #expect(install.status == 0, "\(install.stderr)")
        #expect(install.stdout.contains("Claude Code: installed"))
        #expect(install.stdout.contains("backup"))
        #expect(FileManager.default.isExecutableFile(atPath: home.paths.cliCopy.path))
        #expect(home.read(".breakpoint/bin/.breakpoint-version") == BreakpointVersion.current + "\n")

        let again = try CLI.run(["install", "claude-code"], home: home.url)
        #expect(again.status == 0)
        #expect(again.stdout.contains("already installed"))

        let uninstall = try CLI.run(["uninstall", "claude-code"], home: home.url)
        #expect(uninstall.status == 0)
        #expect(home.read(".claude/settings.json") == JSONToolCase.claude.rich)
    }

    @Test func installAllSkipsToolsThatAreNotHere() throws {
        try CLI.requireFreshBinary()
        let home = FakeHome()
        defer { home.cleanup() }
        home.mkdir(".codex")
        home.write(".zshrc", "export A=1\n")
        let result = try CLI.run(["install", "all"], home: home.url, extraEnvironment: ["CODEX_HOME": "/should/not/be/used"])
        #expect(result.status == 0, "\(result.stdout) \(result.stderr)")
        #expect(result.stdout.contains("Cursor: not found on this Mac, skipped"))
        #expect(result.stdout.contains("Open /hooks in Codex"))
        #expect(home.exists(".codex/hooks.json"))
        #expect(!FileManager.default.fileExists(atPath: "/should/not/be/used"))
        #expect(home.read(".zshrc")!.contains(MarkerBlockEditor.beginMarker))
        let uninstall = try CLI.run(["uninstall", "all"], home: home.url)
        #expect(uninstall.status == 0)
        #expect(!home.exists(".codex/hooks.json"))
        #expect(home.read(".zshrc") == "export A=1\n")
    }

    @Test func errorsExitNonZeroWithAnExplanation() throws {
        try CLI.requireFreshBinary()
        let home = FakeHome()
        defer { home.cleanup() }
        let missing = try CLI.run(["install", "cursor"], home: home.url)
        #expect(missing.status == 1)
        #expect(missing.stderr.contains("Cursor was not found"))

        home.write(".claude/settings.json", "{ broken")
        let broken = try CLI.run(["install", "claude-code"], home: home.url)
        #expect(broken.status == 1)
        #expect(broken.stderr.contains("nothing was changed"))
        #expect(home.read(".claude/settings.json") == "{ broken")

        let unknown = try CLI.run(["install", "vscode"], home: home.url)
        #expect(unknown.status == 2)
        #expect(unknown.stderr.contains("Unknown tool"))
        #expect(try CLI.run(["install"], home: home.url).status == 2)
        #expect(try CLI.run(["frobnicate"], home: home.url).status == 2)
        let version = try CLI.run(["--version"], home: home.url)
        #expect(version.stdout == "breakpoint \(BreakpointVersion.current)\n")
    }

    @Test func statusAndDoctor() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture(start: false)
        defer { f.tearDown() }
        let notRunning = try CLI.run(["status"], home: f.dir.url)
        #expect(notRunning.status == 1)
        #expect(notRunning.stdout == "not running\n")
        let doctorDown = try CLI.run(["doctor"], home: f.dir.url)
        #expect(doctorDown.status == 1)
        #expect(doctorDown.stdout.contains("App is not running"))

        f.server.statusProvider = {
            StatusReport(generatedAt: Date(), lastEventBySource: [.claudeCode: Date().addingTimeInterval(-120)])
        }
        try f.server.start()
        let running = try CLI.run(["status"], home: f.dir.url)
        #expect(running.status == 0)
        #expect(running.stdout.contains("\"appVersion\""))

        let home = f.dir.url
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        #expect(try CLI.run(["install", "claude-code"], home: home).status == 0)
        let doctor = try CLI.run(["doctor"], home: home)
        #expect(doctor.status == 0, "\(doctor.stdout)")
        #expect(doctor.stdout.contains("App is running"))
        #expect(doctor.stdout.contains("Claude Code: connected, last event 2 min ago"))
        #expect(doctor.stdout.hasSuffix("Everything checks out.\n"))

        // An edited install is a problem doctor reports.
        try Data("{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"~/.breakpoint/bin/breakpoint emit agentFinished --source claude-code --x\"}]}]}}".utf8)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        let edited = try CLI.run(["doctor"], home: home)
        #expect(edited.status == 1)
        #expect(edited.stdout.contains("installed but edited"))
    }
}
