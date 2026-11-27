import Foundation

/// Merges Breakpoint's hook entries into a tool's JSON settings without disturbing anything else
/// (SPEC §5.5).
///
/// Contract:
/// - Works on the file's text, not a re-serialised dictionary: foreign keys, entries, key order,
///   indentation and (where the format allows them) comments are preserved byte for byte outside
///   the inserted entries. An install followed by an uninstall restores the original bytes.
/// - `merge` makes each event hold exactly Breakpoint's entries for that event: events that already
///   match are left alone (idempotent); events holding older or edited Breakpoint entries get them
///   replaced; missing events are appended. Creates `hooks` / the event array when missing.
/// - `remove` deletes entries carrying the marker, then groups, arrays and a `hooks` object that
///   became empty because of it. Containers that were already empty are left alone.
/// - `state` reports how the file compares with the wanted entries (for `status()`).
/// - Throws `IntegrationError.unparseableFile` when the text is not a JSON object, has duplicate
///   `hooks` keys, or `hooks` / one of Breakpoint's event lists has the wrong type.
public enum JSONSettingsMerger {
    /// Where handlers sit in the file.
    public enum Layout: Sendable {
        /// `hooks.<Event>: [ { "matcher": …, "hooks": [handler, …] } ]` (Claude Code, Codex, Gemini).
        case grouped
        /// `hooks.<event>: [handler, …]` (Cursor, Copilot).
        case flat
    }

    /// One hook registration: the tool's event name, an optional matcher and the JSON object of
    /// the handler (in the tool's shape, e.g. `{"type":"command","command":"…","async":true}`).
    /// In the flat layout `matcher`, if any, belongs inside the handler and must be nil here.
    public struct HookEntry: Equatable, Sendable {
        public var event: String
        public var matcher: String?
        /// The handler object as JSON text.
        public var handlerJSON: String

        public init(event: String, matcher: String? = nil, handlerJSON: String) {
            self.event = event
            self.matcher = matcher
            self.handlerJSON = handlerJSON
        }

        init(event: String, matcher: String? = nil, handler: JValue) {
            self.event = event
            self.matcher = matcher
            self.handlerJSON = JSONRender.render(handler, indent: "", unit: "  ", newline: "\n", compact: true)
        }

        var handler: JValue { (try? JValue.parse(handlerJSON)) ?? .null }

        var command: String? { handler["command"]?.stringValue ?? handler["bash"]?.stringValue }
    }

    /// How a file compares with the entries Breakpoint wants.
    public enum State: Equatable, Sendable {
        /// No Breakpoint entries.
        case absent
        /// Exactly the wanted entries.
        case current
        /// Breakpoint entries that differ from the wanted ones, all with commands some version of
        /// Breakpoint writes (an older install).
        case outdated
        /// Breakpoint entries whose command was edited by hand.
        case modified
    }

    /// Options for one tool's file.
    public struct Format: Sendable {
        public var layout: Layout
        /// JSONC (`//` and `/* */`) is accepted (Gemini). Otherwise comments make the file unparseable.
        public var allowsComments: Bool
        /// Members written first when the file is empty or `{}` (Cursor: `"version": 1`).
        var skeleton: [JMember]

        public init(layout: Layout, allowsComments: Bool = false) {
            self.layout = layout
            self.allowsComments = allowsComments
            self.skeleton = []
        }

        init(layout: Layout, allowsComments: Bool = false, skeleton: [JMember]) {
            self.layout = layout
            self.allowsComments = allowsComments
            self.skeleton = skeleton
        }
    }

    /// A Breakpoint handler found in the file.
    struct Found {
        var event: String
        var groupIndex: Int
        /// Index inside the group's `hooks` (grouped layout only).
        var handlerIndex: Int?
        var matcher: String?
        var handler: JValue
        var command: String
    }

    // MARK: Public operations

