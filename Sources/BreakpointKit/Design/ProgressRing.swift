import SwiftUI

/// A circular progress ring (SPEC §3.3–3.4, §3.8): starts at 12 o'clock, fills clockwise, round
/// caps. Used for the 44 pt still-time ring, the 140 / 160 pt break rings, the 2 pt auto-start
/// sweep and the 14 pt Skip guard. Content (e.g. a timer) goes in `label`.
public struct ProgressRing<Label: View>: View {
    private let progress: Double
    private let lineWidth: CGFloat
    private let tint: AnyShapeStyle
    private let track: Color
    private let label: Label

    public init(progress: Double, lineWidth: CGFloat = 4, tint: some ShapeStyle = Theme.Colors.mint,
                track: Color = Color.white.opacity(0.14), @ViewBuilder label: () -> Label) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.tint = AnyShapeStyle(tint)
        self.track = track
        self.label = label()
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label
        }
        .padding(lineWidth / 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent")
    }
}

extension ProgressRing where Label == EmptyView {
    public init(progress: Double, lineWidth: CGFloat = 4, tint: some ShapeStyle = Theme.Colors.mint,
                track: Color = Color.white.opacity(0.14)) {
        self.init(progress: progress, lineWidth: lineWidth, tint: tint, track: track) { EmptyView() }
    }
}

/// A number or duration that rolls per digit when it changes (SPEC §4.3, R-F6): monospaced digits
/// and the numeric-text transition, 0.25 s. Under Reduce Motion it cross-fades.
public struct RollingNumber: View {
    private let text: String
    private let value: Double
    private let font: Font
    private let countsDown: Bool
    private let traits = DesignTraits()

    /// - Parameters:
    ///   - text: what to show, e.g. "0:19" or "6 min".
    ///   - value: the numeric value behind it (drives the roll direction).
    ///   - countsDown: digits roll downward when the value decreases.
    public init(_ text: String, value: Double, font: Font = Theme.Typography.timer, countsDown: Bool = true) {
        self.text = text
        self.value = value
        self.font = font
        self.countsDown = countsDown
    }

    public var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .contentTransition(traits.reduceMotion ? .opacity : .numericText(countsDown: countsDown))
            .animation(traits.animation(.digitRoll), value: value)
    }
}
