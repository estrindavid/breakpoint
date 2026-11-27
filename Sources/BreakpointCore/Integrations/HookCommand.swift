import Foundation
#if os(Windows)
import WinSDK
#endif

/// The command strings Breakpoint writes into each tool's hook configuration (SPEC §5.2, §5.5).
///
/// **Keep these byte-for-byte stable across versions.** Codex records trust against a hash of each
/// hook definition, so any change to a command makes the user re-trust it in `/hooks`; the other
/// tools would only report "out of date". `HookCommandTests` pins the exact strings.
///
/// macOS: one POSIX `sh` form that expands `$HOME` itself, the same for every home.
/// Windows: tools run hooks through PowerShell (Cursor, Codex, Gemini CLI, Copilot CLI) or Git
/// Bash, else PowerShell (Claude Code), and some fall back to `cmd`. The one form all three parse
/// is a bare program path with forward slashes and no quotes, so the command names the CLI copy
/// by its absolute path (`C:/Users/x/.breakpoint/bin/breakpoint.exe emit …`). A home with a space
/// in its name is written in its 8.3 short form. There is no portable "missing binary is a
/// no-op" wrapper; `emit` itself prints nothing and always exits 0 (SPEC §5.3).
public enum HookCommand {
    /// The CLI path as written in shell-form hooks (expanded by the shell; no spaces). macOS.
    public static let shellBinary = "$HOME/.breakpoint/bin/breakpoint"

    /// The CLI path as hooks write it for `paths`: `shellBinary` on macOS, the absolute
    /// forward-slash path of `paths.cliCopy` on Windows.
    public static func binary(_ paths: BreakpointPaths) -> String {
        #if os(Windows)
        return windowsHome(paths) + "/.breakpoint/bin/" + BreakpointPaths.cliFileName
        #else
        return shellBinary
        #endif
    }

    /// macOS: `[ -x "$HOME/.breakpoint/bin/breakpoint" ] && "$HOME/.breakpoint/bin/breakpoint" emit <kind>
    /// --source <source> [extra…] --stdin-json >/dev/null 2>&1 || true` — a missing binary is a
    /// silent no-op, output is discarded and the exit status is always 0.
    ///
    /// Windows: `C:/Users/x/.breakpoint/bin/breakpoint.exe emit <kind> --source <source> [extra…]
    /// --stdin-json`.
    public static func shell(_ kind: AgentEventKind, source: AgentSource, extra: [String] = [], paths: BreakpointPaths) -> String {
        let arguments = (["emit", kind.rawValue, "--source", source.rawValue] + extra + ["--stdin-json"]).joined(separator: " ")
        #if os(Windows)
        return "\(binary(paths)) \(arguments)"
        #else
        return "[ -x \"\(shellBinary)\" ] && \"\(shellBinary)\" \(arguments) >/dev/null 2>&1 || true"
        #endif
    }

    /// The macOS form of a Windows hook command, with the same arguments; nil for anything else.
    public static func posixForm(of command: String) -> String? {
        guard let range = command.range(of: "/.breakpoint/bin/breakpoint.exe ") else { return nil }
        return "[ -x \"\(shellBinary)\" ] && \"\(shellBinary)\" \(command[range.upperBound...]) >/dev/null 2>&1 || true"
    }

    #if os(Windows)
    /// The home folder as hooks write it: forward slashes, no trailing slash, and the 8.3 short
    /// name when the long one has a space (when the volume keeps short names).
    static func windowsHome(_ paths: BreakpointPaths) -> String {
        var home = PathDisplay.native(paths.home)
        if home.contains(" "), let short = shortPath(home) { home = short }
        home = home.replacingOccurrences(of: "\\", with: "/")
        while home.count > 3, home.hasSuffix("/") { home.removeLast() }
        return home
    }

    private static func shortPath(_ path: String) -> String? {
        path.withCString(encodedAs: UTF16.self) { long -> String? in
            let needed = GetShortPathNameW(long, nil, 0)
            guard needed > 0 else { return nil }
            var buffer = [WCHAR](repeating: 0, count: Int(needed))
            let written = GetShortPathNameW(long, &buffer, needed)
            guard written > 0, written < needed else { return nil }
            let short = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
            return short.contains(" ") ? nil : short
        }
    }
    #endif
}

/// Identifies Breakpoint's own hook entries for one source (SPEC §5.5 "Marker"): the command runs
/// `…/.breakpoint/bin/breakpoint … emit …` with `--source <source>`. JSON has no comments, so the
/// command string is the marker. (On Windows the path ends in `breakpoint.exe`; the marker still
/// matches.)
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
