import Foundation

/// The command strings Breakpoint writes into each tool's hook configuration (SPEC §5.2, §5.5).
///
/// **Keep these byte-for-byte stable across versions.** Codex records trust against a hash of each
/// hook definition, so any change to a command makes the user re-trust it in `/hooks`; the other
/// tools would only report "out of date". `HookCommandTests` pins the exact strings.
public enum HookCommand {
    /// The CLI path as written in shell-form hooks (expanded by the shell; no spaces).
    public static let shellBinary = "$HOME/.breakpoint/bin/breakpoint"

    /// `[ -x "$HOME/.breakpoint/bin/breakpoint" ] && "$HOME/.breakpoint/bin/breakpoint" emit <kind>
    /// --source <source> [extra…] --stdin-json >/dev/null 2>&1 || true` — a missing binary is a
    /// silent no-op, output is discarded and the exit status is always 0.
    public static func shell(_ kind: AgentEventKind, source: AgentSource, extra: [String] = []) -> String {
        let arguments = (["emit", kind.rawValue, "--source", source.rawValue] + extra + ["--stdin-json"]).joined(separator: " ")
        return "[ -x \"\(shellBinary)\" ] && \"\(shellBinary)\" \(arguments) >/dev/null 2>&1 || true"
    }
}

/// Identifies Breakpoint's own hook entries for one source (SPEC §5.5 "Marker"): the command runs
/// `…/.breakpoint/bin/breakpoint … emit …` with `--source <source>`. JSON has no comments, so the
/// command string is the marker.
public struct HookMarker: Equatable, Sendable {
    public let source: AgentSource

    public init(source: AgentSource) { self.source = source }

    static let binaryFragment = "/.breakpoint/bin/breakpoint"

    /// True when `command` is one of Breakpoint's hooks for `source`.
    public func matches(_ command: String) -> Bool {
        guard command.contains(Self.binaryFragment), command.contains(" emit ") else { return false }
        return Self.sourceArgument(in: command) == source.rawValue
    }

    /// The value after `--source` (or `--source=`), if any.
    static func sourceArgument(in command: String) -> String? {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"';&|<>"))
        var rest = Substring(command)
        while let range = rest.range(of: "--source") {
            var after = rest[range.upperBound...]
            if after.first == "=" {
                after = after.dropFirst()
            } else if let first = after.first, first == " " || first == "\t" {
                after = after.drop { $0 == " " || $0 == "\t" }
            } else {
                rest = after
                continue
            }
            let value = after.prefix { !$0.unicodeScalars.contains(where: separators.contains) }
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }
}
