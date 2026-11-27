import Foundation
import BreakpointCore

// SPEC §5.3: `emit` prints nothing, always exits 0, reads stdin to
// EOF (1 MB cap, 250 ms total) with --stdin-json, writes one line with a 100 ms timeout, never
// waits for a reply, starts no child process.

enum Emit {
    /// Runs `emit` and never returns. Exit status is always 0.
    static func run(_ request: EmitRequest?) -> Never {
        // Nothing may reach the hook's stdout or stderr, whatever happens below.
        silenceOutput()
        guard var request else { exit(0) }
        if request.payloadMode == .stdinJSON {
            request.payload = readStdin(limit: EmitRequest.maxPayloadBytes, timeout: EmitRequest.stdinTimeout)
        }
        let environment = ProcessInfo.processInfo.environment
        let paths = BreakpointPaths.live(environment: environment)
        if var event = HookPayloadParser.event(from: request, environment: environment, now: Date()) {
            // The settings file is read only when there is a prompt snippet or a message to withhold.
            if event.title != nil || event.message != nil, !event.kind.isCommandEvent, event.source != .shell,
               !storePromptSnippets(paths) {
                event.title = nil
                event.message = nil
            }
            _ = EventSocketClient.send(.event(event), to: SocketPath(paths: paths), timeout: 0.1)
        }
        exit(0)
    }

    /// Points stdout and stderr at the null device, so not even a runtime warning can reach the hook.
    static func silenceOutput() { Console.silenceOutput() }

    /// "Keep prompt snippets" (SPEC §3.9), read without side effects; on when unreadable.
    static func storePromptSnippets(_ paths: BreakpointPaths) -> Bool {
        guard let data = try? Data(contentsOf: paths.settingsFile, options: [.uncached]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["storePromptSnippets"] as? Bool else { return true }
        return value
    }

    /// Reads stdin to EOF, at most `limit` bytes, giving up after `timeout` seconds in total.
    static func readStdin(limit: Int, timeout: TimeInterval) -> Data? {
        Console.readStdin(limit: limit, timeout: timeout)
    }
}
