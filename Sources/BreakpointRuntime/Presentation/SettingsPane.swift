import Foundation

// SPEC §3.9. The settings panes both apps show, in sidebar order, with their groups and icons
// (SF Symbol names; the Windows app maps them to its own glyphs).

/// The settings panes, in sidebar order, with their groups and icons.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case breaks, routine, pauses, windDown, integrations, general, privacy, about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .breaks: return "Breaks"
        case .routine: return "Routine"
        case .pauses: return "Pauses"
        case .windDown: return "Wind-down"
        case .integrations: return "Integrations"
        case .general: return "General"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    public var systemImage: String {
        switch self {
        case .breaks: return "timer"
        case .routine: return "figure.arms.open"
        case .pauses: return "pause"
        case .windDown: return "moon"
        case .integrations: return "point.3.connected.trianglepath.dotted"
        case .general: return "gearshape"
        case .privacy: return "hand.raised"
        case .about: return "info"
        }
    }

    /// Sidebar group: Breaks · Connections · You.
    public var group: String {
        switch self {
        case .breaks, .routine, .pauses, .windDown: return "Breaks"
        case .integrations: return "Connections"
        case .general, .privacy, .about: return "You"
        }
    }

    /// Position in the sidebar (drives the tile colour ramp).
    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Where the next opening of the settings window should land (set by the popover's About and
/// Connect…, consumed by the settings window when it shows).
@MainActor
public enum SettingsNavigator {
    public static var pendingPane: SettingsPane?
}
