import Foundation

// Pure geometry of the pop-up motion (SPEC §4.6 "Liquid pop-ups"): how a pop-up's glass grows
// out of a point, how it leaves, and how the nudge card becomes the countdown chip. Values in,
// values out, so the live panels and the frame-by-frame film draw exactly the same shapes.
// Foundation only: plain Doubles; BreakpointKit converts to CoreGraphics.

/// A rounded rectangle: top-left corner, size and corner radius.
///
/// The y axis is whatever the caller uses (y down inside a view, y up on screen): the morph only
/// interpolates, so it never needs to know.
public struct MorphShape: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var radius: Double

    public init(x: Double, y: Double, width: Double, height: Double, radius: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.radius = radius
    }

    /// A circle of `diameter` at (`x`, `y`).
    public static func circle(x: Double, y: Double, diameter: Double) -> MorphShape {
        MorphShape(x: x, y: y, width: diameter, height: diameter, radius: diameter / 2)
    }

    /// Every value interpolated by `t` (not clamped, so a spring's overshoot carries through).
    public func interpolated(to other: MorphShape, _ t: Double) -> MorphShape {
        MorphShape(x: LiquidMotion.lerp(x, other.x, t), y: LiquidMotion.lerp(y, other.y, t),
                   width: LiquidMotion.lerp(width, other.width, t), height: LiquidMotion.lerp(height, other.height, t),
                   radius: LiquidMotion.lerp(radius, other.radius, t))
    }
}

public enum LiquidMotion {
    // MARK: Curves

