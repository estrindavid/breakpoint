import Foundation

// The break overlay's backdrop as pure functions of time (SPEC §3.3, §4.6): how the screen
// softens into a break, the slow aurora while it lasts, and how it lets go. The live overlay,
// the snapshots and the films all draw these same values. Foundation only, so it is unit-tested.

/// The backdrop's layers at one moment, each 0 (absent) … 1 (at rest).
public struct BackdropFrame: Equatable, Sendable {
    /// The behind-window blur of the desktop. The system blur's radius is fixed, so its opacity is
    /// what moves: the desktop's edges dissolve first.
    public var blur: Double
    /// The vignette: the display's edges darken a beat before the middle.
    public var vignette: Double
    /// The deep scrim over the whole display.
    public var dim: Double
    /// The aurora's light, as a share of its resting strength.
    public var glow: Double
    /// How far the aurora's lights have spread: 0 gathered behind the words, 1 at their drifting
    /// places.
    public var bloom: Double

    public init(blur: Double, vignette: Double, dim: Double, glow: Double, bloom: Double) {
        self.blur = blur
        self.vignette = vignette
        self.dim = dim
        self.glow = glow
        self.bloom = bloom
    }

    /// Every layer at the same value (Reduce Motion: one cross-fade).
    public init(uniform value: Double) {
        self.init(blur: value, vignette: value, dim: value, glow: value, bloom: 1)
    }

    /// Fully in.
    public static let settled = BackdropFrame(uniform: 1)
    /// Nothing drawn.
    public static let clear = BackdropFrame(blur: 0, vignette: 0, dim: 0, glow: 0, bloom: 0)
}

/// When each backdrop layer moves.
///
/// Entrance (the content's own steps, title at 0.55 s, run on top of this):
///
/// | t (s) | Layer |
/// |---|---|
/// | 0.00 → 0.50 | blur fades in, fast then gentle (the desktop softens first) |
/// | 0.05 → 0.60 | vignette: the edges darken |
/// | 0.15 → 0.75 | scrim: the whole screen settles into deep tones |
/// | 0.35 → 1.55 | aurora: its light rises from behind the words and spreads to its places |
///
/// Exit (the content fades over its first 0.2 s):
///
/// | t (s) | Layer |
/// |---|---|
/// | 0.00 → 0.35 | aurora fades with the content |
/// | 0.15 → 0.55 | scrim lifts |
/// | 0.20 → 0.60 | vignette lifts |
/// | 0.30 → 0.75 | blur dissolves last: the desktop comes back into focus |
public enum BackdropTimeline {
    /// A layer's move: when it starts and how long it takes.
    public struct Ramp: Equatable, Sendable {
        public var start: TimeInterval
        public var duration: TimeInterval
        public var end: TimeInterval { start + duration }

        public init(_ start: TimeInterval, _ duration: TimeInterval) {
            self.start = start
            self.duration = duration
        }

        /// Linear progress 0…1 at `t`.
        public func progress(at t: TimeInterval) -> Double {
            guard duration > 0 else { return t >= start ? 1 : 0 }
            return min(max((t - start) / duration, 0), 1)
        }
    }

    // Entrance
    public static let blurIn = Ramp(0, 0.5)
    public static let vignetteIn = Ramp(0.05, 0.55)
    public static let dimIn = Ramp(0.15, 0.6)
    public static let glowIn = Ramp(0.35, 1.2)

    // Exit
    public static let glowOut = Ramp(0, 0.35)
    public static let dimOut = Ramp(0.15, 0.4)
    public static let vignetteOut = Ramp(0.2, 0.4)
    public static let blurOut = Ramp(0.3, 0.45)

    /// The backdrop is fully in this long after the overlay appears.
    public static var entranceTotal: TimeInterval { [blurIn, vignetteIn, dimIn, glowIn].map(\.end).max()! }
    /// The backdrop is gone this long after the exit starts.
    public static var exitTotal: TimeInterval { [glowOut, dimOut, vignetteOut, blurOut].map(\.end).max()! }

    /// The backdrop `t` seconds after the overlay appeared.
    public static func entrance(at t: TimeInterval) -> BackdropFrame {
        let glow = Ease.out(glowIn.progress(at: t))
        return BackdropFrame(
            blur: Ease.outCubic(blurIn.progress(at: t)),
            vignette: Ease.inOut(vignetteIn.progress(at: t)),
            dim: Ease.inOut(dimIn.progress(at: t)),
            glow: glow,
            bloom: glow)
    }

