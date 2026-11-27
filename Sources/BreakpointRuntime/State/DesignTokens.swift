import Foundation
import BreakpointCore

// The few design-system values `AppState` carries, as plain enums both apps draw from. BreakpointKit
// keeps its own names for them (`BrandMark.Variant`, `BrandMark.Badge`, `Theme.Tone`) as aliases.

/// How the mark is drawn (SPEC §3.7, §4.1).
public enum MarkVariant: Sendable, CaseIterable {
    /// Solid tag with the eyes knocked out: the brand mark (icon, onboarding, About).
    case brand
    /// Menu bar, idle: outlined tag with the two eyes.
    case idle
    /// Menu bar, break due: outlined tag, notch filled (block with the eyes knocked out).
    case due
    /// Menu bar, on a break: the whole mark filled (same as `.brand`).
    case onBreak
    /// Menu bar, paused: outlined tag with a single pause bar.
    case paused
}

/// The menu-bar (tray) badge layer (§3.7), at the trailing-bottom corner.
public enum MarkBadge: Sendable, CaseIterable {
    case none
    /// Agent working: small filled dot (the caller animates its opacity at 0.5 Hz).
    case working
    /// Agent needs you: small hollow ring, static.
    case needsYou
}

/// The colour role of a badge, dot or chip.
public enum Tone: String, Sendable, CaseIterable {
    /// The Breakpoint gradient: break kinds.
    case brand
    /// Indigo: agent working.
    case agent
    /// Amber: an agent needs you.
    case needsYou
    /// Solid mint: done, connected, selected.
    case mint
    /// Grey: idle.
    case neutral
}

/// The break overlay's buttons (SPEC §3.3).
public enum OverlayControl: Hashable, Sendable, CaseIterable {
    /// Skip, relabelled Done after 80%.
    case skip
    /// "1 more minute".
    case extend
    /// The mint primary: I'm back / Welcome back / Back to work.
    case primary
}

/// Which overlay controls a break shows, and the primary's label (shared by both apps and the
/// debug harness).
public enum OverlayControls {
    public static func controls(for activeBreak: ActiveBreakState) -> [OverlayControl] {
        var controls: [OverlayControl] = [.skip]
        if activeBreak.canExtend && !activeBreak.needsYou { controls.append(.extend) }
        if hasPrimary(activeBreak) { controls.append(.primary) }
        return controls
    }

    /// A mint primary is shown: Back to work when an agent needs you, I'm back on `walk`.
    public static func hasPrimary(_ activeBreak: ActiveBreakState) -> Bool {
        activeBreak.needsYou || activeBreak.kind == .walk
    }

    /// The primary's label.
    public static func primaryTitle(_ activeBreak: ActiveBreakState) -> String {
        if activeBreak.needsYou { return "Back to work" }
        return activeBreak.welcomeBack ? "Welcome back" : "I'm back"
    }
}
