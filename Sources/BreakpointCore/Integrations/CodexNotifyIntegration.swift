import Foundation

/// Codex legacy `notify` (SPEC §5.5): one marked line in `$CODEX_HOME/config.toml`, placed among the
/// top-level keys (before the first `[table]`, or TOML would file it under that table). Refuses if
/// `notify` is already set (Breakpoint never chains it) or the Codex hooks integration is
/// installed. Codex runs the program directly (no shell) and appends one JSON argument.
public struct CodexNotifyIntegration: Integration {
    public let environment: IntegrationEnvironment
    public init(environment: IntegrationEnvironment) { self.environment = environment }
    public var id: IntegrationID { .codexNotify }
    public var toolFolder: URL { environment.codexHome }
    public var configFile: URL { toolFolder.appendingPathComponent("config.toml") }

    public func detect() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: toolFolder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `notify = ["<home>/.breakpoint/bin/breakpoint", "emit", "agentFinished", "--source", "codex", "--argv-json"]`
    public var notifyLine: String {
        let arguments = [environment.paths.cliCopy.path, "emit", AgentEventKind.agentFinished.rawValue, "--source",
                         AgentSource.codex.rawValue, "--argv-json"]
        return "notify = [" + arguments.map(TOMLScan.basicString).joined(separator: ", ") + "]"
    }

    var blockBody: String {
        "# Added by Breakpoint. Remove with: ~/.breakpoint/bin/breakpoint uninstall codex-notify\n" + notifyLine
    }

    private var file: ConfigFile { ConfigFile(url: configFile, tool: id, environment: environment) }

    public func status() -> IntegrationInstallState {
        guard detect() else { return .notFound }
        do {
            guard let text = try file.read() else { return .notInstalled }
            let body: String?
            do {
                body = try MarkerBlockEditor.body(in: text)
            } catch {
                return .unreadable(reason: "config.toml has a Breakpoint block with a missing marker line.")
            }
            do {
                _ = try TOMLScan.scan(MarkerBlockEditor.removeChecked(from: text))
            } catch let error as TOMLScan.SyntaxError {
                return .unreadable(reason: "config.toml could not be read (\(error.reason)).")
            }
            guard let body else { return .notInstalled }
            if body == blockBody { return .installed }
            return body.contains(".breakpoint/bin/breakpoint") && body.contains("--argv-json") ? .outdated : .modified
        } catch let error as IntegrationError {
            return .unreadable(reason: error.statusSentence)
        } catch {
            return .unreadable(reason: "config.toml could not be read.")
        }
    }

    public func install() throws -> InstallReport {
        guard detect() else { throw IntegrationError.toolNotFound(id) }
        if CodexIntegration(environment: environment).status().hasBreakpointEntries {
            throw IntegrationError.conflictsWith(.codex)
        }
        try environment.ensureCLICopy()
        let url = configFile
        var original: String?
        let change = try file.update { text in
            original = text
            let current = text ?? ""
            let base: String
            do {
                base = try MarkerBlockEditor.removeChecked(from: current)
            } catch {
                throw IntegrationError.unparseableFile(url, reason: "it has a Breakpoint block with a missing marker line")
            }
            let scan: TOMLScan.Result
            do {
                scan = try TOMLScan.scan(base)
            } catch let error as TOMLScan.SyntaxError {
                throw IntegrationError.unparseableFile(url, reason: error.reason)
            }
            if scan.topLevelKeys.contains("notify") { throw IntegrationError.notifyAlreadySet(url) }
            if (try? MarkerBlockEditor.body(in: current)) == blockBody { return current }
            if let offset = scan.insertionOffset {
                return MarkerBlockEditor.insert(body: blockBody, in: base, at: base.utf8.index(base.utf8.startIndex, offsetBy: offset))
            }
            return MarkerBlockEditor.upsert(body: blockBody, in: base)
        }
        if change != nil, original?.isBlank ?? true { file.remember(original: original) }
        return InstallReport(changedFiles: change.map { [$0.file] } ?? [], backups: change?.backup.map { [$0] } ?? [],
                             notes: ["Codex runs Breakpoint when a turn finishes. Restart open Codex sessions."])
    }

    public func uninstall() throws -> InstallReport {
        let url = configFile
        let record = file.ledgerRecord()
        let change = try file.update { text in
            guard let text else { return nil }
            let removed: String
            do {
                removed = try MarkerBlockEditor.removeChecked(from: text)
            } catch {
                throw IntegrationError.unparseableFile(url, reason: "it has a Breakpoint block with a missing marker line")
            }
            guard removed != text else { return text }
            if let record, record.hasOriginal, removed.isBlank { return record.original }
            return removed
        }
        if record != nil { file.forgetRecord() }
        return InstallReport(changedFiles: change.map { [$0.file] } ?? [], backups: change?.backup.map { [$0] } ?? [])
    }
}

/// Just enough TOML reading to place and find a top-level key safely: finds table headers and
/// top-level keys while skipping strings (including multi-line ones), arrays spanning lines and
/// comments, and rejects text that is clearly not TOML (unclosed strings or brackets, lines that
/// are neither `key = value`, `[table]`, a comment nor blank).
enum TOMLScan {
    struct SyntaxError: Error, Equatable {
        var message: String
        var line: Int
        var reason: String { "\(message) on line \(line)" }
    }

    struct Result: Equatable {
        /// Keys before the first table header, unquoted, dotted parts joined with ".".
        var topLevelKeys: [String]
        /// UTF-8 offset of the first table header line (moved up over comment lines directly
        /// above it), or nil when there is no table.
        var insertionOffset: Int?
    }

