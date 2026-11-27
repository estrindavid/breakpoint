import Foundation

/// Loads and saves `settings.json` (SPEC §3.9, §8).
///
/// Contract:
/// - `load()` never fails: a missing file gives the defaults; an unreadable or corrupt file is
///   moved aside to `settings.json.corrupt` (so the user's data is not silently lost) and the
///   defaults are returned. Older files are migrated step by step (`migrate`), then decoded
///   tolerantly and `normalized()` (clamped, preset consistent with the cadences).
/// - `save(_:)` writes atomically (mode 0600, directory 0700) and throws on I/O failure. Keys this
///   version does not know (a file written by a newer Breakpoint) are kept, as is the newer
///   version number, so opening an older build never erases newer settings.
/// - `onChange` is called after a save that changed any value, with what changed.
/// - Not thread-safe; the coordinator calls it from the main thread.
///
/// Versions: a file without a `version` key is version 0 (written before the key existed; same
/// keys as version 1). Version 1 is the current schema.
public final class SettingsStore {
    public let fileURL: URL
    /// Called after `save` changed the stored settings.
    public var onChange: ((SettingsChange) -> Void)?
    /// The settings as last loaded or saved (`nil` before either).
    public private(set) var current: Settings?

    /// Keys of the last loaded file that this version does not know, kept on save.
    private var foreignKeys: [String: Any] = [:]
    /// The last loaded file's version, when newer than `Settings.currentVersion`.
    private var newerVersion: Int?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public convenience init(paths: BreakpointPaths) {
        self.init(fileURL: paths.settingsFile)
    }

    /// The corrupt-file location used by `load()`.
    public var corruptFileURL: URL { fileURL.appendingPathExtension("corrupt") }

    public func load() -> Settings {
        foreignKeys = [:]
        newerVersion = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            current = .defaults
            return .defaults
        }
        do {
            let data = try SafeFile.read(fileURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let version = Self.version(of: object)
            let migrated = Self.migrate(object, from: version)
            let decoded = try JSONFile<Settings>.decoder.decode(
                Settings.self, from: JSONSerialization.data(withJSONObject: migrated))
            let known = Set(Settings.CodingKeys.allCases.map(\.rawValue))
            foreignKeys = migrated.filter { !known.contains($0.key) }
            newerVersion = version > Settings.currentVersion ? version : nil
            let settings = decoded.normalized()
            current = settings
            return settings
        } catch {
            let fm = FileManager.default
            try? fm.removeItem(at: corruptFileURL)
            try? fm.moveItem(at: fileURL, to: corruptFileURL)
            current = .defaults
            return .defaults
        }
    }

    /// Writes `settings` (normalized). Returns what changed since the last load or save, if
    /// anything did.
    @discardableResult
    public func save(_ settings: Settings) throws -> SettingsChange? {
        let normalized = settings.normalized()
        var object = try Self.dictionary(normalized)
        for (key, value) in foreignKeys where object[key] == nil { object[key] = value }
        if let newerVersion { object[Settings.CodingKeys.version.rawValue] = newerVersion }

        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try SafeFile.writeAtomically(data, to: fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        let previous = current ?? .defaults
        current = normalized
        let change = SettingsChange(previous: previous, current: normalized)
        guard change.hasChanges else { return nil }
        onChange?(change)
        return change
    }

    // MARK: Migration

    /// The `version` key of a settings object; 0 when absent or not a number.
    static func version(of object: [String: Any]) -> Int {
        (object[Settings.CodingKeys.version.rawValue] as? NSNumber)?.intValue ?? 0
    }

    /// Upgrades a raw settings object from `version` to `Settings.currentVersion`, one step at a
    /// time. Objects from a newer version are returned unchanged (decoding is tolerant).
    static func migrate(_ object: [String: Any], from version: Int) -> [String: Any] {
        var object = object
        var version = max(0, version)
        while version < Settings.currentVersion {
            object = step(object, from: version)
            version += 1
            object[Settings.CodingKeys.version.rawValue] = version
        }
        return object
    }

    /// One migration step from `version` to `version + 1`.
    private static func step(_ object: [String: Any], from version: Int) -> [String: Any] {
        switch version {
        case 0:
            // Version 0 files predate the version key and have the same keys as version 1.
            return object
        default:
            return object
        }
    }

    /// Kept for callers that migrate decoded values; decoded settings are already current.
    static func migrate(_ settings: Settings) -> Settings {
        settings
    }

    private static func dictionary(_ settings: Settings) throws -> [String: Any] {
        let data = try JSONFile<Settings>.encoder.encode(settings)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