    public static func merge(_ entries: [HookEntry], into text: String, marker: HookMarker, format: Format,
                             file: URL) throws -> String {
        var doc = try document(text.isBlank ? "{}\n" : text, format: format, file: file)
        if doc.root.members?.isEmpty == true {
            for member in format.skeleton {
                try edit(file) { try doc.appendMember(member.key, member.value, toObjectAt: []) }
            }
        }
        let wantedEvents = orderedEvents(entries)
        // Breakpoint entries on events it no longer uses.
        for event in Set(try found(in: doc, marker: marker, format: format, file: file).map(\.event)) where !wantedEvents.contains(event) {
            try removeMarked(in: &doc, event: event, marker: marker, format: format, file: file, dropEmptyEvent: true)
        }
        for event in wantedEvents {
            let wanted = entries.filter { $0.event == event }
            let present = try found(in: doc, marker: marker, format: format, file: file).filter { $0.event == event }
            if matches(present, wanted) { continue }
            try removeMarked(in: &doc, event: event, marker: marker, format: format, file: file, dropEmptyEvent: false)
            if doc.node(at: ["hooks"]) == nil {
                try edit(file) { try doc.appendMember("hooks", .object([]), toObjectAt: []) }
            }
            if doc.node(at: ["hooks", .key(event)]) == nil {
                try edit(file) { try doc.appendMember(event, .array([]), toObjectAt: ["hooks"]) }
            }
            for entry in wanted {
                let item: JValue
                switch format.layout {
                case .grouped:
                    var members: [JMember] = []
                    if let matcher = entry.matcher { members.append(JMember("matcher", .string(matcher))) }
                    members.append(JMember("hooks", .array([entry.handler])))
                    item = .object(members)
                case .flat:
                    item = entry.handler
                }
                try edit(file) { try doc.appendElement(item, toArrayAt: ["hooks", .key(event)]) }
            }
        }
        return doc.text
    }

    /// - Parameter keepEmpty: containers to leave in place even if empty ("hooks", "hooks/<event>"):
    ///   those that were already empty before Breakpoint added to them (see `emptyContainers`).
    public static func remove(marker: HookMarker, from text: String, format: Format, keepEmpty: Set<String> = [],
                              file: URL) throws -> String {
        guard !text.isBlank else { return text }
        var doc = try document(text, format: format, file: file)
        let events = Set(try found(in: doc, marker: marker, format: format, file: file).map(\.event))
        guard !events.isEmpty else { return text }
        for event in events.sorted() {
            try removeMarked(in: &doc, event: event, marker: marker, format: format, file: file,
                             dropEmptyEvent: !keepEmpty.contains("hooks/\(event)"))
        }
        if !keepEmpty.contains("hooks"), let hooks = doc.node(at: ["hooks"]), hooks.members?.isEmpty == true {
            try edit(file) { try doc.removeMember("hooks", fromObjectAt: []) }
        }
        return doc.text
    }

    public static func state(of text: String, wanted entries: [HookEntry], marker: HookMarker, format: Format,
                             recognizedCommands: Set<String>, file: URL) throws -> State {
        guard !text.isBlank else { return .absent }
        let doc = try document(text, format: format, file: file)
        for event in orderedEvents(entries) {
            if let value = doc.node(at: ["hooks", .key(event)]), !value.isArray {
                throw IntegrationError.unparseableFile(file, reason: "hooks.\(event) is not a list")
            }
        }
        let present = try found(in: doc, marker: marker, format: format, file: file)
        if present.isEmpty { return .absent }
        let known = recognizedCommands.union(entries.compactMap(\.command))
        if present.contains(where: { !known.contains($0.command) }) { return .modified }
        let events = Set(present.map(\.event)).union(entries.map(\.event))
        for event in events where !matches(present.filter { $0.event == event }, entries.filter { $0.event == event }) {
            return .outdated
        }
        return .current
    }

    /// The containers among `hooks` and `hooks/<event>` (for the wanted events) that exist and are
    /// empty, so uninstall can leave them as it found them.
    public static func emptyContainers(in text: String, wanted entries: [HookEntry], format: Format, file: URL) -> [String] {
        guard !text.isBlank, let doc = try? document(text, format: format, file: file),
              let hooks = doc.node(at: ["hooks"]) else { return [] }
        var result: [String] = []
        if hooks.members?.isEmpty == true { result.append("hooks") }
        for event in orderedEvents(entries) where doc.node(at: ["hooks", .key(event)])?.elements?.isEmpty == true {
            result.append("hooks/\(event)")
        }
        return result
    }

    public static func containsMarker(_ marker: String, in text: String) -> Bool {
        text.contains(marker)
    }

    // MARK: Internals

    static func document(_ text: String, format: Format, file: URL) throws -> JSONTextDocument {
        let doc: JSONTextDocument
        do {
            doc = try JSONTextDocument(text: text, allowComments: format.allowsComments)
        } catch let error as JSONSyntaxError {
            throw IntegrationError.unparseableFile(file, reason: error.reason)
        }
        guard let members = doc.root.members else {
            throw IntegrationError.unparseableFile(file, reason: "the top level is not a JSON object")
        }
        if members.filter({ $0.key == "hooks" }).count > 1 {
            throw IntegrationError.unparseableFile(file, reason: "\"hooks\" appears twice")
        }
        if let hooks = doc.node(at: ["hooks"]) {
            guard let hookMembers = hooks.members else {
                throw IntegrationError.unparseableFile(file, reason: "\"hooks\" is not an object")
            }
            let keys = hookMembers.map(\.key)
            if Set(keys).count != keys.count {
                throw IntegrationError.unparseableFile(file, reason: "an event appears twice in \"hooks\"")
            }
        }
        return doc
    }

