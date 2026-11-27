import SwiftUI

/// A capsule chip (SPEC §3.4 cue chip, §3.8 state chips). 24 pt, 12 pt semibold.
/// - `.neutral` style: 12% white fill, 85% text (the `move` cue chip).
/// - Toned styles (`.agent`, `.needsYou`, `.mint`): tinted fill at 18% with the tone's colour as
///   text, plus an optional leading dot, for popover state chips ("working", "needs you", "idle").
public struct Chip: View {
    private let text: String
    private let tone: Theme.Tone
    private let showsDot: Bool
    private let size: Size
    @Environment(\.colorScheme) private var scheme

    /// `.regular`: 24 pt, 12 pt semibold (the `move` cue chip). `.small`: 20 pt, 11 pt semibold,
    /// for state chips inside a 36 pt row (popover agents), so the project name keeps its room.
    public enum Size: Sendable { case regular, small }

    public init(_ text: String, tone: Theme.Tone = .neutral, showsDot: Bool = false, size: Size = .regular) {
        self.text = text
        self.tone = tone
        self.showsDot = showsDot
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                StatusDot(tone: tone, diameter: 6)
            }
            Text(text).lineLimit(1)
        }
        .font(size == .regular ? Theme.Typography.cueChip : Theme.Typography.smallChip)
        .foregroundStyle(foreground)
        .padding(.horizontal, size == .regular ? 10 : 8)
        .frame(height: size == .regular ? Theme.Layout.cueChipHeight : Theme.Layout.smallChipHeight)
        .background(Capsule(style: .circular).fill(background))
    }

    private var foreground: Color {
        switch tone {
        case .neutral, .brand: return scheme == .dark ? Theme.Colors.white(.body) : Color.primary.opacity(0.8)
        default: return Theme.Colors.solid(for: tone)
        }
    }

    private var background: Color {
        switch tone {
        case .neutral, .brand: return (scheme == .dark ? Color.white : Color.black).opacity(scheme == .dark ? 0.12 : 0.06)
        default: return Theme.Colors.solid(for: tone).opacity(0.16)
        }
    }
}

/// The overlay's agent chip (SPEC §3.3 row 1): glass-free capsule 28 pt, an 8 pt dot and 13 pt
/// semibold text. Working: indigo dot pulsing at 0.5 Hz. Done: mint. Needs you: amber.
/// Without a dot (`tone == nil`) it shows plain 60% text, e.g. the time of day.
public struct AgentChip: View {
    private let text: String
    private let tone: Theme.Tone?
    private let pulsing: Bool
    private let traits = DesignTraits()

    public init(_ text: String, tone: Theme.Tone?, pulsing: Bool = false) {
        self.text = text
        self.tone = tone
        self.pulsing = pulsing
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let tone {
                StatusDot(tone: tone, pulsing: pulsing)
            }
            Text(text)
                .font(Theme.Typography.agentChip)
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(tone == nil ? traits.secondaryOpacity : 0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, tone == nil ? 0 : 12)
        .frame(height: Theme.Layout.agentChipHeight)
        .background {
            if tone != nil {
                Capsule(style: .circular).fill(Color.white.opacity(0.10))
                    .overlay(Capsule(style: .circular).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
        }
        .animation(traits.animation(.agentChipColor), value: tone)
        .accessibilityElement(children: .combine)
    }
}

/// A 1 pt line. On dark surfaces white at 25%; on windows the system separator.
public struct Hairline: View {
    private let width: CGFloat?
    private let vertical: Bool
    @Environment(\.colorScheme) private var scheme

    /// `width` nil fills the available width (or height when `vertical`).
    public init(width: CGFloat? = Theme.Layout.hairlineWidth, vertical: Bool = false) {
        self.width = width
        self.vertical = vertical
    }

    public var body: some View {
        Rectangle()
            .fill(scheme == .dark ? Color.white.opacity(Theme.TextStep.hairline.opacity) : Color.black.opacity(0.12))
            .frame(width: vertical ? 1 : width, height: vertical ? width : 1)
            .frame(maxWidth: (width == nil && !vertical) ? .infinity : nil)
            .accessibilityHidden(true)
    }
}

/// A 16 pt × button for the top-leading corner of self-dismissing pop-ups, shown on hover
/// (SPEC §3.0). Place it with `.overlay(alignment: .topLeading)` and offset it half outside.
public struct HoverCloseButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: Theme.Layout.closeButton, height: Theme.Layout.closeButton)
                .background(Circle().fill(Theme.Colors.solidPopup))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(PointerResponseStyle(Circle(), tone: .glass, lifts: false))
        .accessibilityLabel("Close")
    }
}