    static func basicString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func scan(_ text: String) throws -> Result {
        let b = Array(text.utf8)
        var i = 0
        var line = 1
        var keys: [String] = []
        var firstHeader: Int?
        var lastCommentRunStart: Int?   // start of a run of comment-only lines directly above

        func fail(_ message: String) -> SyntaxError { SyntaxError(message: message, line: line) }
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }
        func atEOL(_ j: Int) -> Bool { j >= b.count || b[j] == 0x0A || (b[j] == 0x0D && j + 1 < b.count && b[j + 1] == 0x0A) }

        func skipToEOL() { while i < b.count, b[i] != 0x0A { i += 1 } }
        func endLine() throws {
            while i < b.count, isSpace(b[i]) { i += 1 }
            if i < b.count, b[i] == UInt8(ascii: "#") { skipToEOL() }
            if i < b.count, b[i] == 0x0D { i += 1 }
            guard atEOL(i) else { throw fail("unexpected text after a value") }
            if i < b.count { i += 1; line += 1 }
        }

        /// Scans a quoted string starting at `i` (on a quote). Returns its raw contents.
        func scanString() throws -> String {
            let quote = b[i]
            let triple = i + 2 < b.count && b[i + 1] == quote && b[i + 2] == quote
            if triple {
                i += 3
                while i + 2 < b.count || i < b.count {
                    if i + 2 < b.count, b[i] == quote, b[i + 1] == quote, b[i + 2] == quote {
                        i += 3
                        // Up to two more quotes may close the string.
                        while i < b.count, b[i] == quote { i += 1 }
                        return ""
                    }
                    if quote == UInt8(ascii: "\""), b[i] == UInt8(ascii: "\\") { i += 2; continue }
                    if b[i] == 0x0A { line += 1 }
                    i += 1
                }
                throw fail("a multi-line string is not closed")
            }
            i += 1
            let start = i
            while i < b.count {
                let c = b[i]
                if c == 0x0A { throw fail("a string is not closed") }
                if quote == UInt8(ascii: "\""), c == UInt8(ascii: "\\") { i += 2; continue }
                if c == quote {
                    let raw = String(decoding: b[start..<i], as: UTF8.self)
                    i += 1
                    return raw
                }
                i += 1
            }
            throw fail("a string is not closed")
        }

        func scanKey(terminator: UInt8) throws -> String {
            var parts: [String] = []
            var current = ""
            while i < b.count {
                let c = b[i]
                if c == terminator { break }
                if isSpace(c) { i += 1; continue }
                if c == UInt8(ascii: ".") { parts.append(current); current = ""; i += 1; continue }
                if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") { current += try scanString(); continue }
                let bare = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                    || c == UInt8(ascii: "_") || c == UInt8(ascii: "-")
                guard bare else { throw fail("a line that is not key = value") }
                current += String(UnicodeScalar(c))
                i += 1
            }
            guard i < b.count, b[i] == terminator else { throw fail("a line that is not key = value") }
            parts.append(current)
            guard !parts.contains(where: \.isEmpty) || parts.count == 1 else { throw fail("an empty key") }
            return parts.joined(separator: ".")
        }

        func scanValue() throws {
            while i < b.count, isSpace(b[i]) { i += 1 }
            guard !atEOL(i), b[i] != UInt8(ascii: "#") else { throw fail("a key without a value") }
            var depth = 0
            while i < b.count {
                let c = b[i]
                switch c {
                case UInt8(ascii: "\""), UInt8(ascii: "'"):
                    _ = try scanString()
                case UInt8(ascii: "["), UInt8(ascii: "{"):
                    depth += 1
                    i += 1
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                    guard depth >= 0 else { throw fail("an unmatched bracket") }
                    i += 1
                case UInt8(ascii: "#"):
                    if depth == 0 { return }
                    skipToEOL()
                case 0x0A:
                    if depth == 0 { return }
                    line += 1
                    i += 1
                case 0x0D:
                    if depth == 0, i + 1 < b.count, b[i + 1] == 0x0A { return }
                    i += 1
                default:
                    i += 1
                }
            }
            if depth != 0 { throw fail("a list is not closed") }
        }

        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        while i < b.count {
            let lineStart = i
            while i < b.count, isSpace(b[i]) { i += 1 }
            if atEOL(i) {
                lastCommentRunStart = nil
                if i < b.count, b[i] == 0x0D { i += 1 }
                if i < b.count { i += 1; line += 1 }
                continue
            }
            if b[i] == UInt8(ascii: "#") {
                if lastCommentRunStart == nil { lastCommentRunStart = lineStart }
                skipToEOL()
                if i < b.count { i += 1; line += 1 }
                continue
            }
            if b[i] == UInt8(ascii: "[") {
                if firstHeader == nil { firstHeader = lastCommentRunStart ?? lineStart }
                let isArrayTable = i + 1 < b.count && b[i + 1] == UInt8(ascii: "[")
                i += isArrayTable ? 2 : 1
                _ = try scanKey(terminator: UInt8(ascii: "]"))
                i += 1
                if isArrayTable {
                    guard i < b.count, b[i] == UInt8(ascii: "]") else { throw fail("a table header is not closed") }
                    i += 1
                }
                lastCommentRunStart = nil
                try endLine()
                continue
            }
            lastCommentRunStart = nil
            let key = try scanKey(terminator: UInt8(ascii: "="))
            i += 1
            try scanValue()
            if firstHeader == nil { keys.append(key) }
            try endLine()
        }
        return Result(topLevelKeys: keys, insertionOffset: firstHeader)
    }
}
