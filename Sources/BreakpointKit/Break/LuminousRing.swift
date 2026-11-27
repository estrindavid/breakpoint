import SwiftUI
import BreakpointRuntime

// SPEC §3.4 (`move` step and pace ring, `walk` ring), §4.6 (completion mark).

/// The overlay's progress ring: a quiet track, a mint arc that brightens from its tail to its
/// head, and a soft glow at the head, so the ring reads as light on the aurora rather than a
/// drawn line. Starts at 12 o'clock and fills clockwise with round caps, like `ProgressRing`.
///
/// `tail` moves the arc's start off 12 o'clock (in turns; negative wraps back past the top), so
/// the same ring draws the `move` pace ring's travelling arc ("circle" steps) as well as its fill.
///
/// Increase Contrast: a solid mint arc and no glow.
struct LuminousRing<Label: View>: View {
    private let head: Double
    private let tail: Double
    private let lineWidth: CGFloat
    private let label: Label
    private let traits = DesignTraits()

    init(progress: Double, tail: Double = 0, lineWidth: CGFloat, @ViewBuilder label: () -> Label) {
        let head = min(max(progress, tail), tail + 1)
        self.head = tail == 0 ? min(max(head, 0), 1) : head
        self.tail = tail
        self.lineWidth = lineWidth
        self.label = label()
    }

    /// The lit length, in turns.
    private var length: Double { min(max(head - tail, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let radius = (diameter - lineWidth) / 2
            ZStack {
                Circle()
                    .inset(by: lineWidth / 2)
                    .stroke(Theme.Colors.white(.outline), lineWidth: lineWidth)
                if length > 0.0005 {
                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: 0, to: length)
                        .stroke(arc, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(360 * tail - 90))
                }
                if glows {
                    Circle()
                        .fill(Theme.Colors.mint)
                        .frame(width: lineWidth * Self.glowSize, height: lineWidth * Self.glowSize)
                        .blur(radius: lineWidth * Self.glowBlur)
                        .opacity(Self.glowOpacity)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(360 * head))
                        .allowsHitTesting(false)
                }
                label
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(tail == 0 ? "\(Int((length * 100).rounded())) percent" : "")
    }

    /// The head glow: this many stroke widths across, blurred by this many, at this opacity.
    static var glowSize: CGFloat { 4 }
    static var glowBlur: CGFloat { 1.5 }
    static var glowOpacity: Double { 0.6 }
    /// The arc's tail, as a share of the mint at its head.
    static var tailOpacity: Double { 0.3 }

    private var glows: Bool { !traits.increaseContrast && length > 0.005 }

    /// Dim at the tail, full mint at the head; dim again past the head so the round cap at the
    /// start never picks up the bright end. The gradient turns with the arc.
    private var arc: AnyShapeStyle {
        if traits.increaseContrast || length <= 0 { return AnyShapeStyle(Theme.Colors.mint) }
        let tailColour = Theme.Colors.mint.opacity(Self.tailOpacity)
        return AnyShapeStyle(AngularGradient(
            stops: [
                .init(color: tailColour, location: 0),
                .init(color: Theme.Colors.mint, location: length),
                .init(color: tailColour, location: min(1, length + 0.001) == 1 ? 1 : (1 + length) / 2),
                .init(color: tailColour, location: 1),
            ],
            center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
    }
}
