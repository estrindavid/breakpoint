import Foundation
import BreakpointCore

// The `breakpoint` command-line tool (SPEC §5.8). `emit` is handled
// before anything else can print or fail: it is silent and always exits 0 (SPEC §5.3).

Console.ignoreBrokenPipes()
Console.useLineFeeds()

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "emit" {
    Emit.run(CLIArguments.parseEmit(Array(arguments.dropFirst())))
}

let status: Int32
do {
    switch try CLIArguments.parse(arguments) {
    case .emit(let request):
        Emit.run(request)
    case .status:
        status = Commands.status()
    case .statusLine(let forceColour):
        status = StatusLineCommand.run(forceColour: forceColour)
    case .install(let ids, let all):
        status = Commands.install(ids, uninstall: false, all: all)
    case .uninstall(let ids, let all):
        status = Commands.install(ids, uninstall: true, all: all)
    case .doctor:
        status = Commands.doctor()
    case .debug(let rest):
        status = Commands.debug(rest)
    case .version:
        // A terminal gets the mark beside the version; a pipe gets "breakpoint <version>" alone.
        print(TerminalMark.versionOutput(version: BreakpointVersion.current, isTerminal: Console.stdoutIsTerminal,
                                         environment: ProcessInfo.processInfo.environment), terminator: "")
        status = 0
    case .help:
        print(CLIArguments.usage)
        status = 0
    case .updateRelaunch(let oldPID):
        let paths = BreakpointPaths.live()
        let outcome = UpdateRelauncher(file: PendingUpdate.file(paths)).run(oldPID: oldPID)
        status = outcome == .confirmed || outcome == .nothingPending ? 0 : 1
    }
} catch let error as CLIParseError {
    Commands.printError(error.description)
    status = 2
} catch {
    Commands.printError("\(error)")
    status = 2
}
exit(status)
