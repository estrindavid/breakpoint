import Foundation

/// Call signals read without a permission prompt (SPEC §2.4): any microphone or camera in use.
public struct CallSignals: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let microphone = CallSignals(rawValue: 1 << 0)
    public static let camera = CallSignals(rawValue: 1 << 1)

    /// "microphone is on", "camera is on", "microphone and camera are on"; `nil` when empty.
    /// Names the signal, never an app (SPEC decision 6).
    public var phrase: String? {
        switch (contains(.microphone), contains(.camera)) {
        case (true, true): return "microphone and camera are on"
        case (true, false): return "microphone is on"
        case (false, true): return "camera is on"
        case (false, false): return nil
        }
    }

    /// The signals that count as a call under the user's settings.
    public func filtered(by settings: Settings) -> CallSignals {
        var result: CallSignals = []
        if settings.pauseForMicrophone, contains(.microphone) { result.insert(.microphone) }
        if settings.pauseForMicrophone, settings.pauseForCamera, contains(.camera) { result.insert(.camera) }
        return result
    }
}

/// A reason no nudge may appear (SPEC §2.4). While any is active the menu bar shows the paused
/// shape. Timers keep accruing during pauses.
public enum PauseReason: Codable, Equatable, Hashable, Sendable {
    /// From the Pause menu: 30 min, 1 h, or until tomorrow (05:00 local).
    case manual(until: Date)
    /// Microphone and/or camera in use, with "Pause during calls" on.
    case call(CallSignals)
    /// The user chose Wrap up (SPEC §2.8); lasts until 05:00 local (`until`).
    case windDownWrappedUp(until: Date)

    /// When the reason ends by itself; `nil` for calls (they end when the signals stop).
    public var until: Date? {
        switch self {
        case .manual(let until), .windDownWrappedUp(let until): return until
        case .call: return nil
        }
    }

    /// Order for choosing which reason to name when several are active: call > wrap-up > manual.
    public var displayPriority: Int {
        switch self {
        case .call: return 2
        case .windDownWrappedUp: return 1
        case .manual: return 0
        }
    }
}

/// Every pause-related fact the engine needs (SPEC §7.1).
public struct PauseState: Codable, Equatable, Hashable, Sendable {
    /// Active reasons; empty when not paused.
    public var reasons: [PauseReason]
    /// No nudge before this time (resume cool-down, SPEC §2.4).
    public var cooldownUntil: Date?
    /// Set by **Resume now** during a call: the current call is ignored until every call signal
    /// has stopped, then this resets to `false`.
    public var ignoringCurrentCall: Bool

    public init(reasons: [PauseReason] = [], cooldownUntil: Date? = nil, ignoringCurrentCall: Bool = false) {
        self.reasons = reasons
        self.cooldownUntil = cooldownUntil
        self.ignoringCurrentCall = ignoringCurrentCall
    }

    public static let none = PauseState()

    public var isPaused: Bool { !reasons.isEmpty }

    /// The reason to name in the UI (highest `displayPriority`).
    public var primaryReason: PauseReason? { reasons.max { $0.displayPriority < $1.displayPriority } }

    /// The active call signals, if a call pause is active.
    public var callSignals: CallSignals? {
        for reason in reasons { if case .call(let signals) = reason { return signals } }
        return nil
    }

    public func isCoolingDown(at now: Date) -> Bool { cooldownUntil.map { now < $0 } ?? false }
}

/// The choices of the Pause menu (SPEC §2.4, §3.8).
public enum PauseDuration: String, Codable, Sendable, Hashable, CaseIterable {
    case thirtyMinutes
    case oneHour
    case untilTomorrow

    public var menuTitle: String {
        switch self {
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .untilTomorrow: return "Until tomorrow"
        }
    }

    /// The end of a pause chosen at `now`. "Until tomorrow" ends at the next 05:00 local.
    public func end(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .untilTomorrow: return BreakpointDay.nextBoundary(after: now, calendar: calendar)
        }
    }
}
