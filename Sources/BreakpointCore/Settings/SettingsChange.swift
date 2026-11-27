import Foundation

/// What a settings save changed (`SettingsStore.onChange`). Lets the app react to exactly the
/// settings that matter for each part: timers, presence, the tracker, integrations, layout.
public struct SettingsChange: Equatable, Sendable {
    public var previous: Settings
    public var current: Settings

    public init(previous: Settings, current: Settings) {
        self.previous = previous
        self.current = current
    }

    /// Whether the value at `keyPath` differs.
    public func changed<Value: Equatable>(_ keyPath: KeyPath<Settings, Value>) -> Bool {
        previous[keyPath: keyPath] != current[keyPath: keyPath]
    }

    public var hasChanges: Bool { previous != current }

    /// The settings keys (property names, as in `settings.json`) whose values differ.
    public var changedKeys: Set<String> {
        let before = Self.values(previous)
        let after = Self.values(current)
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }

    /// The eye or move cadence (or the preset) changed: "next break" figures move.
    public var cadenceChanged: Bool { changed(\.cadence) || changed(\.preset) }

    /// Presence rules changed: the away threshold or what counts as a call.
    public var presenceRulesChanged: Bool {
        changed(\.awayThresholdMinutes) || changed(\.pauseForMicrophone) || changed(\.pauseForCamera)
    }

    /// Each key's JSON value, as text, for a key-by-key comparison.
    private static func values(_ settings: Settings) -> [String: String] {
        guard let data = try? JSONFile<Settings>.encoder.encode(settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let encoded = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) {
                result[key] = String(decoding: encoded, as: UTF8.self)
            }
        }
        return result
    }
}