    private static func edit(_ file: URL, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as JSONSyntaxError {
            // Never expected: our splices always produce valid JSON. Refuse rather than write.
            throw IntegrationError.unparseableFile(file, reason: "an internal edit failed (\(error.reason))")
        } catch is JSONEditError {
            throw IntegrationError.unparseableFile(file, reason: "the hooks are not laid out as expected")
        }
    }

    private static func orderedEvents(_ entries: [HookEntry]) -> [String] {
        var seen = Set<String>()
        return entries.map(\.event).filter { seen.insert($0).inserted }
    }

    /// Breakpoint's handlers in the file. Event values that are not lists are skipped for foreign
    /// events and refused for events Breakpoint has entries in.
    static func found(in doc: JSONTextDocument, marker: HookMarker, format: Format, file: URL) throws -> [Found] {
        guard let hooks = doc.node(at: ["hooks"])?.members else { return [] }
        var result: [Found] = []
        for event in hooks {
            guard let items = event.value.elements else { continue }
            for (groupIndex, item) in items.enumerated() {
                switch format.layout {
                case .flat:
                    if let command = commandOf(item.value), marker.matches(command) {
                        result.append(Found(event: event.key, groupIndex: groupIndex, handlerIndex: nil, matcher: nil,
                                            handler: item.value, command: command))
                    }
                case .grouped:
                    let group = item.value
                    guard case .array(let handlers)? = group["hooks"] else { continue }
                    let matcher = group["matcher"]?.stringValue
                    for (handlerIndex, handler) in handlers.enumerated() {
                        if let command = commandOf(handler), marker.matches(command) {
                            result.append(Found(event: event.key, groupIndex: groupIndex, handlerIndex: handlerIndex,
                                                matcher: matcher, handler: handler, command: command))
                        }
                    }
                }
            }
        }
        return result
    }

    private static func commandOf(_ value: JValue) -> String? {
        value["command"]?.stringValue ?? value["bash"]?.stringValue
    }

    /// Whether the Breakpoint handlers present for one event are exactly the wanted ones.
    private static func matches(_ present: [Found], _ wanted: [HookEntry]) -> Bool {
        guard present.count == wanted.count else { return false }
        var remaining = present
        for entry in wanted {
            let handler = entry.handler
            guard let index = remaining.firstIndex(where: { $0.matcher == entry.matcher && $0.handler.semanticallyEquals(handler) }) else {
                return false
            }
            remaining.remove(at: index)
        }
        return true
    }

    /// Removes Breakpoint's handlers from one event, then groups emptied by that, then (if
    /// `dropEmptyEvent`) the event if emptied by that.
    private static func removeMarked(in doc: inout JSONTextDocument, event: String, marker: HookMarker, format: Format,
                                     file: URL, dropEmptyEvent: Bool) throws {
        if let value = doc.node(at: ["hooks", .key(event)]), !value.isArray {
            throw IntegrationError.unparseableFile(file, reason: "hooks.\(event) is not a list")
        }
        let present = try found(in: doc, marker: marker, format: format, file: file).filter { $0.event == event }
        guard !present.isEmpty else { return }
        let eventPath: [JPath] = ["hooks", .key(event)]
        switch format.layout {
        case .flat:
            for item in present.sorted(by: { $0.groupIndex > $1.groupIndex }) {
                try edit(file) { try doc.removeElement(at: item.groupIndex, fromArrayAt: eventPath) }
            }
        case .grouped:
            let byGroup = Dictionary(grouping: present, by: \.groupIndex)
            for groupIndex in byGroup.keys.sorted(by: >) {
                let handlersPath = eventPath + [.index(groupIndex), "hooks"]
                for item in byGroup[groupIndex]!.sorted(by: { ($0.handlerIndex ?? 0) > ($1.handlerIndex ?? 0) }) {
                    try edit(file) { try doc.removeElement(at: item.handlerIndex ?? 0, fromArrayAt: handlersPath) }
                }
                if doc.node(at: handlersPath)?.elements?.isEmpty == true {
                    try edit(file) { try doc.removeElement(at: groupIndex, fromArrayAt: eventPath) }
                }
            }
        }
        if dropEmptyEvent, doc.node(at: eventPath)?.elements?.isEmpty == true {
            try edit(file) { try doc.removeMember(event, fromObjectAt: ["hooks"]) }
        }
    }
}

