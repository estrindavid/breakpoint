import SwiftUI
import BreakpointCore
import BreakpointRuntime

// Neutral glyphs for agent sources and tools in
// the popover's agent rows and the Integrations pane. Never a tool's own logo (identity, §4.1).

// `MenuBarGlyphs` (the SF Symbol for each source) lives in BreakpointRuntime
// (Presentation/Symbols.swift), shared with Windows.

/// A 20 pt rounded-square tile holding a source glyph (SPEC §3.8 agent rows). Neutral on dark
/// glass; on windows it uses a quiet fill that follows the system appearance.
struct SourceTile: View {
    let symbol: String
    var size: CGFloat = Theme.Layout.sourceTile
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: size * Theme.Radius.sourceTile / Theme.Layout.sourceTile, style: .continuous)
            .fill(scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: size * Theme.Radius.sourceTile / Theme.Layout.sourceTile, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: (size * 0.5).rounded(), weight: .semibold))
                    .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Color.primary.opacity(0.75)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
