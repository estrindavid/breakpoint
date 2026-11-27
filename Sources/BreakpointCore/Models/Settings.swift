import Foundation

/// What to show next to the menu-bar icon (SPEC §3.7, §3.9 General).
public enum MenuBarTextMode: String, Codable, Sendable, Hashable, CaseIterable {
    case nothing
    /// "6m", "due".
    case timeToNextBreak
    /// "Claude 3m".
    case agentState
}

/// Where pop-ups appear on the active display (SPEC §3.0).
public enum PopupPosition: String, Codable, Sendable, Hashable, CaseIterable {
    case topLeft
    case topCentre
    case topRight
}

/// A global keyboard shortcut (Carbon key code + Carbon modifier flags), as recorded in Settings.
public struct HotKeyCombo: Codable, Equatable, Hashable, Sendable {
    /// Carbon virtual key code (`kVK_*`).
    public var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    public var carbonModifiers: UInt32
    /// Display form, e.g. "⌃⌥⌘B".
    public var display: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    /// How this platform writes the shortcut in sentences: the stored macOS form ("⌃⌥⌘.") on
    /// macOS; on Windows, the keys Windows names ("Ctrl+Alt+Win+."), in the order Windows writes
    /// them (⌃ Ctrl, ⌥ Alt, ⇧ Shift, ⌘ Win), as the Windows app's keycaps do.
    public var platformDisplay: String {
        #if os(Windows)
        let names: [(Character, String)] = [("⌃", "Ctrl"), ("⌥", "Alt"), ("⇧", "Shift"), ("⌘", "Win")]
        let present = Set(display.filter { glyph in names.contains { $0.0 == glyph } })
        let key = String(display.filter { glyph in !names.contains { $0.0 == glyph } })
        return (names.filter { present.contains($0.0) }.map(\.1) + [key.uppercased()]).joined(separator: "+")
        #else
        return display
        #endif
    }

    // Carbon modifier bits (from Carbon.HIToolbox.Events), duplicated here so Core stays Foundation-only.
    public static let cmdKey: UInt32 = 1 << 8
    public static let shiftKey: UInt32 = 1 << 9
    public static let optionKey: UInt32 = 1 << 11
    public static let controlKey: UInt32 = 1 << 12

    /// ⌃⌥⌘B: start the offered break (SPEC §3.1). kVK_ANSI_B = 0x0B.
    public static let nudgeStart = HotKeyCombo(
        keyCode: 0x0B, carbonModifiers: controlKey | optionKey | cmdKey, display: "⌃⌥⌘B")
    /// ⌃⌥⌘. : dismiss the nudge (Not now). kVK_ANSI_Period = 0x2F.
    public static let nudgeDismiss = HotKeyCombo(
        keyCode: 0x2F, carbonModifiers: controlKey | optionKey | cmdKey, display: "⌃⌥⌘.")
}

/// All user settings (SPEC §3.9). Property names are the keys of the settings table; stored as
/// `settings.json`. Decoding is tolerant: a missing key takes its default, an out-of-range value
/// is clamped (`normalized()`), so files from older or newer versions always load.
public struct Settings: Codable, Equatable, Hashable, Sendable {
    /// Schema version of this struct. Bump when a key changes meaning; migrate in `SettingsStore`.
    public static let currentVersion = 1

    public var version: Int = Settings.currentVersion

    // Breaks
    public var preset: CadencePreset = .balanced
    /// 10–60.
    public var eyesEveryMinutes: Int = 20
    /// 20–120.
    public var moveEveryMinutes: Int = 50
    /// 5–20.
    public var walkThresholdMinutes: Int = 8
    public var autoStartEyes: Bool = true
    public var strictAgentOnly: Bool = false
    public var fullBreakOnAllDisplays: Bool = false

    // Routine
    public var hasBand: Bool = false
    public var airpodsMovementCheck: Bool = false
    /// Routine ids never used for a stretch (SPEC §2.2). Sorted, no duplicates.
    public var excludedRoutines: [String] = []

    // Pauses
    /// "Pause during calls" (the main toggle).
    public var pauseForMicrophone: Bool = true
    /// Options…: also when the camera is on (only applies while `pauseForMicrophone` is on).
    public var pauseForCamera: Bool = true
    /// 2–10.
    public var awayThresholdMinutes: Int = 3

