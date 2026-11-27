import Foundation
import BreakpointCore

// Socket commands (`WireMessage.command`) and the socket's start-up problems.
//
// - `activate`: sent by a second copy of the app that found this one already answering on the
//   socket; this copy shows its popover and the second copy quits.
// - `signals`: the activity monitor's diagnostic report, printed by `breakpoint doctor`.
// - `debug …`: the end-to-end harness (debug builds only; see DebugHarness.swift and CLAUDE.md).

extension AppCoordinator {
    func handleCommand(_ name: String, arguments: [String]) -> String {
        switch name {
        case "activate":
            showPopover()
            return "ok"
        case "signals":
            return signalReport()
        case "debug":
            #if DEBUG
            return harness?.handle(arguments) ?? "The debug harness is not running."
            #else
            return "Debug commands are only available in debug builds."
            #endif
        default:
            return "Unknown command \(name)."
        }
    }

    /// The activity monitor's plain-text report of every signal it reads (no names).
    func signalReport() -> String {
        #if DEBUG
        if let report = harness?.simulatedSignalReport(now: currentDate()) { return report }
        #endif
        let report = monitor.diagnosticReport()
        return report.isEmpty ? "Signals are not available." : report
    }

    // MARK: - Start-up problems with the socket (§5.1)

    /// Another copy of Breakpoint already answers on this home's socket: ask it to show itself,
    /// then quit quietly without having shown or written anything.
    func handOverToRunningCopy() {
        log.info("Another copy of Breakpoint is running; handing over to it")
        _ = try? EventSocketClient.request(.command(name: "activate", arguments: []), to: server.socketPath, timeout: 1)
        #if DEBUG
        harness?.recorder.note("handed over to the running copy; quitting")
        #endif
        exit(0)
    }

    /// One sentence for the user about why the socket could not be opened.
    static func describeSocketProblem(_ error: Error) -> String {
        switch error {
        case SocketServerError.pathOccupied(let path):
            return "Something other than Breakpoint is in the way at \(path), so Breakpoint can't hear from your coding tools. Move that item elsewhere, then quit and reopen Breakpoint."
        case SocketServerError.pathTooLong(let path):
            return "The path \(path) is too long for Breakpoint's connection, so it can't hear from your coding tools."
        case SocketServerError.system(let call, let code):
            return "Breakpoint couldn't open its connection for your coding tools (\(call): \(SystemErrorText.describe(code))). Quit and reopen Breakpoint; `breakpoint doctor` shows more."
        default:
            return "Breakpoint couldn't open its connection for your coding tools. Quit and reopen Breakpoint; `breakpoint doctor` shows more."
        }
    }

    /// Tells the user once, after launch, without stopping the app: breaks still work, only the
    /// tool events are missing.
    func reportSocketProblem(_ sentence: String) {
        if isHeadless {
            recordSurface("alert: \(sentence)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.platform.alert(title: "Breakpoint can't hear from your coding tools",
                                 message: sentence + "\n\nBreaks offered while you pause typing still work in the meantime.")
        }
    }
}
