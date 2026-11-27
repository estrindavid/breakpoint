import SwiftUI
import BreakpointRuntime

// The coach family (SPEC §3.12): one visual language for the tour's coach lines and the first-use
// hints. A small mint dot marks every line that teaches (at the end of a coach line's pointer, at
// the head of a hint); the words are 13 pt regular at the body step on pop-ups, 16 pt on the break
// screen; keys are keycaps. Neutral otherwise, so the surface they sit on stays itself.

/// The coach family's mark: a small mint target (a 4 pt dot inside a 1 pt ring, 9 pt across), so
/// it never reads as a status dot (a solid dot in the popover means a connected tool). A faint dark
/// halo keeps it legible on any wallpaper, card or break screen.
public struct CoachDot: View {
    private let traits = DesignTraits()

    public init() {}

    public var body: some View {
        ZStack {
            Circle().fill(Theme.Colors.scrim.opacity(0.35))
            Circle().strokeBorder(Theme.Colors.mint.opacity(traits.increaseContrast ? 1 : 0.7), lineWidth: 1)
            Circle().fill(Theme.Colors.mint).frame(width: 4, height: 4)
        }
        .frame(width: Theme.Layout.coachDot, height: Theme.Layout.coachDot)
        .accessibilityHidden(true)
    }
}

/// Words and keycaps in one row (a hint's line).
struct CoachPieces: View {
    let pieces: [KeyHint.Piece]
    var compactKeys = true

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let text):
                    Text(text).lineLimit(1)
                case .key(let key):
                    Keycap(key, compact: compactKeys)
                }
            }
        }
    }

    static func spoken(_ pieces: [KeyHint.Piece]) -> String {
        pieces.map { piece -> String in
            switch piece {
            case .text(let text): return text
            case .key(let key): return Keycap.spokenName(key)
            }
        }
        .joined(separator: " ")
    }
}

/// A first-use hint on a pop-up or in the popover (SPEC §3.12): the coach dot, then one line in
/// the coach lines' type and colour. It never takes a click of its own.
///
/// `HintLine("Start, or carry on: it asks again later.")`
public struct HintLine: View {
    private let pieces: [KeyHint.Piece]
    private let traits = DesignTraits()

    public init(_ text: String) { self.pieces = [.text(text)] }
    public init(_ pieces: [KeyHint.Piece]) { self.pieces = pieces }

    public var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.xs) {
            CoachDot()
            CoachPieces(pieces: pieces)
                .minimumScaleFactor(0.85)
        }
        .font(Theme.Typography.coach)
        .foregroundStyle(Color.white.opacity(traits.increaseContrast ? 0.95 : Theme.TextStep.body.opacity))
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tip: " + CoachPieces.spoken(pieces))
    }
}

/// The hairline pointer of a coach line: a 1 pt line (55% white) that ends in the coach dot on the
/// surface it points at. Increase Contrast: a brighter line.
public struct CoachStem: View {
    var length: CGFloat
    /// The dot at the top (pointing up) or the leading end (pointing left).
    var horizontal = false
    private let traits = DesignTraits()

    public init(length: CGFloat, horizontal: Bool = false) {
        self.length = length
        self.horizontal = horizontal
    }

    public var body: some View {
        let line = Color.white.opacity(traits.increaseContrast ? 0.8 : 0.55)
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            CoachDot()
            Rectangle().fill(line)
                .frame(width: horizontal ? length - Theme.Layout.coachDot : 1,
                       height: horizontal ? 1 : length - Theme.Layout.coachDot)
        }
        .accessibilityHidden(true)
    }
}

/// A coach line on the break screen (the tour's, and the first real break's hint): a capsule of
/// 16 pt words on a dark scrim, with a hairline pointer up to the agent chip or left to the
/// controls. No glass: the break screen is its own backdrop.
public struct OverlayCoachLine: View {
    public enum Pointing: Sendable { case up, leading }

    private let pieces: [KeyHint.Piece]
    private let pointing: Pointing
    private let isHint: Bool
    private let traits = DesignTraits()

    public init(_ text: String, pointing: Pointing) {
        self.init([.text(text)], pointing: pointing)
    }

    /// `isHint`: read as a tip by VoiceOver (the first real break), not as a tour step.
    public init(_ pieces: [KeyHint.Piece], pointing: Pointing, isHint: Bool = false) {
        self.pieces = pieces
        self.pointing = pointing
        self.isHint = isHint
    }

    public var body: some View {
        let layout = pointing == .up ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            CoachStem(length: 22, horizontal: pointing == .leading)
            CoachPieces(pieces: pieces, compactKeys: false)
                .font(Theme.Typography.overlayCoach)
                .foregroundStyle(Color.white.opacity(traits.increaseContrast ? 1 : Theme.TextStep.body.opacity))
                .fixedSize()
                .padding(.horizontal, Theme.Spacing.m)
                .frame(height: Theme.Layout.overlayCoachHeight)
                .background(Capsule(style: .circular).fill(Theme.Colors.scrim.opacity(traits.reduceTransparency ? 0.85 : 0.42)))
                .overlay(Capsule(style: .circular)
                    .strokeBorder(Color.white.opacity(traits.increaseContrast ? 0.40 : 0.16), lineWidth: 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((isHint ? "Tip: " : "") + CoachPieces.spoken(pieces))
    }
}
