import Foundation
import Testing
@testable import BreakpointCore

@Suite("Settings and SettingsStore (SPEC §3.9)")
struct SettingsTests {
    @Test func defaultsMatchTheSpecTable() {
        let s = Settings.defaults
        #expect(s.version == 1)
        #expect(s.preset == .balanced)
        #expect(s.eyesEveryMinutes == 20 && s.moveEveryMinutes == 50 && s.walkThresholdMinutes == 8)
        #expect(s.autoStartEyes && !s.strictAgentOnly && !s.fullBreakOnAllDisplays)
        #expect(!s.hasBand && !s.airpodsMovementCheck)
        #expect(s.pauseForMicrophone && s.pauseForCamera && s.awayThresholdMinutes == 3)
        #expect(!s.windDownEnabled && s.stopTime == TimeOfDay(hour: 23, minute: 0) && s.stopDays == .all && s.escalatingHold)
        #expect(s.codexHome == nil)
        #expect(s.launchAtLogin && s.menuBarText == .nothing && s.popupPosition == .topCentre && s.nudgeHotkeys)
        #expect(s.popoverHotkey == nil && s.chimeNeedsYou && s.volume == 0.5 && !s.chimeBreakEnd)
        #expect(s.storePromptSnippets && !s.hasCompletedOnboarding)
    }

    @Test func roundTripsEveryKey() throws {
        var s = Settings()
        s.applyPreset(.frequent)
        s.walkThresholdMinutes = 12
        s.stopTime = TimeOfDay(hour: 22, minute: 30)
        s.stopDays = .weekdays
        s.codexHome = "~/codex"
        s.popoverHotkey = .nudgeStart
        s.menuBarText = .agentState
        s.popupPosition = .topRight
        s.volume = 0.25
        #expect(try Fixture.jsonRoundTrip(s) == s)
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        let decoded = try JSONFile<Settings>.decoder.decode(Settings.self, from: Data("{}".utf8))
        #expect(decoded == .defaults)
    }

    @Test func wrongTypesAndUnknownCasesFallBackPerKey() throws {
        let json = #"{"eyesEveryMinutes":"lots","preset":"turbo","moveEveryMinutes":40,"futureKey":1,"stopDays":[2,3]}"#
        let decoded = try JSONFile<Settings>.decoder.decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.eyesEveryMinutes == 20)
        #expect(decoded.preset == .balanced)
        #expect(decoded.moveEveryMinutes == 40)
        #expect(decoded.stopDays == [.monday, .tuesday])
    }

    @Test func normalizedClampsRangesAndFixesPreset() {
        var s = Settings()
        s.eyesEveryMinutes = 5
        s.moveEveryMinutes = 500
        s.walkThresholdMinutes = 1
        s.awayThresholdMinutes = 60
        s.volume = 3
        let n = s.normalized()
        #expect(n.eyesEveryMinutes == 10 && n.moveEveryMinutes == 120)
        #expect(n.walkThresholdMinutes == 5 && n.awayThresholdMinutes == 10 && n.volume == 1)
        #expect(n.preset == .custom)
    }

    @Test func editingACadenceSetsCustomUnlessItMatchesAPreset() {
        var s = Settings()
        s.setCadence(eyesEveryMinutes: 25)
        #expect(s.preset == .custom)
        s.setCadence(eyesEveryMinutes: 30, moveEveryMinutes: 75)
        #expect(s.preset == .gentle)
        s.applyPreset(.frequent)
        #expect(s.cadence == Cadence(eyesEveryMinutes: 15, moveEveryMinutes: 30))
    }

    @Test func presetsMatchTheSpec() {
        #expect(CadencePreset.gentle.cadence == Cadence(eyesEveryMinutes: 30, moveEveryMinutes: 75))
        #expect(CadencePreset.balanced.cadence == Cadence(eyesEveryMinutes: 20, moveEveryMinutes: 50))
        #expect(CadencePreset.frequent.cadence == Cadence(eyesEveryMinutes: 15, moveEveryMinutes: 30))
        #expect(CadencePreset.custom.cadence == nil)
    }

    @Test func storeLoadsDefaultsWhenMissingAndSavesAtomically() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let store = SettingsStore(paths: dir.paths)
        #expect(store.load() == .defaults)
        #expect(!FileManager.default.fileExists(atPath: dir.paths.settingsFile.path))

        var s = Settings()
        s.hasBand = true
        s.applyPreset(.gentle)
        try store.save(s)
        #expect(store.load() == s)

        let attributes = try FileManager.default.attributesOfItem(atPath: dir.paths.settingsFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: dir.paths.appSupport.path)
        #expect((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func storeMovesACorruptFileAsideAndReturnsDefaults() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        try dir.paths.ensureAppSupportDirectory()
        try Data("{ not json".utf8).write(to: dir.paths.settingsFile)
        let store = SettingsStore(paths: dir.paths)
        #expect(store.load() == .defaults)
        #expect(FileManager.default.fileExists(atPath: store.corruptFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: dir.paths.settingsFile.path))
    }

    @Test func storeSavesNormalizedValues() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let store = SettingsStore(paths: dir.paths)
        var s = Settings()
        s.eyesEveryMinutes = 1
        try store.save(s)
        #expect(store.load().eyesEveryMinutes == 10)
    }
}
