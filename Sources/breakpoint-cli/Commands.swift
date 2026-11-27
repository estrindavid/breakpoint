import Foundation
import BreakpointCore

// SPEC §5.8: status, install, uninstall and doctor print
// human-readable text and may exit non-zero.

enum Commands {
    static var processEnvironment: [String: String] { ProcessInfo.processInfo.environment }
    static var paths: BreakpointPaths { .live(environment: processEnvironment) }

    /// The running executable, for copying to `~/.breakpoint/bin/breakpoint`.
    static var executable: URL {
        if let path = Bundle.main.executablePath { return URL(fileURLWithPath: path).resolvingSymlinksInPath() }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    static var environment: IntegrationEnvironment {
        IntegrationEnvironment(paths: paths, codexHomeOverride: codexHomeSetting(),
                               processEnvironment: processEnvironment, bundledCLI: executable)
    }

    /// `Settings.codexHome`, read without side effects (the app owns settings.json).
    static func codexHomeSetting() -> String? {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["codexHome"] as? String
    }

    static func display(_ url: URL) -> String { PathDisplay.abbreviatingHome(url.path, home: paths.home.path) }

    // MARK: status

    /// `breakpoint status`: the app's status as pretty JSON, or "not running" (exit 1).
    static func status() -> Int32 {
        do {
            let reply = try EventSocketClient.request(.statusRequest, to: SocketPath(paths: paths))
            guard case .statusReply(let report) = reply else {
                printError("The app sent an unexpected reply.")
                return 1
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
            return 0
        } catch SocketClientError.timedOut {
            print("not responding")
            return 1
        } catch {
            print("not running")
            return 1
        }
    }

    // MARK: install / uninstall

    /// `breakpoint install <tool>` / `uninstall <tool>`. `all` skips tools that are not on this Mac.
    static func install(_ ids: [IntegrationID], uninstall: Bool, all: Bool) -> Int32 {
        let environment = environment
        var failed = false
        for id in ids {
            let integration = IntegrationRegistry.integration(id, environment: environment)
            if all, !integration.detect() {
                print("\(id.displayName): not found on this \(BreakpointPlatform.computerName), skipped")
                continue
            }
            do {
                let report = uninstall ? try integration.uninstall() : try integration.install()
                print(summary(id, report: report, uninstall: uninstall))
                for file in report.changedFiles { print("  changed \(display(file))") }
                for backup in report.backups { print("  backup  \(display(backup))") }
                report.notes.forEach { print("  \($0)") }
            } catch let error as IntegrationError {
                failed = true
                printError("\(id.displayName): \(error.explanation)")
            } catch {
                failed = true
                printError("\(id.displayName): \(error.localizedDescription)")
            }
        }
        if !uninstall, !failed, FileManager.default.isExecutableFile(atPath: paths.cliCopy.path) {
            print("Hooks call \(display(paths.cliCopy)).")
        }
        return failed ? 1 : 0
    }

    static func summary(_ id: IntegrationID, report: InstallReport, uninstall: Bool) -> String {
        if report.changedFiles.isEmpty {
            return "\(id.displayName): \(uninstall ? "not installed, nothing to remove" : "already installed, nothing changed")"
        }
        return "\(id.displayName): \(uninstall ? "removed" : "installed")"
    }

    // MARK: doctor

    /// `breakpoint doctor`: socket, app, CLI copy, each integration and its last event. Exits 1 when
    /// something needs attention (app not running, socket permissions, CLI copy missing or stale
    /// while an integration is installed, an integration that is unreadable, outdated or edited).
    static func doctor() -> Int32 {
        var problems = 0
        func line(_ ok: Bool?, _ text: String) {
            let mark = ok.map { $0 ? "ok  " : "!!  " } ?? "    "
            if ok == false { problems += 1 }
            print(mark + text)
        }
        let paths = self.paths
        let socket = SocketPath(paths: paths)
        print("Breakpoint \(BreakpointVersion.current), home \(paths.home.path)")

        // Socket and app.
        var lastEvents: [AgentSource: Date] = [:]
        var running = false
        do {
            if case .statusReply(let report) = try EventSocketClient.request(.statusRequest, to: socket) {
                running = true
                lastEvents = report.lastEventBySource
                line(true, "App is running (version \(report.appVersion))")
            }
        } catch SocketClientError.timedOut {
            line(false, "App is not responding on the socket")
        } catch {
            line(false, "App is not running")
        }
        let socketDescription = display(socket.url) + (socket.isFallback ? " (short fallback path)" : "")
        #if os(Windows)
        // Windows: an AF_UNIX socket file is a reparse point; its folder's ACL is the user's own.
        if socket.exists {
            let isSocket = socket.isSocketFile
            line(isSocket, "Socket \(socketDescription)" + (isSocket ? "" : ", not a socket"))
        } else {
            line(running ? false : nil, "Socket \(socketDescription) does not exist")
        }
        #else
        var info = stat()
        if lstat(socket.path, &info) == 0 {
            let isSocket = info.st_mode & S_IFMT == S_IFSOCK
            let mode = info.st_mode & 0o777
            line(isSocket && mode & 0o077 == 0 && info.st_uid == getuid(),
                 "Socket \(socketDescription), mode \(String(mode, radix: 8))" + (isSocket ? "" : ", not a socket"))
        } else {
            line(running ? false : nil, "Socket \(socketDescription) does not exist")
        }
        var dirInfo = stat()
        if stat(socket.directory.path, &dirInfo) == 0 {
            let mode = dirInfo.st_mode & 0o777
            line(mode & 0o077 == 0, "Socket folder mode \(String(mode, radix: 8))")
        }
        #endif

        // Integrations.
        let environment = environment
        var anyInstalled = false
        var rows: [(IntegrationID, IntegrationInstallState)] = []
        for id in IntegrationID.allCases {
            let state = IntegrationRegistry.integration(id, environment: environment).status()
            anyInstalled = anyInstalled || state.hasBreakpointEntries
            rows.append((id, state))
        }

        // CLI copy.
        let cli = CLIInstaller(paths: paths, bundledCLI: executable)
        if cli.isInstalled {
            let version = cli.installedVersion ?? "unknown"
            line(version == BreakpointVersion.current, "CLI copy \(display(paths.cliCopy)) (version \(version))")
        } else {
            line(anyInstalled ? false : nil, "CLI copy \(display(paths.cliCopy)) is not installed")
        }

        for (id, state) in rows {
            let text = "\(id.displayName): \(describe(state, lastEvent: lastEvents[id.source], id: id))"
            switch state {
            case .unreadable, .outdated, .modified: line(false, text)
            case .installed:
                // The CLI copy has its own line above; a tool setting that turns hooks off is the
                // other thing the app checks on disk (`InstallCheck`).
                if let problem = InstallCheck.toolProblem(for: id, environment: environment) {
                    line(false, "\(id.displayName): \(problem)")
                } else {
                    line(true, text)
                }
            case .notFound, .notInstalled: line(nil, text)
            }
        }
        // The signals the running app reads (idle time, lock and sleep, camera, one name-free
        // line per audio device and the microphone decision). The app reads them: the CLI does not
        // link AppKit, CoreAudio or CoreMediaIO.
        print("")
        if running, case .reply(let report)? = try? EventSocketClient.request(.command(name: "signals", arguments: []), to: socket) {
            print(report)
        } else {
            print("Signals: the app is not running. `Breakpoint --signals` (the app's executable) prints them on its own.")
        }
        print("")
        print(problems == 0 ? "Everything checks out." : "\(problems) problem\(problems == 1 ? "" : "s") found.")
        return problems == 0 ? 0 : 1
    }

    // MARK: debug

    /// `breakpoint debug …`: sends the arguments to the app's end-to-end harness and prints the
    /// reply. Exits 1 when the app is not running or the reply starts with "error".
    static func debug(_ arguments: [String]) -> Int32 {
        do {
            let reply = try EventSocketClient.request(.command(name: "debug", arguments: arguments),
                                                      to: SocketPath(paths: paths), timeout: 60)
            guard case .reply(let text) = reply else {
                printError("The app sent an unexpected reply.")
                return 1
            }
            print(text)
            return text.hasPrefix("error") ? 1 : 0
        } catch {
            printError("not running")
            return 1
        }
    }

    static func describe(_ state: IntegrationInstallState, lastEvent: Date?, id: IntegrationID) -> String {
        switch state {
        case .notFound: return "not found on this \(BreakpointPlatform.computerName)"
        case .notInstalled: return "not installed"
        case .unreadable(let reason): return reason
        case .outdated: return "installed by another version; run `breakpoint install \(id.rawValue)` to update"
        case .modified: return "installed but edited; run `breakpoint install \(id.rawValue)` to restore"
        case .installed:
            // The last event is information: an install that reads back is connected.
            guard let lastEvent else {
                return id == .codex ? "connected; Codex runs the hooks once you trust them in /hooks" : "connected"
            }
            let minutes = Int(max(0, Date().timeIntervalSince(lastEvent)) / 60)
            return "connected, last event \(minutes == 0 ? "just now" : "\(minutes) min ago")"
        }
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