    /// The unit step response of a spring with SwiftUI's parameters (`spring(response:dampingFraction:)`:
    /// mass 1, stiffness (2π / response)², damping 4π · dampingFraction / response), `t` seconds in.
    /// 0 before the start; above 1 while it overshoots (damping < 1).
    public static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let zeta = damping
        if zeta >= 1 {
            // Critically damped (over-damped values are treated as critical).
            return 1 - exp(-omega * t) * (1 + omega * t)
        }
        let decay = zeta * omega
        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-decay * t) * (cos(omegaD * t) + decay / omegaD * sin(omegaD * t))
    }

    /// A CSS-style cubic Bézier timing curve (control points (x1, y1), (x2, y2)) at time
    /// fraction `x` (clamped to 0…1). The same curves as SwiftUI's `timingCurve`.
    public static func timingCurve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bezier(_ a: Double, _ b: Double, _ s: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        // Solve bezier_x(s) = x by bisection (monotonic for 0 ≤ x1, x2 ≤ 1).
        var low = 0.0, high = 1.0, s = x
        for _ in 0..<40 {
            s = (low + high) / 2
            if bezier(x1, x2, s) < x { low = s } else { high = s }
        }
        return bezier(y1, y2, s)
    }

    /// Hermite smoothstep: 0 at or below `edge0`, 1 at or above `edge1`.
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    // MARK: Constants

    /// Arrival: the glass springs open, settling with the faintest overshoot (damping ≥ 0.8, §4.6).
    public static let arrivalResponse: Double = 0.5
    public static let arrivalDamping: Double = 0.82
    /// The arrival has settled (spring within 0.5% of rest) by this time.
    public static let arrivalSettles: TimeInterval = 0.6
    /// The seed the glass grows from: a small capsule hanging from the card's top edge.
    public static let seedWidthFraction: Double = 0.22
    public static let seedHeightFraction: Double = 0.18
    public static let seedHeightRange: ClosedRange<Double> = 8...14
    /// The height trails the width by this much of the progress, so the glass spreads along the
    /// menu bar first and then drops open (and, leaving, folds up first and then draws in).
    public static let heightLag: Double = 0.18
    /// The content comes into focus over this part of the progress (and leaves over it).
    public static let contentWindow: ClosedRange<Double> = 0.45...0.95
    public static let contentBlur: Double = 6
    public static let contentDrop: Double = 6
    /// Leaving after a timeout: retracts into its seed while drifting up 4 pt (§4.6).
    public static let retractDrift: Double = 4
    /// Leaving after a timeout, the glass folds over this last part of the progress (the words
    /// fade over the first part).
    public static let retractGlassShare: Double = 0.75
    /// Leaving after an action or withdrawal: a small settle towards the top edge as it fades.
    public static let fadeScale: Double = 0.96
    /// Leaving on Start: swells into the break screen as it fades (§3.1).
    public static let swellScale: Double = 1.04

    // MARK: Pop-up poses

    /// What a pop-up is doing: one of these, at a progress from 0 (absent) to 1 (at rest).
    public enum Mode: Equatable, Sendable {
        /// Arriving: progress follows `spring` from 0 to 1.
        case grow
        /// Leaving after a timeout: progress eases from 1 to 0.
        case retract
        /// Leaving after an action or a withdrawal.
        case fade
        /// Leaving on Start.
        case swell
        /// Reduce Motion: an opacity cross-fade, nothing moves.
        case crossfade
        /// Handed to another surface that draws it from now on: gone at once.
        case handoff
    }

    /// One frame of a pop-up: where its glass is (inside the card's own rect, y down) and how its
    /// content and the whole are drawn.
    public struct Pose: Equatable, Sendable {
        public var shape: MorphShape
        public var shapeOpacity: Double
        public var contentOpacity: Double
        public var contentBlur: Double
        public var contentOffsetY: Double
        /// Scale of the whole, anchored at the top edge.
        public var scale: Double
        public var opacity: Double

        /// True when nothing differs from the card at rest (masks and effects can be dropped).
        public var isRest: Bool {
            shapeOpacity == 1 && contentOpacity == 1 && contentBlur == 0 && contentOffsetY == 0
                && scale == 1 && opacity == 1
        }
    }

    /// The pose of a card `width` × `height` with corner `radius`, `mode` at `progress`.
    /// `anchorX` places the seed: 0.5 under the middle of the top edge (pop-ups under the menu
    /// bar), 0 at the leading end (the countdown chip, which sits beside the pointer).
    public static func pose(_ mode: Mode, progress p: Double, width: Double, height: Double, radius: Double,
                            anchorX: Double = 0.5) -> Pose {
        let rest = MorphShape(x: 0, y: 0, width: width, height: height, radius: radius)
        switch mode {
        case .grow:
            let shape = grown(p, width: width, height: height, radius: radius, anchorX: anchorX)
            let c = smoothstep(contentWindow.lowerBound, contentWindow.upperBound, p)
            return Pose(shape: shape, shapeOpacity: smoothstep(0, 0.2, p),
                        contentOpacity: c, contentBlur: (1 - c) * contentBlur,
                        contentOffsetY: (1 - c) * -contentDrop, scale: 1, opacity: 1)
        case .retract:
            // The words go first while the glass holds, then the glass folds up into its seed.
            let q = min(1, max(0, p))
            var shape = grown(min(1, q / retractGlassShare), width: width, height: height, radius: radius, anchorX: anchorX)
            let c = smoothstep(retractGlassShare, 1, q)
            let drift = -(1 - q) * retractDrift
            shape.y += drift
            return Pose(shape: shape, shapeOpacity: smoothstep(0, 0.25, q / retractGlassShare),
                        contentOpacity: c, contentBlur: (1 - c) * contentBlur,
                        contentOffsetY: (1 - c) * -contentDrop + drift, scale: 1, opacity: 1)
        case .fade:
            let q = min(1, max(0, p))
            return Pose(shape: rest, shapeOpacity: 1, contentOpacity: 1, contentBlur: 0, contentOffsetY: 0,
                        scale: lerp(fadeScale, 1, q), opacity: q)
        case .swell:
            let q = min(1, max(0, p))
            return Pose(shape: rest, shapeOpacity: 1, contentOpacity: 1, contentBlur: 0, contentOffsetY: 0,
                        scale: lerp(swellScale, 1, q), opacity: q)
        case .crossfade:
            let q = min(1, max(0, p))
            return Pose(shape: rest, shapeOpacity: 1, contentOpacity: 1, contentBlur: 0, contentOffsetY: 0,
                        scale: 1, opacity: q)
        case .handoff:
            return Pose(shape: rest, shapeOpacity: 0, contentOpacity: 0, contentBlur: 0, contentOffsetY: 0,
                        scale: 1, opacity: 0)
        }
    }

    /// The glass between its seed (progress 0) and the full card (1); the height trails the width.
    static func grown(_ p: Double, width: Double, height: Double, radius: Double, anchorX: Double) -> MorphShape {
        let seedHeight = min(height, min(seedHeightRange.upperBound, max(seedHeightRange.lowerBound, height * seedHeightFraction)))
        let seedWidth = min(width, max(seedHeight * 2, width * seedWidthFraction))
        // Progress may overshoot 1 (spring) but never goes below the seed.
        let pw = max(0, p)
        let ph = max(0, (p - heightLag) / (1 - heightLag))
        let w = lerp(seedWidth, width, pw)
        let h = lerp(seedHeight, height, ph)
        return MorphShape(x: (width - w) * anchorX, y: 0, width: w, height: h, radius: min(radius, h / 2))
    }

    // MARK: Nudge → countdown chip

    /// The card becomes the chip: the glass gathers in (height first), glides to the pointer and
    /// settles as the chip, while the badge travels and shrinks as one object (SPEC §3.2).
    public static let handoffResponse: Double = 0.6
    public static let handoffDamping: Double = 0.86
    /// The height gathers on a quicker spring than the glide.
    public static let handoffHeightResponse: Double = 0.42
    /// The card's words are gone by then (they blur out; nothing of them travels).
    public static let handoffCardFade: TimeInterval = 0.2
    /// The chip's words come in over this part of the glide.
    public static let handoffChipWindow: ClosedRange<Double> = 0.72...0.98
    /// Long enough for the spring to rest (within 0.1%); after this the chip is simply the chip.
    public static let handoffDuration: TimeInterval = 0.8

    /// One frame of the handoff.
    public struct HandoffFrame: Equatable, Sendable {
        /// The glass, in the caller's coordinates (on screen in the app).
        public var shape: MorphShape
        /// The badge, relative to the glass's top-left corner, y down.
        public var badge: MorphShape
        public var cardOpacity: Double
        public var cardBlur: Double
        /// The card's words shrink a little towards the badge as they go.
        public var cardScale: Double
        public var chipOpacity: Double
        public var finished: Bool
    }

    /// The handoff `t` seconds in, from the card `from` (with its badge `fromBadge`, relative to
    /// the card) to the chip `to` (badge `toBadge`). `to` may move between frames (the chip
    /// follows the pointer); the glide heads for wherever it is now.
    public static func handoff(at t: TimeInterval, from: MorphShape, to: MorphShape,
                               fromBadge: MorphShape, toBadge: MorphShape) -> HandoffFrame {
        guard t < handoffDuration else {
            return HandoffFrame(shape: to, badge: toBadge, cardOpacity: 0, cardBlur: contentBlur, cardScale: 0.85,
                                chipOpacity: 1, finished: true)
        }
        let s = spring(t, response: handoffResponse, damping: handoffDamping)
        let sh = spring(t, response: handoffHeightResponse, damping: 1)
        var shape = from.interpolated(to: to, s)
        shape.height = lerp(from.height, to.height, sh)
        shape.radius = min(lerp(from.radius, to.radius, s), shape.height / 2)
        let fade = smoothstep(0, handoffCardFade, t)
        return HandoffFrame(shape: shape, badge: fromBadge.interpolated(to: toBadge, s),
                            cardOpacity: 1 - fade, cardBlur: fade * contentBlur, cardScale: lerp(1, 0.85, fade),
                            chipOpacity: smoothstep(handoffChipWindow.lowerBound, handoffChipWindow.upperBound, s),
                            finished: false)
    }
}
