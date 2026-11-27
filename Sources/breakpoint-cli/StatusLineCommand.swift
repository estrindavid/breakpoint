import Foundation
import BreakpointCore

// `breakpoint status --line` (SPEC §5.8). Made to be run by a prompt or a status bar on every
// draw: one status request with a short timeout, no files read, and nothing printed (exit 0) when
// the app is not running or does not answer in time.

enum StatusLineCommand {
    static func run(forceColour: Bool) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let socket = SocketPath(paths: .live(environment: environment))
        guard case .statusReply(let report)? = try? EventSocketClient.request(.statusRequest, to: socket,
                                                                             timeout: Timing.statusLineTimeout) else {
            return 0
        }
        print(StatusLine.render(report, colour: colour(force: forceColour, environment: environment)))
        return 0
    }

    /// The terminal's colour, as `--version` takes it (`NO_COLOR`, `TERM=dumb`); `--color` asks for
    /// it in a pipe too (an agent's status bar reads the command's output through one).
    static func colour(force: Bool, environment: [String: String]) -> TerminalMark.Colour? {
        if force {
            var environment = environment
            environment["NO_COLOR"] = nil
            if (environment["TERM"] ?? "").isEmpty || environment["TERM"] == "dumb" { environment["TERM"] = "xterm-256color" }
            return TerminalMark.colour(isTerminal: true, environment: environment)
        }
        return TerminalMark.colour(isTerminal: Console.stdoutIsTerminal, environment: environment)
    }
}
