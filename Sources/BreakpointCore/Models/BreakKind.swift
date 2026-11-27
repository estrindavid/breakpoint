import Foundation

/// The four break kinds (SPEC §2.1). Raw values are stable on disk and in the wire format.
public enum BreakKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable, Comparable {
    case eyes
    case move
    case walk
    case breathe

    public var id: String { rawValue }

    /// Default planned length in seconds. `walk` has no fixed length: its target is the triggering
    /// run's expected length clamped to 5–10 min (see `walkTarget(expectedRun:)`); 5 min here is the
    /// value used for a manual walk with no agent.
    public var defaultLength: TimeInterval {
        switch self {
        case .eyes: return 20
        case .move: return 120
        case .walk: return 300
        case .breathe: return 60
        }
    }

    /// Walk target = expected run length clamped to 5–10 min, rounded to the minute (SPEC §2.1).
    public static func walkTarget(expectedRun: TimeInterval) -> TimeInterval {
        let clamped = min(max(expectedRun, 300), 600)
        return (clamped / 60).rounded() * 60
    }

    /// Short noun used in copy: "eye rest", "stretch", "walk", "breather".
    public var noun: String {
        switch self {
        case .eyes: return "eye rest"
        case .move: return "stretch"
        case .walk: return "walk"
        case .breathe: return "breather"
        }
    }

    /// Menu label in "Take a break ▸" menus: "Eye rest", "Stretch", "Walk", "Breather".
    public var menuTitle: String { noun.prefix(1).uppercased() + noun.dropFirst() }

    /// True for kinds where "1 more minute" is offered (SPEC §3.3, decision 15).
    public var allowsExtension: Bool { self == .move || self == .breathe }

    /// Larger first, for "the larger credited kind" (SPEC §3.5): walk > move > breathe > eyes.
    public var weight: Int {
        switch self {
        case .eyes: return 0
        case .breathe: return 1
        case .move: return 2
        case .walk: return 3
        }
    }

    public static func < (lhs: BreakKind, rhs: BreakKind) -> Bool { lhs.weight < rhs.weight }
}

/// How an offer or break ended (SPEC §2.7). Raw values are stable on disk.
public enum BreakOutcome: String, Codable, Sendable, Hashable, CaseIterable {
    case completed
    /// A started break that ended before 80% (Skip, Esc twice, I'm back, Back to work): it counts.
    case endedEarly
    /// Written only by earlier versions (a break ended with Skip in its first seconds). Still
    /// read from history; never recorded now, and counted nowhere.
    case skipped
    /// "Not now" on the nudge.
    case declined
    /// The nudge or countdown timed out, or was cancelled by input.
    case ignored
    /// A natural break: away time long enough to count (SPEC §2.3).
    case credited

    /// "Breaks taken" = completed + ended early + credited (SPEC §2.7). The UI never counts the others.
    public var countsAsTaken: Bool { self == .completed || self == .endedEarly || self == .credited }
}

/// Why the user ended a break from the overlay (the argument of `AppActions.finishBreak`).
/// Skip is `AppActions.skipBreak`; the timer running out is handled by the coordinator.
public enum BreakFinishReason: String, Codable, Sendable, Hashable, CaseIterable {
    /// Skip relabelled "Done" after ≥ 80% elapsed (SPEC §3.3). Records `completed`.
    case done
    /// "I'm back" / "Welcome back" on `walk`.
    case imBack
    /// "Back to work" when an agent needs the user during the break.
    case backToWork
}

extension BreakKind: CodingKeyRepresentable {}
