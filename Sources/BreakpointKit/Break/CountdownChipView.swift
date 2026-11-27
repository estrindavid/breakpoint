import SwiftUI
import BreakpointCore

// SPEC §3.2.

/// The countdown chip: glass capsule 32 pt (radius 16), 22 pt badge + "Eye rest in 5"
/// (13 pt semibold, rolling digit). It is the last rung of the warning ladder, so it says what
/// is coming and when, nothing else.
public struct CountdownChipView: View {
    private let kind: BreakKind
    private let remaining: TimeInterval
    private let traits = DesignTraits()

    public init(kind: BreakKind, remaining: TimeInterval) {
        self.kind = kind
        self.remaining = remaining
    }

    /// The badge's inset from the capsule's leading end (and, at 22 pt in 32, from top and bottom).
    public static let badgeInset: CGFloat = 5

    private var second: Int { Int(max(0, remaining).rounded(.up)) }

    public var body: some View {
        GlassCapsule(height: Theme.Layout.countdownChipHeight, leadingInset: Self.badgeInset, trailingInset: 13) {
            HStack(spacing: 8) {
                KindBadge(kind: kind, diameter: Theme.Layout.countdownChipBadge)
                Text(Copy.countdownChip(kind: kind, remaining: remaining))
                    .font(Theme.Typography.agentChip)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.white(.title))
                    .contentTransition(traits.reduceMotion ? .opacity : .numericText(countsDown: true))
                    .animation(traits.animation(.digitRoll), value: second)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
