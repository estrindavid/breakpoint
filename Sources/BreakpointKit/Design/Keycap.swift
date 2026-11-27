import SwiftUI
import BreakpointRuntime

/// A key drawn as a keycap (SPEC §3.3 hint, §3.1 hover hotkeys): rounded rectangle, 1 pt rim,
/// 11 pt label. Inside a pressed `PillButton` it presses too. Use the key's symbol or short name:
/// "esc", "return", "⌃⌥⌘B", "→".
public struct Keycap: View {
    private let label: String
    private let compact: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlIsPressed) private var pressed
    private let traits = DesignTraits()

    /// `compact` keycaps (inside buttons) are 16 pt tall; regular ones 18 pt.
    public init(_ label: String, compact: Bool = false) {
        self.label = label
        self.compact = compact
    }

    public var body: some View {
        let base: Color = scheme == .dark ? .white : .black
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.keycap, style: .continuous)
        Text(label)
            .font(compact ? .system(size: 10, weight: .medium) : Theme.Typography.keycap)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 4 : 5)
            .frame(minWidth: compact ? 16 : 18, minHeight: compact ? 16 : 18)
            .foregroundStyle(labelColor)
            .background(shape.fill(base.opacity(pressed ? 0.16 : 0.08)))
            .overlay(shape.strokeBorder(base.opacity(traits.increaseContrast ? 0.45 : 0.22), lineWidth: 1))
            // Inside a pressed button the key goes down too: half a point, a little brighter.
            .offset(y: pressed && !traits.reduceMotion ? 0.5 : 0)
            .accessibilityLabel(Self.spokenName(label))
    }

    private var labelColor: Color {
        if scheme != .dark { return Color.primary.opacity(0.75) }
        return Color.white.opacity(traits.increaseContrast ? 0.85 : 0.75)
    }

    static func spokenName(_ label: String) -> String {
        switch label {
        case "esc": return "Escape"
        case "return", "⏎": return "Return"
        case "→": return "Right arrow"
        case "←": return "Left arrow"
        default: return label
        }
    }
}

/// A hint line of text and keycaps (SPEC §3.3 row 8): "[esc] [esc] to skip · [return] I'm back".
/// 11 pt at 50% (60% with Increase Contrast).
public struct KeyHint: View {
    public enum Piece: Hashable, Sendable {
        case text(String)
        case key(String)
    }

    private let pieces: [Piece]
    @Environment(\.colorScheme) private var scheme
    private let traits = DesignTraits()

    public init(_ pieces: [Piece]) { self.pieces = pieces }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let text):
                    Text(text)
                case .key(let key):
                    Keycap(key)
                }
            }
        }
        .font(Theme.Typography.hint)
        .foregroundStyle(scheme == .dark ? Color.white.opacity(traits.hintOpacity) : Color.secondary)
        .accessibilityElement(children: .combine)
    }
}