    // Wind-down
    public var windDownEnabled: Bool = false
    public var stopTime: TimeOfDay = TimeOfDay(hour: 23, minute: 0)
    public var stopDays: Weekdays = .all
    public var escalatingHold: Bool = true

    // Integrations
    /// Codex folder override, shown only if `~/.codex` is absent. `nil` = `$CODEX_HOME` or `~/.codex`.
    public var codexHome: String? = nil

    // General
    public var launchAtLogin: Bool = true
    public var menuBarText: MenuBarTextMode = .nothing
    public var popupPosition: PopupPosition = .topCentre
    public var nudgeHotkeys: Bool = true
    public var popoverHotkey: HotKeyCombo? = nil
    public var chimeNeedsYou: Bool = true
    /// 0…1.
    public var volume: Double = 0.5
    public var chimeBreakEnd: Bool = false
    /// A soft tick at each step change of a stretch (SPEC §4.7), quieter than the chimes.
    public var stepTick: Bool = true

    // Privacy
    public var storePromptSnippets: Bool = true

    // Updates (About)
    /// Once a day, ask GitHub for the latest version number (SPEC §2.11).
    public var checkForUpdates: Bool = true
    /// Install new versions at a quiet moment without asking first (SPEC §2.11).
    public var installUpdatesAutomatically: Bool = false

    // Not a user-visible setting: set when onboarding finishes (SPEC §3.10 runs on first launch only).
    public var hasCompletedOnboarding: Bool = false
    // Not a user-visible setting: what happened to the one-minute tour (SPEC §3.12), so it is
    // offered once. Missing in files from versions without the tour: `.notOffered`, and only
    // finishing onboarding offers it, so people who update never get it unasked.
    public var tourStatus: TourStatus = .notOffered
    /// "Show hints" (General): the first time a real surface appears it may carry one short line
    /// (SPEC §3.12). A file from a version without this key belongs to someone who already uses
    /// Breakpoint, so it decodes as off: an update never starts showing hints unasked.
    public var showHints: Bool = true
    // Not a user-visible setting: lessons already known, from a hint or from the tour (§3.12).
    public var hintsSeen: [HintLesson] = []

    public init() {}

    public static let defaults = Settings()

    // MARK: Ranges (SPEC §3.9)

    public static let eyesEveryRange = 10...60
    public static let moveEveryRange = 20...120
    public static let walkThresholdRange = 5...20
    public static let awayThresholdRange = 2...10

    // MARK: Derived values

    public var cadence: Cadence { Cadence(eyesEveryMinutes: eyesEveryMinutes, moveEveryMinutes: moveEveryMinutes) }
    public var walkThreshold: TimeInterval { TimeInterval(walkThresholdMinutes * 60) }
    public var awayThreshold: TimeInterval { TimeInterval(awayThresholdMinutes * 60) }

    // MARK: Mutations with rules

    /// Includes or excludes a routine from the rotation.
    public mutating func setRoutine(_ id: String, excluded: Bool) {
        var set = Set(excludedRoutines)
        if excluded { set.insert(id) } else { set.remove(id) }
        excludedRoutines = set.sorted()
    }

    /// Selects a preset card, setting both cadences. `custom` keeps the current cadences.
    public mutating func applyPreset(_ preset: CadencePreset) {
        self.preset = preset
        if let cadence = preset.cadence {
            eyesEveryMinutes = cadence.eyesEveryMinutes
            moveEveryMinutes = cadence.moveEveryMinutes
        }
    }

    /// Editing either cadence sets the preset to Custom (SPEC §2.1), unless the result equals a
    /// preset exactly, in which case that preset is selected.
    public mutating func setCadence(eyesEveryMinutes: Int? = nil, moveEveryMinutes: Int? = nil) {
        if let eyes = eyesEveryMinutes { self.eyesEveryMinutes = Self.eyesEveryRange.clamp(eyes) }
        if let move = moveEveryMinutes { self.moveEveryMinutes = Self.moveEveryRange.clamp(move) }
        preset = CadencePreset.matching(cadence)
    }

