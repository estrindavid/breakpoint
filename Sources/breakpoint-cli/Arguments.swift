import Foundation
import BreakpointCore

// SPEC §5.8.

/// A parsed command line.
enum CLICommand: Equatable {
    /// `emit` always parses to this; `nil` request = unusable arguments (still silent, exit 0).
    case emit(EmitRequest?)
    case status
    /// `status --line [--color]`: one short line for a prompt or status bar; `forceColour` colours
    /// it even when standard output is not a terminal (an agent's status bar, tmux).
    case statusLine(forceColour: Bool)
    /// `all` = the tool argument was "all" (tools not on this Mac are skipped).
    case install([IntegrationID], all: Bool)
    case uninstall([IntegrationID], all: Bool)
    case doctor
    /// `debug …` (debug builds only): the end-to-end harness's commands, sent to a debug app.
    case debug([String])
    case version
    case help
    /// `update-relaunch --pid N`: run by the app itself during an in-place update (SPEC §2.11);
    /// not listed in the help.
    case updateRelaunch(oldPID: Int32)
}

enum CLIParseError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case missingTool(String)
    case unknownTool(String)
    case badOption(String)

    var description: String {
        switch self {
        case .unknownCommand(let command): return "Unknown command \"\(command)\". Run `breakpoint help`."
        case .missingTool(let command): return "`breakpoint \(command)` needs a tool: \(CLIArguments.toolList)."
        case .unknownTool(let tool): return "Unknown tool \"\(tool)\". Choose one of: \(CLIArguments.toolList)."
        case .badOption(let option): return "Unknown option \"\(option)\" for `breakpoint status`. Run `breakpoint help`."
        }
    }
}

enum CLIArguments {
    static let toolList = (IntegrationID.allCases.map(\.rawValue) + ["all"]).joined(separator: " | ")

    static let usage = """
    Usage:
      breakpoint emit <kind> --source S [--session ID] [--cwd PATH] [--title TEXT] [--detail TEXT]
                      [--duration-ms N] [--exit-code N] [--stdin-json | --argv-json]
      breakpoint status              Print the app's status, or "not running"
      breakpoint status --line       One short line for a prompt or status bar ("stretch due · Claude
                [--color]            working 3 min"); prints nothing when the app is not running.
                                     Coloured on a terminal; --color colours it in a pipe too
      breakpoint install <tool>      \(toolList)
      breakpoint uninstall <tool>
      breakpoint doctor              Check the socket, the app, the CLI copy, each integration and
                                     the signals the app reads
      breakpoint --version

    Set BREAKPOINT_HOME=/some/folder to use that folder as the home directory (for testing).
    """

    /// Parses `arguments` (without the program name).
    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "emit": return .emit(parseEmit(rest))
        case "status": return try status(rest)
        case "doctor": return .doctor
        #if DEBUG
        case "debug": return .debug(rest)
        #endif
        case "install": return .install(try tools(rest, command: command), all: rest.first == "all")
        case "uninstall": return .uninstall(try tools(rest, command: command), all: rest.first == "all")
        case "--version", "version": return .version
        case "help", "--help", "-h": return .help
        case "update-relaunch":
            guard rest.count == 2, rest[0] == "--pid", let pid = Int32(rest[1]), pid > 0 else {
                throw CLIParseError.unknownCommand(command)
            }
            return .updateRelaunch(oldPID: pid)
        default: throw CLIParseError.unknownCommand(command)
        }
    }

    private static func status(_ rest: [String]) throws -> CLICommand {
        guard !rest.isEmpty else { return .status }
        var line = false, colour = false
        for option in rest {
            switch option {
            case "--line": line = true
            case "--color", "--colour": colour = true
            default: throw CLIParseError.badOption(option)
            }
        }
        guard line else { throw CLIParseError.badOption(rest[0]) }
        return .statusLine(forceColour: colour)
    }

    private static func tools(_ rest: [String], command: String) throws -> [IntegrationID] {
        guard let tool = rest.first else { throw CLIParseError.missingTool(command) }
        if tool == "all" { return command == "uninstall" ? IntegrationID.allCases : IntegrationID.settingsRows }
        guard let id = IntegrationID(rawValue: tool) else { throw CLIParseError.unknownTool(tool) }
        return [id]
    }

    /// `emit <kind> --source S …`. Returns `nil` when the kind or source is missing or unknown;
    /// unknown flags are ignored (hooks must never fail). Flags take `--flag value` or
    /// `--flag=value`. With `--argv-json` the last argument is the payload (Codex `notify`), not a
    /// flag value.
    static func parseEmit(_ rest: [String]) -> EmitRequest? {
        guard let rawKind = rest.first, let kind = AgentEventKind(rawValue: rawKind) else { return nil }
        var args = Array(rest.dropFirst())
        var payload: Data?
        var mode = EmitRequest.PayloadMode.none
        if args.contains("--argv-json") {
            mode = .argvJSON
            args.removeAll { $0 == "--argv-json" }
            if let last = args.last, last.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                payload = Data(last.utf8)
                args.removeLast()
            }
        } else if args.contains("--stdin-json") {
            mode = .stdinJSON
            args.removeAll { $0 == "--stdin-json" }
        }

        var values: [String: String] = [:]
        var i = 0
        while i < args.count {
            let argument = args[i]
            guard argument.hasPrefix("--") else {
                i += 1
                continue
            }
            if let equals = argument.firstIndex(of: "=") {
                values[String(argument[argument.index(argument.startIndex, offsetBy: 2)..<equals])] = String(argument[argument.index(after: equals)...])
                i += 1
            } else if i + 1 < args.count {
                values[String(argument.dropFirst(2))] = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        guard let source = values["source"]?.trimmingCharacters(in: .whitespaces), !source.isEmpty,
              source.count <= 64, !source.contains(where: { $0.isNewline }) else { return nil }
        return EmitRequest(
            kind: kind,
            source: AgentSource(source),
            sessionID: values["session"],
            cwd: values["cwd"],
            title: values["title"],
            detail: values["detail"],
            durationMS: values["duration-ms"].flatMap { Int($0) },
            exitCode: values["exit-code"].flatMap { Int($0) },
            payloadMode: mode,
            payload: payload)
    }
}
