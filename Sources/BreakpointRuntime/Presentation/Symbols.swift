import Foundation
import BreakpointCore

// The glyph each break kind and agent source is drawn with, named by SF Symbol (SPEC §3.1, §3.8).
// The macOS app draws the symbol itself; the Windows app maps each name to its own glyph
// (`BreakpointWindows/Design/Glyphs.swift`). Never a tool's own logo (identity, §4.1).

extension BreakKind {
    /// SF Symbol for the kind badge (SPEC §3.1).
    public var symbolName: String {
        switch self {
        case .eyes: return "eye"
        case .move: return "figure.arms.open"
        case .walk: return "figure.walk"
        case .breathe: return "wind"
        }
    }
}

/// Neutral glyphs for agent sources and tools in the popover's agent rows and the Integrations pane.
public enum MenuBarGlyphs {
    /// SF Symbol for an agent source tile (20 pt rounded square).
    public static func sourceSymbol(_ source: AgentSource) -> String {
        switch source {
        case .claudeCode: return "sparkle"
        case .cursor: return "cursorarrow.rays"
        case .codex: return "curlybraces"
        case .copilot: return "paperplane"
        case .gemini: return "sparkles"
        case .shell: return "terminal"
        default: return "circle.hexagongrid"
        }
    }

    /// SF Symbol for an integration row.
    public static func integrationSymbol(_ id: IntegrationID) -> String {
        sourceSymbol(id.source)
    }
}
