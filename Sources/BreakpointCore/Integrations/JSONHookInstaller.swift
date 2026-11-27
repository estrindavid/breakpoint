import Foundation

/// The install / uninstall / status logic shared by every tool whose hooks are merged into a JSON
/// settings file (Claude Code, Cursor, Codex, Gemini). Each tool supplies its file, entries and
/// format; this type does the safe editing (SPEC §5.5).
struct JSONHookInstaller {
    let id: IntegrationID
    let environment: IntegrationEnvironment
    let file: URL
    let entries: [JSONSettingsMerger.HookEntry]
    let format: JSONSettingsMerger.Format
    /// Commands earlier versions wrote (so an old install reads as "outdated", not "modified").
    let legacyCommands: Set<String>
    /// Extra checks before writing (e.g. Cursor's `"version": 1`). Throw `.unparseableFile`.
    var validate: (JSONTextDocument) throws -> Void = { _ in }

    var marker: HookMarker { HookMarker(source: id.source) }

    /// Commands that read as an older install rather than an edit: what earlier versions wrote
    /// and, on Windows, the macOS form of every current or earlier command (a settings file
    /// shared with a Mac through dotfiles), which Install then rewrites for this PC.
    var recognizedCommands: Set<String> {
        #if os(Windows)
        let current = entries.compactMap { $0.handler["command"]?.stringValue }
        return legacyCommands.union((current + legacyCommands).compactMap(HookCommand.posixForm(of:)))
        #else
        return legacyCommands
        #endif
    }
    var configFile: ConfigFile { ConfigFile(url: file, tool: id, environment: environment) }

    func status(found: Bool) -> IntegrationInstallState {
        guard found else { return .notFound }
        do {
            guard let text = try configFile.read() else { return .notInstalled }
            if !text.isBlank { try validate(try JSONSettingsMerger.document(text, format: format, file: file)) }
            switch try JSONSettingsMerger.state(of: text, wanted: entries, marker: marker, format: format,
                                                recognizedCommands: recognizedCommands, file: file) {
            case .absent: return .notInstalled
            case .current: return .installed
            case .outdated: return .outdated
            case .modified: return .modified
            }
        } catch let error as IntegrationError {
            return .unreadable(reason: error.statusSentence)
        } catch {
            return .unreadable(reason: "\(file.lastPathComponent) could not be read.")
        }
    }

    func install(found: Bool, notes: [String]) throws -> InstallReport {
        guard found else { throw IntegrationError.toolNotFound(id) }
        try environment.ensureCLICopy()
        var original: String?
        let change = try configFile.update { text in
            original = text
            if let text, !text.isBlank { try validate(try JSONSettingsMerger.document(text, format: format, file: file)) }
            return try JSONSettingsMerger.merge(entries, into: text ?? "", marker: marker, format: format, file: file)
        }
        if change != nil {
            if original.map(isSkeletonOrBlank) ?? true { configFile.remember(original: original) }
            configFile.remember(keepEmpty: JSONSettingsMerger.emptyContainers(in: original ?? "", wanted: entries,
                                                                              format: format, file: file))
        }
        return InstallReport(changedFiles: change.map { [$0.file] } ?? [], backups: change?.backup.map { [$0] } ?? [], notes: notes)
    }

    func uninstall() throws -> InstallReport {
        let record = configFile.ledgerRecord()
        let change = try configFile.update { text in
            guard let text else { return nil }
            let removed = try JSONSettingsMerger.remove(marker: marker, from: text, format: format,
                                                        keepEmpty: Set(record?.keepEmpty ?? []), file: file)
            guard removed != text else { return text }
            if let record, record.hasOriginal, isSkeletonOrBlank(removed) { return record.original }
            return removed
        }
        if record != nil { configFile.forgetRecord() }
        return InstallReport(changedFiles: change.map { [$0.file] } ?? [], backups: change?.backup.map { [$0] } ?? [])
    }

    /// True for text with no content of its own: blank, `{}`, or only the skeleton members
    /// Breakpoint itself writes into an empty file (and no comments).
    func isSkeletonOrBlank(_ text: String) -> Bool {
        if text.isBlank { return true }
        guard let doc = try? JSONTextDocument(text: text, allowComments: false), let members = doc.root.members else {
            return false
        }
        return members.allSatisfy { member in
            format.skeleton.contains { $0.key == member.key && $0.value.semanticallyEquals(member.value.value) }
        }
    }
}

extension IntegrationError {
    /// One sentence for a status pill ("settings.json could not be read (…).").
    var statusSentence: String {
        switch self {
        case .unparseableFile(let url, let reason): return "\(url.lastPathComponent) could not be read (\(reason))."
        default: return explanation
        }
    }
}

/// Builds hook handler objects.
enum HookHandler {
    /// `{"type": "command", "command": …, "async": true}` or, for `timeout`, sync with that timeout.
    static func claudeStyle(_ command: String, async: Bool, timeout: Int? = nil) -> JValue {
        var members = [JMember("type", .string("command")), JMember("command", .string(command))]
        if async { members.append(JMember("async", .bool(true))) }
        if let timeout { members.append(JMember("timeout", .int(timeout))) }
        return .object(members)
    }
}
