import SwiftUI
import BreakpointCore
import BreakpointRuntime

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

/// The single coloured badge of a pop-up (SPEC §3.0, §3.1): a circle in the Breakpoint gradient
/// (break kinds), indigo (agent working) or amber (needs you), with a white SF Symbol.
///
/// Sizes: 44 pt nudge, 32 pt away note, 28 pt resume card, 22 pt countdown chip; the symbol is
/// scaled to match (20 pt at 44). `ringProgress` draws the 2 pt white-80% ring that sweeps around
/// the badge during eye-rest auto-start (§3.1), 3 pt outside the circle.
public struct KindBadge: View {
    private let symbol: String
    private let tone: Theme.Tone
    private let diameter: CGFloat
    private let ringProgress: Double?

    public init(kind: BreakKind, diameter: CGFloat = Theme.Layout.badge, ringProgress: Double? = nil) {
        self.symbol = kind.symbolName
        self.tone = .brand
        self.diameter = diameter
        self.ringProgress = ringProgress
    }

    public init(symbol: String, tone: Theme.Tone, diameter: CGFloat = Theme.Layout.badge, ringProgress: Double? = nil) {
        self.symbol = symbol
        self.tone = tone
        self.diameter = diameter
        self.ringProgress = ringProgress
    }

    public var body: some View {
        ZStack {
            Circle().fill(Theme.Colors.fill(for: tone))
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            Image(systemName: symbol)
                .font(.system(size: (diameter * Theme.Layout.badgeSymbol / Theme.Layout.badge).rounded(), weight: .semibold))
                .foregroundStyle(tone == .needsYou ? Theme.Colors.onAccent : .white)
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            if let ringProgress {
                ProgressRing(progress: ringProgress, lineWidth: 2, tint: .white.opacity(0.8), track: .clear)
                    .padding(-4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small filled or hollow dot (agent chip, popover status chips, menu text). The working dot
/// pulses at 0.5 Hz (static under Reduce Motion).
public struct StatusDot: View {
    public enum Style: Sendable {
        case filled, hollow
    }

    private let tone: Theme.Tone
    private let style: Style
    private let diameter: CGFloat
    private let pulsing: Bool
    private let traits = DesignTraits()

    public init(tone: Theme.Tone, style: Style = .filled, diameter: CGFloat = Theme.Layout.agentChipDot, pulsing: Bool = false) {
        self.tone = tone
        self.style = style
        self.diameter = diameter
        self.pulsing = pulsing
    }

    public var body: some View {
        Group {
            if pulsing && traits.runsContinuousAnimations {
                TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
                    dot.opacity(Self.pulseOpacity(at: context.date))
                }
            } else {
                dot
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var dot: some View {
        switch style {
        case .filled: Circle().fill(Theme.Colors.solid(for: tone))
        case .hollow: Circle().strokeBorder(Theme.Colors.solid(for: tone), lineWidth: max(1.5, diameter / 5))
        }
    }

    /// Opacity of a 0.5 Hz pulse between 40% and 100% at `date`.
    public static func pulseOpacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate * Theme.Motion.pulseFrequency * 2 * .pi
        return 0.7 + 0.3 * cos(phase)
    }
}