extension String {
    /// Empty or only whitespace and newlines.
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}

/// Edits marker blocks in rc files and the TOML `notify` line (SPEC §5.5):
/// `# >>> breakpoint >>>` … `# <<< breakpoint <<<`.
///
/// Contract: `upsert` replaces an existing block's body or appends a new block at the end
/// (separated from earlier text by one blank line); `insert` places a new block before a given
/// offset (followed by one blank line); `remove` deletes every block and the one blank line that
/// separated it. Text outside the block is preserved exactly, so append-then-remove restores the
/// original whenever it ended with a newline (or was empty). Idempotent. A begin marker without an
/// end marker (or the reverse) throws `MarkerBlockEditor.Malformed` from the throwing variants.
public enum MarkerBlockEditor {
    public static let beginMarker = "# >>> breakpoint >>>"
    public static let endMarker = "# <<< breakpoint <<<"

    public struct Malformed: Error, Equatable {}

    /// The block's text, ending with a newline.
    public static func block(body: String) -> String {
        let trimmed = body.hasSuffix("\n") ? String(body.dropLast()) : body
        return beginMarker + "\n" + trimmed + "\n" + endMarker + "\n"
    }

    public static func upsert(body: String, in text: String) -> String {
        (try? upsertChecked(body: body, in: text)) ?? text
    }

    public static func upsertChecked(body: String, in text: String) throws -> String {
        let blocks = try ranges(in: text)
        if !blocks.isEmpty {
            // Replace the first block, drop any others.
            var result = text
            for range in blocks.dropFirst().reversed() { result = removing(range, from: result) }
            result.replaceSubrange(try ranges(in: result)[0], with: block(body: body))
            return result
        }
        if text.isEmpty { return block(body: body) }
        if text.utf8.last == 0x0A { return text + "\n" + block(body: body) }
        return text + "\n\n" + block(body: body)
    }

    /// Inserts a new block at `offset` (a line start), followed by a blank line.
    static func insert(body: String, in text: String, at offset: String.Index) -> String {
        var result = text
        result.insert(contentsOf: block(body: body) + "\n", at: offset)
        return result
    }

    public static func remove(from text: String) -> String {
        (try? removeChecked(from: text)) ?? text
    }

    public static func removeChecked(from text: String) throws -> String {
        var result = text
        while let range = try ranges(in: result).last {
            result = removing(range, from: result)
        }
        return result
    }

    public static func containsBlock(_ text: String) -> Bool {
        text.contains(beginMarker) && text.contains(endMarker)
    }