    /// A copy with every ranged value clamped and the version set to current.
    public func normalized() -> Settings {
        var s = self
        s.version = Settings.currentVersion
        s.eyesEveryMinutes = Self.eyesEveryRange.clamp(eyesEveryMinutes)
        s.moveEveryMinutes = Self.moveEveryRange.clamp(moveEveryMinutes)
        s.walkThresholdMinutes = Self.walkThresholdRange.clamp(walkThresholdMinutes)
        s.awayThresholdMinutes = Self.awayThresholdRange.clamp(awayThresholdMinutes)
        s.volume = min(max(volume, 0), 1)
        s.excludedRoutines = Array(Set(excludedRoutines)).sorted()
        if let cadence = s.preset.cadence, cadence != s.cadence { s.preset = .custom }
        s.hintsSeen = HintLesson.allCases.filter { hintsSeen.contains($0) }
        return s
    }

    // MARK: Codable (tolerant)

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, preset, eyesEveryMinutes, moveEveryMinutes, walkThresholdMinutes, autoStartEyes,
             strictAgentOnly, fullBreakOnAllDisplays, hasBand, airpodsMovementCheck, excludedRoutines,
             pauseForMicrophone,
             pauseForCamera, awayThresholdMinutes, windDownEnabled, stopTime, stopDays, escalatingHold,
             codexHome, launchAtLogin, menuBarText, popupPosition, nudgeHotkeys, popoverHotkey,
             chimeNeedsYou, volume, chimeBreakEnd, stepTick, storePromptSnippets, checkForUpdates,
             installUpdatesAutomatically, hasCompletedOnboarding, tourStatus, showHints, hintsSeen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // A wrong type or unknown enum case falls back to the default instead of failing the file.
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = Settings()
        version = value(.version, d.version)
        preset = value(.preset, d.preset)
        eyesEveryMinutes = value(.eyesEveryMinutes, d.eyesEveryMinutes)
        moveEveryMinutes = value(.moveEveryMinutes, d.moveEveryMinutes)
        walkThresholdMinutes = value(.walkThresholdMinutes, d.walkThresholdMinutes)
        autoStartEyes = value(.autoStartEyes, d.autoStartEyes)
        strictAgentOnly = value(.strictAgentOnly, d.strictAgentOnly)
        fullBreakOnAllDisplays = value(.fullBreakOnAllDisplays, d.fullBreakOnAllDisplays)
        hasBand = value(.hasBand, d.hasBand)
        airpodsMovementCheck = value(.airpodsMovementCheck, d.airpodsMovementCheck)
        excludedRoutines = value(.excludedRoutines, d.excludedRoutines)
        pauseForMicrophone = value(.pauseForMicrophone, d.pauseForMicrophone)
        pauseForCamera = value(.pauseForCamera, d.pauseForCamera)
        awayThresholdMinutes = value(.awayThresholdMinutes, d.awayThresholdMinutes)
        windDownEnabled = value(.windDownEnabled, d.windDownEnabled)
        stopTime = value(.stopTime, d.stopTime)
        stopDays = value(.stopDays, d.stopDays)
        escalatingHold = value(.escalatingHold, d.escalatingHold)
        codexHome = value(.codexHome, d.codexHome)
        launchAtLogin = value(.launchAtLogin, d.launchAtLogin)
        menuBarText = value(.menuBarText, d.menuBarText)
        popupPosition = value(.popupPosition, d.popupPosition)
        nudgeHotkeys = value(.nudgeHotkeys, d.nudgeHotkeys)
        popoverHotkey = value(.popoverHotkey, d.popoverHotkey)
        chimeNeedsYou = value(.chimeNeedsYou, d.chimeNeedsYou)
        volume = value(.volume, d.volume)
        chimeBreakEnd = value(.chimeBreakEnd, d.chimeBreakEnd)
        stepTick = value(.stepTick, d.stepTick)
        storePromptSnippets = value(.storePromptSnippets, d.storePromptSnippets)
        checkForUpdates = value(.checkForUpdates, d.checkForUpdates)
        installUpdatesAutomatically = value(.installUpdatesAutomatically, d.installUpdatesAutomatically)
        hasCompletedOnboarding = value(.hasCompletedOnboarding, d.hasCompletedOnboarding)
        tourStatus = value(.tourStatus, d.tourStatus)
        // Without the key (a version before hints): on only for someone still before onboarding.
        showHints = value(.showHints, !hasCompletedOnboarding)
        // Names this version does not know (a newer Breakpoint's hints) are skipped, not fatal.
        hintsSeen = value(.hintsSeen, [String]()).compactMap(HintLesson.init(rawValue:))
    }
}

extension ClosedRange where Bound: Comparable {
    /// `value` limited to this range.
    public func clamp(_ value: Bound) -> Bound { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