    /// The backdrop `t` seconds into the exit, from a settled overlay. The lights stay where they
    /// are; only their strength goes.
    public static func exit(at t: TimeInterval) -> BackdropFrame {
        BackdropFrame(
            blur: 1 - Ease.inOut(blurOut.progress(at: t)),
            vignette: 1 - Ease.inOut(vignetteOut.progress(at: t)),
            dim: 1 - Ease.inOut(dimOut.progress(at: t)),
            glow: 1 - Ease.inOut(glowOut.progress(at: t)),
            bloom: 1)
    }

    /// Easing curves (all map 0 → 0 and 1 → 1, monotonic).
    public enum Ease {
        /// Quadratic ease-out.
        public static func out(_ p: Double) -> Double { 1 - (1 - p) * (1 - p) }
        /// Cubic ease-out: most of the change early.
        public static func outCubic(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
        /// Smoothstep.
        public static func inOut(_ p: Double) -> Double { p * p * (3 - 2 * p) }
    }
}

/// The aurora: five soft lights in Breakpoint's mint → indigo family drifting over the deep
/// scrim. Each moves on its own slow path, and every path repeats exactly once a minute, so the
/// light never seems to loop and any moment can be drawn again.
public enum AuroraField {
    /// One drift loop (SPEC §4.6: 60 s).
    public static let period: TimeInterval = 60

    public enum Hue: Sendable, CaseIterable {
        /// Breakpoint mint.
        case mint
        /// Between mint and indigo.
        case teal
        /// Breakpoint indigo.
        case indigo
        /// A deep blue, for the lower edge.
        case deep
    }

    /// A light at one moment. Positions are fractions of the display (0…1, may sit a little
    /// outside); the radius is a fraction of the display's longer side.
    public struct Light: Equatable, Sendable {
        public var hue: Hue
        public var x: Double
        public var y: Double
        public var radius: Double
        /// 0…1, before the layer's own strength.
        public var intensity: Double
    }

    /// Where the lights gather before they bloom (behind the title).
    public static let gatherPoint = (x: 0.5, y: 0.44)

    /// The loop phase 0…1 for `seconds` on the backdrop's clock.
    public static func phase(at seconds: TimeInterval) -> Double {
        let r = seconds.truncatingRemainder(dividingBy: period) / period
        return r < 0 ? r + 1 : r
    }

    /// The lights at loop `phase` (0…1), spread by `bloom` (0 gathered, 1 at rest).
    public static func lights(phase: Double, bloom: Double = 1) -> [Light] {
        let a = phase * 2 * .pi
        // Integer harmonics only, so every path closes at phase 1.
        let rest: [Light] = [
            Light(hue: .mint, x: 0.24 + 0.10 * sin(a), y: 0.26 + 0.08 * cos(a), radius: 0.50, intensity: 1),
            Light(hue: .teal, x: 0.60 + 0.12 * sin(2 * a + 1.3), y: 0.58 + 0.07 * cos(a + 2.1), radius: 0.40,
                  intensity: 0.75),
            Light(hue: .indigo, x: 0.80 - 0.10 * sin(a + 0.9), y: 0.80 - 0.08 * cos(a + 0.9), radius: 0.55,
                  intensity: 0.9),
            Light(hue: .deep, x: 0.14 + 0.07 * cos(a + 3.0), y: 0.92 + 0.05 * sin(2 * a), radius: 0.48,
                  intensity: 0.8),
            Light(hue: .mint, x: 0.86 + 0.05 * sin(a + 4.2), y: 0.14 + 0.06 * cos(2 * a + 0.5), radius: 0.32,
                  intensity: 0.45),
        ]
        let b = min(max(bloom, 0), 1)
        let spread = 0.45 + 0.55 * b
        let size = 0.7 + 0.3 * b
        return rest.map { light in
            var l = light
            l.x = gatherPoint.x + (light.x - gatherPoint.x) * spread
            l.y = gatherPoint.y + (light.y - gatherPoint.y) * spread
            l.radius = light.radius * size
            return l
        }
    }
}
