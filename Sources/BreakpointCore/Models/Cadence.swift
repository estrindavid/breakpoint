import Foundation

/// How often `eyes` and `move` are due (SPEC §2.1).
public struct Cadence: Codable, Equatable, Hashable, Sendable {
    public var eyesEveryMinutes: Int
    public var moveEveryMinutes: Int

    public init(eyesEveryMinutes: Int, moveEveryMinutes: Int) {
        self.eyesEveryMinutes = eyesEveryMinutes
        self.moveEveryMinutes = moveEveryMinutes
    }

    public var eyesEvery: TimeInterval { TimeInterval(eyesEveryMinutes * 60) }
    public var moveEvery: TimeInterval { TimeInterval(moveEveryMinutes * 60) }

    /// The cadence that drives `kind`: eyes for `eyes`, move for every other kind.
    public func interval(for kind: BreakKind) -> TimeInterval { kind == .eyes ? eyesEvery : moveEvery }
}

/// Cadence presets (SPEC §2.1). Editing either cadence sets the preset to `custom`.
public enum CadencePreset: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case gentle
    case balanced
    case frequent
    case custom

    public var id: String { rawValue }

    /// The three presets shown as cards (custom is never a card).
    public static let cards: [CadencePreset] = [.gentle, .balanced, .frequent]

    /// Gentle 30/75, Balanced 20/50, Frequent 15/30; `nil` for custom.
    public var cadence: Cadence? {
        switch self {
        case .gentle: return Cadence(eyesEveryMinutes: 30, moveEveryMinutes: 75)
        case .balanced: return Cadence(eyesEveryMinutes: 20, moveEveryMinutes: 50)
        case .frequent: return Cadence(eyesEveryMinutes: 15, moveEveryMinutes: 30)
        case .custom: return nil
        }
    }

    public var title: String {
        switch self {
        case .gentle: return "Gentle"
        case .balanced: return "Balanced"
        case .frequent: return "Frequent"
        case .custom: return "Custom"
        }
    }

    /// The preset matching `cadence`, or `custom`.
    public static func matching(_ cadence: Cadence) -> CadencePreset {
        cards.first { $0.cadence == cadence } ?? .custom
    }
}
