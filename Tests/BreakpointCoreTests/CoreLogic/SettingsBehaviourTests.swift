import Foundation
import Testing
@testable import BreakpointCore

@Suite("Settings behaviour: migration, clamping, presets, change notification (SPEC §2.1, §3.9)")
struct SettingsBehaviourTests {
    func write(_ json: String, to dir: TemporaryDirectory) throws {
        try dir.paths.ensureAppSupportDirectory()
        try Data(json.utf8).write(to: dir.paths.settingsFile)
    }

    func object(_ dir: TemporaryDirectory) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: dir.paths.settingsFile)) as? [String: Any] ?? [:]
    }

    @Test func aFileWithoutAVersionIsMigrated() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        try write(#"{"preset":"gentle","eyesEveryMinutes":30,"moveEveryMinutes":75,"hasBand":true}"#, to: dir)
        let store = SettingsStore(paths: dir.paths)
        let s = store.load()
        #expect(s.version == Settings.currentVersion)
        #expect(s.preset == .gentle && s.hasBand)
        try store.save(s)
        #expect(try object(dir)["version"] as? Int == Settings.currentVersion)
        #expect(SettingsStore.version(of: [:]) == 0)
        #expect(SettingsStore.migrate(["hasBand": true], from: 0)["version"] as? Int == 1)
    }

    @Test func outOfRangeValuesAreClampedOnLoad() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        try write(#"{"version":1,"preset":"balanced","eyesEveryMinutes":2,"moveEveryMinutes":999,"walkThresholdMinutes":0,"awayThresholdMinutes":1,"volume":-2}"#, to: dir)
        let s = SettingsStore(paths: dir.paths).load()
        #expect(s.eyesEveryMinutes == 10 && s.moveEveryMinutes == 120)
        #expect(s.walkThresholdMinutes == 5 && s.awayThresholdMinutes == 2 && s.volume == 0)
        // The cadences no longer match "balanced", so the preset says Custom.
        #expect(s.preset == .custom)
    }

    @Test func aPresetThatDisagreesWithItsCadencesBecomesCustom() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        try write(#"{"version":1,"preset":"frequent","eyesEveryMinutes":20,"moveEveryMinutes":50}"#, to: dir)
        #expect(SettingsStore(paths: dir.paths).load().preset == .custom)
    }

    @Test func settingsFromANewerVersionSurviveARoundTrip() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        try write(#"{"version":3,"hasBand":true,"newFeature":{"level":2},"menuBarText":"somethingNew"}"#, to: dir)
        let store = SettingsStore(paths: dir.paths)
        var s = store.load()
        #expect(s.hasBand && s.menuBarText == .nothing)
        s.volume = 0.8
        try store.save(s)
        let saved = try object(dir)
        #expect(saved["version"] as? Int == 3)
        #expect((saved["newFeature"] as? [String: Any])?["level"] as? Int == 2)
        #expect(saved["volume"] as? Double == 0.8)
        #expect(saved["menuBarText"] as? String == "nothing")
        #expect(store.load().volume == 0.8)
    }

    @Test func notANumberVersionOrNotAnObjectIsHandled() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        try write(#"{"version":"one","hasBand":true}"#, to: dir)
        #expect(SettingsStore(paths: dir.paths).load().hasBand)
        try write("[1,2,3]", to: dir)
        let store = SettingsStore(paths: dir.paths)
        #expect(store.load() == .defaults)
        #expect(FileManager.default.fileExists(atPath: store.corruptFileURL.path))
    }

    @Test func savingNotifiesWhatChanged() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let store = SettingsStore(paths: dir.paths)
        var received: [SettingsChange] = []
        store.onChange = { received.append($0) }
        var s = store.load()
        #expect(try store.save(s) == nil)
        #expect(received.isEmpty)

        s.applyPreset(.frequent)
        s.awayThresholdMinutes = 5
        let change = try #require(try store.save(s))
        #expect(received == [change])
        #expect(change.cadenceChanged && change.presenceRulesChanged)
        #expect(change.changed(\.awayThresholdMinutes) && !change.changed(\.hasBand))
        #expect(change.changedKeys == ["preset", "eyesEveryMinutes", "moveEveryMinutes", "awayThresholdMinutes"])

        // Saving the same values again says nothing.
        #expect(try store.save(s) == nil)
        #expect(received.count == 1)
    }

    @Test func changedKeysCoverOptionalKeys() {
        var after = Settings()
        after.codexHome = "/tmp/codex"
        after.popoverHotkey = .nudgeStart
        let change = SettingsChange(previous: .defaults, current: after)
        #expect(change.changedKeys == ["codexHome", "popoverHotkey"])
        #expect(!change.cadenceChanged && !change.presenceRulesChanged)
    }

    @Test func presetsApplyAndCustomEditsAreClamped() {
        var s = Settings()
        for preset in CadencePreset.cards {
            s.applyPreset(preset)
            #expect(s.cadence == preset.cadence && s.preset == preset)
        }
        s.setCadence(eyesEveryMinutes: 5)
        #expect(s.eyesEveryMinutes == 10 && s.preset == .custom)
        s.setCadence(moveEveryMinutes: 500)
        #expect(s.moveEveryMinutes == 120)
        s.applyPreset(.custom)
        #expect(s.eyesEveryMinutes == 10 && s.preset == .custom)
    }
}