    /// The body of the first block (without markers or the final newline), if any.
    public static func body(in text: String) throws -> String? {
        guard let range = try ranges(in: text).first else { return nil }
        var lines = String(text.unicodeScalars[range]).components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 2 else { return "" }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    /// Ranges of complete blocks, each from the start of the begin line through the end line's
    /// newline. Works on Unicode scalars so CRLF files split into lines correctly.
    static func ranges(in text: String) throws -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var openStart: String.Index?
        let scalars = text.unicodeScalars
        var lineStart = scalars.startIndex
        while lineStart < scalars.endIndex {
            let lineEnd = scalars[lineStart...].firstIndex(of: "\n") ?? scalars.endIndex
            let next = lineEnd < scalars.endIndex ? scalars.index(after: lineEnd) : scalars.endIndex
            let line = String(scalars[lineStart..<lineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == beginMarker {
                if openStart != nil { throw Malformed() }
                openStart = lineStart
            } else if line == endMarker {
                guard let start = openStart else { throw Malformed() }
                result.append(start..<next)
                openStart = nil
            }
            lineStart = next
        }
        if openStart != nil { throw Malformed() }
        return result
    }

    /// Removes `range` and one separating blank line (before it if there is one, else after it).
    private static func removing(_ range: Range<String.Index>, from text: String) -> String {
        var before = Array(String(text.unicodeScalars[..<range.lowerBound]).utf8)
        var after = Array(String(text.unicodeScalars[range.upperBound...]).utf8)
        if before.suffix(2) == [0x0A, 0x0A] {
            before.removeLast()
        } else if before.isEmpty || before.last == 0x0A, after.first == 0x0A {
            after.removeFirst()
        } else if before.isEmpty || before.last == 0x0A, after.starts(with: [0x0D, 0x0A]) {
            after.removeFirst(2)
        }
        return String(decoding: before + after, as: UTF8.self)
    }
}

/// Copies the CLI to `~/.breakpoint/bin/breakpoint` (SPEC §5.2): written on the first Install,
/// refreshed at app launch when its version differs. A copy, never a symlink.
///
/// Contract: `install()` creates `bin/` (0755), copies the bytes of `bundledCLI` (no extended
/// attributes, so no quarantine flag) to a temp file in `bin/`, sets mode 0755 and renames it into
/// place (a running hook keeps the old file); then writes the sidecar `bin/.breakpoint-version`.
/// `needsRefresh()` is true when the copy is missing, differs from `bundledCLI`, or the sidecar's version differs from
/// `BreakpointVersion.current`. Installing from the copy itself is a no-op.
public struct CLIInstaller: Sendable {
    public let paths: BreakpointPaths
    /// The CLI inside the app bundle (`Contents/Helpers/breakpoint`).
    public let bundledCLI: URL

    public init(paths: BreakpointPaths, bundledCLI: URL) {
        self.paths = paths
        self.bundledCLI = bundledCLI
    }

    /// Files that travel with the CLI on Windows: the Visual C++ runtime the statically linked
    /// Swift code still loads, shipped beside the app's executables (app-local deployment) so
    /// the copy runs on a PC without the Visual C++ Redistributable. Copied when present next to
    /// `bundledCLI`; none on macOS.
    public static var companionFiles: [String] {
        #if os(Windows)
        ["vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"]
        #else
        []
        #endif
    }

    /// Sidecar recording the installed copy's version.
    public var versionFile: URL { paths.binDirectory.appendingPathComponent(".breakpoint-version") }

    public var isInstalled: Bool { Executable.isRunnable(paths.cliCopy) }

    /// The version recorded next to the installed copy, if any.
    public var installedVersion: String? {
        guard let data = try? Data(contentsOf: versionFile) else { return nil }
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// Missing, from another version, or different bytes from the bundled tool (a rebuild without
    /// a version bump, e.g. every development build, would otherwise never reach the hooks).
    public func needsRefresh() -> Bool {
        guard isInstalled, installedVersion == BreakpointVersion.current else { return true }
        let source = bundledCLI.resolvingSymlinksInPath().standardizedFileURL
        guard source.path != paths.cliCopy.standardizedFileURL.path else { return false }
        let fm = FileManager.default
        let sourceSize = (try? fm.attributesOfItem(atPath: source.path))?[.size] as? NSNumber
        let copySize = (try? fm.attributesOfItem(atPath: paths.cliCopy.path))?[.size] as? NSNumber
        guard let sourceSize else { return false }  // nothing to copy from
        if sourceSize != copySize { return true }
        let folder = source.deletingLastPathComponent()
        for name in Self.companionFiles where fm.fileExists(atPath: folder.appendingPathComponent(name).path)
            && !fm.fileExists(atPath: paths.binDirectory.appendingPathComponent(name).path) {
            return true
        }
        guard let a = try? Data(contentsOf: source, options: .mappedIfSafe),
              let b = try? Data(contentsOf: paths.cliCopy, options: .mappedIfSafe) else { return true }
        return a != b
    }

    public func install() throws {
        let fm = FileManager.default
        let source = bundledCLI.resolvingSymlinksInPath().standardizedFileURL
        let target = paths.cliCopy.standardizedFileURL
        if source.path != target.path {
            let data: Data
            do {
                data = try Data(contentsOf: source)
            } catch {
                throw IntegrationError.io("The command-line tool could not be read from \(source.path).")
            }
            do {
                try fm.createDirectory(at: paths.dotBreakpoint, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o755])
                try fm.createDirectory(at: paths.binDirectory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o755])
                try AtomicFile.write(data, to: target, mode: 0o755)
                for name in Self.companionFiles {
                    let companion = source.deletingLastPathComponent().appendingPathComponent(name)
                    guard let bytes = try? Data(contentsOf: companion) else { continue }
                    let destination = paths.binDirectory.appendingPathComponent(name)
                    if (try? Data(contentsOf: destination)) != bytes {
                        try AtomicFile.write(bytes, to: destination, mode: 0o644)
                    }
                }
            } catch let error as IntegrationError {
                throw error
            } catch {
                throw IntegrationError.io("The command-line tool could not be copied to \(target.path).")
            }
        }
        do {
            try AtomicFile.write(Data((BreakpointVersion.current + "\n").utf8), to: versionFile, mode: 0o644)
        } catch {
            throw IntegrationError.io("The command-line tool's version file could not be written.")
        }
    }
}
