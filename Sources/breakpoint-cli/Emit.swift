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

    /// Points stdout and stderr at /dev/null, so not even a runtime warning can reach the hook.
    static func silenceOutput() {
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard null >= 0 else { return }
        dup2(null, STDOUT_FILENO)
        dup2(null, STDERR_FILENO)
        if null > STDERR_FILENO { close(null) }
    }

    /// "Keep prompt snippets" (SPEC §3.9), read without side effects; on when unreadable.
    static func storePromptSnippets(_ paths: BreakpointPaths) -> Bool {
        guard let data = try? Data(contentsOf: paths.settingsFile, options: [.uncached]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["storePromptSnippets"] as? Bool else { return true }
        return value
    }

    /// Reads stdin to EOF, at most `limit` bytes, giving up after `timeout` seconds in total.
    /// Never blocks longer than `timeout`, never reads a terminal, never changes stdin's flags
    /// (the descriptor is shared with the hook runner). Returns what was read (or nil).
    static func readStdin(limit: Int, timeout: TimeInterval) -> Data? {
        let fd = STDIN_FILENO
        guard isatty(fd) == 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            let remainingMS = Int32((deadline.timeIntervalSinceNow * 1000).rounded(.up))
            if remainingMS <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, remainingMS)
            if ready < 0, errno == EINTR { continue }
            if ready <= 0 { break }
            if pfd.revents & Int16(POLLNVAL) != 0 { break }
            // poll said readable (or hung up), so this read does not block.
            let count = read(fd, &buffer, min(buffer.count, limit - data.count))
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                break  // EOF
            } else if errno != EAGAIN && errno != EINTR {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}
