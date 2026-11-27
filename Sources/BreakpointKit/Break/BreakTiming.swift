import Foundation
import CoreGraphics
import BreakpointCore
import BreakpointRuntime

// Every timing the break screens use, in one place so it can be tuned. Values that SPEC §4.6
// fixes live in `Theme.Motion` and are referenced from here by name; values the spec
// leaves open (how fast a stack slides, how often the chip follows the pointer, the watchdog's
// cadence) are defined here. Behavioural constants (Skip guard, Esc interval, ceiling) live in
// `Timing` (Core) and are only referenced.

/// Tunable timings of the break screens that SPEC §4.6 does not fix.
public enum BreakTiming {
    // MARK: Pop-ups

    /// Panels below a dismissed or resized pop-up slide to their new place over this long.
    public static let stackSlide: TimeInterval = 0.25
    /// A pop-up's window shrinks this long after its content does, so the content's own
    /// animation is never clipped (the window grows at once).
    public static let panelShrinkDelay: TimeInterval = 0.45
    /// A pop-up evicted by a higher-priority one fades its window out over this long.
    public static let evictionFade: TimeInterval = Theme.Motion.popupOutActionDuration
    /// The countdown chip follows the pointer at this rate while visible (≤ 5 s at a time).
    public static let chipFollowInterval: TimeInterval = 1.0 / 60
    /// The auto-start badge ring animates linearly between the coordinator's 10 Hz updates.
    public static let autoStartRingStep: TimeInterval = 0.1
    /// The nudge's hover reveal (why-now, ×, keycaps) waits for the pointer to rest this long.
    public static var hoverRest: TimeInterval { Theme.Motion.hoverRestDelay }

    // MARK: Overlay

    /// The live overlay redraws its staged entrance, exit and Skip guard at display rate until
    /// this long after it appeared (the guard ring fills for `Timing.skipGuard`).
    public static var overlayLiveClockWindow: TimeInterval {
        max(Theme.Motion.overlayEntranceTotal, BackdropTimeline.entranceTotal, Timing.skipGuard) + 0.1
    }
    /// The aurora drifts so slowly that 15 frames a second is indistinguishable from 60 and costs
    /// a quarter of the energy over a 30-minute walk.
    public static let auroraFrameInterval: TimeInterval = 1.0 / 15
    /// Overlay exit: the content fades while the backdrop lets go in layers (SPEC §4.6); total.
    public static var overlayExitTotal: TimeInterval {
        max(Theme.Motion.overlayExitContent, BackdropTimeline.exitTotal)
    }
    /// Reduce Motion: the exit is one cross-fade of this length.
    public static var overlayExitReduced: TimeInterval { Theme.Motion.reduceMotionFade }
    /// `breathe` "In" / "Out" cross-fade around each turn.
    public static let breatheWordFade: TimeInterval = 0.5

    // MARK: Safety

    /// The main thread stamps the watchdog's heartbeat this often while an overlay is up.
    public static let heartbeatInterval: TimeInterval = 0.5
    /// The watchdog thread checks the heartbeat this often.
    public static let watchdogCheckInterval: TimeInterval = 0.25
    /// A heartbeat older than this means the main thread is stuck: the app exits (SPEC §7.2).
    public static let watchdogLimit: TimeInterval = 3
    /// The overlay controller's own backstop closes its windows this long after the hard ceiling
    /// if the coordinator has not ended the break by then (the coordinator records the outcome).
    public static let ceilingBackstopGrace: TimeInterval = 2

    /// The hard ceiling for a break (SPEC §3.3): planned length + extensions + 60 s; `walk` 30 min.
    /// `ActiveBreakState.plannedLength` already includes extensions.
    public static func ceiling(for activeBreak: ActiveBreakState) -> TimeInterval {
        activeBreak.kind == .walk ? Timing.walkCeiling : activeBreak.plannedLength + Timing.overlayCeilingSlack
    }
}

// MARK: - Easing

/// A CSS-style cubic Bézier timing curve, evaluated exactly (Newton–Raphson with bisection
/// fallback). `Theme.Motion.popupIn` is `.25, .1, .25, 1`.
public struct CubicBezier: Sendable {
    public let x1, y1, x2, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    /// CSS `ease` (the pop-up entrance curve).
    public static let ease = CubicBezier(0.25, 0.1, 0.25, 1)
    public static let easeOut = CubicBezier(0, 0, 0.58, 1)
    public static let easeIn = CubicBezier(0.42, 0, 1, 1)
    public static let easeInOut = CubicBezier(0.42, 0, 0.58, 1)

    private func sample(_ t: Double, _ a1: Double, _ a2: Double) -> Double {
        let c = 3 * a1, b = 3 * (a2 - a1) - c, a = 1 - c - b
        return ((a * t + b) * t + c) * t
    }

    private func slope(_ t: Double, _ a1: Double, _ a2: Double) -> Double {
        let c = 3 * a1, b = 3 * (a2 - a1) - c, a = 1 - c - b
        return (3 * a * t + 2 * b) * t + c
    }

    /// The curve's value at progress `x` (0…1, clamped).
    public func callAsFunction(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        if x == 0 || x == 1 { return x }
        var t = x
        for _ in 0..<8 {
            let error = sample(t, x1, x2) - x
            if abs(error) < 1e-6 { return sample(t, y1, y2) }
            let d = slope(t, x1, x2)
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<30 {
            let value = sample(t, x1, x2)
            if abs(value - x) < 1e-6 { break }
            if value < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sample(t, y1, y2)
    }
}

// MARK: - Overlay entrance and exit (SPEC §4.6)

/// The overlay's staged entrance and exit as pure functions of time, so the live view, the
/// snapshots, the films and the demo's step-through all draw exactly the same frames.
///
/// The backdrop's layers follow `BackdropTimeline` (Core): the desktop softens (blur, 0–0.5 s),
/// the edges darken (vignette), the screen settles into deep tones (scrim, 0.15–0.75 s), and the
/// aurora's light rises from behind the words and spreads (0.35–1.55 s). Over that, the content:
///
/// | t (s) | Event |
/// |---|---|
/// | 0.55 | title: opacity 0 → 1 and blur 8 → 0 over 0.35 s (focus pull) |
/// | 0.95 | instruction, kind line, hairline, guide: opacity + 6 pt rise over 0.35 s |
/// | 1.25 | agent chip, controls, hint: opacity over 0.3 s (done ≈ 1.55 s) |
///
/// Exit: the content fades over 0.2 s while the title defocuses; the aurora goes with it, the
/// scrim and vignette lift, and the desktop comes back into focus last (0.75 s in all). Reduce
/// Motion: one 0.25 s fade in, one 0.2 s fade out, no blur, rise or bloom.
public struct OverlayFrame: Equatable, Sendable {
    /// The backdrop's layers.
    public var atmosphere: BackdropFrame = .settled
    public var titleOpacity: Double = 1
    public var titleBlur: CGFloat = 0
    public var bodyOpacity: Double = 1
    public var bodyRise: CGFloat = 0
    public var chromeOpacity: Double = 1

    public init() {}

    /// The desktop blur's opacity (the backdrop's first layer in, last out). Films fade their
    /// blurred desktop by this.
    public var backdrop: Double {
        get { atmosphere.blur }
        set { atmosphere = BackdropFrame(uniform: newValue) }
    }

    /// Fully settled.
    public static let settled = OverlayFrame()

    /// The frame `t` seconds into the entrance.
    public static func entrance(at t: TimeInterval, reduceMotion: Bool) -> OverlayFrame {
        typealias M = Theme.Motion
        var f = OverlayFrame()
        if reduceMotion {
            let p = progress(t, start: 0, duration: M.overlayEntranceReduced)
            f.atmosphere = BackdropFrame(uniform: p)
            f.titleOpacity = p; f.bodyOpacity = p; f.chromeOpacity = p
            return f
        }
        f.atmosphere = BackdropTimeline.entrance(at: t)
        let title = CubicBezier.ease(progress(t, start: M.overlayTitleAt, duration: M.overlayTitleDuration))
        f.titleOpacity = title
        f.titleBlur = M.overlayTitleBlur * CGFloat(1 - title)
        let body = CubicBezier.ease(progress(t, start: M.overlayBodyAt, duration: M.overlayBodyDuration))
        f.bodyOpacity = body
        f.bodyRise = M.overlayBodyRise * CGFloat(1 - body)
        f.chromeOpacity = CubicBezier.ease(progress(t, start: M.overlayChromeAt, duration: M.overlayChromeDuration))
        return f
    }

    /// The frame `t` seconds into the exit, starting from a settled overlay.
    public static func exit(at t: TimeInterval, reduceMotion: Bool) -> OverlayFrame {
        typealias M = Theme.Motion
        var f = OverlayFrame()
        if reduceMotion {
            let p = 1 - progress(t, start: 0, duration: BreakTiming.overlayExitReduced)
            f.atmosphere = BackdropFrame(uniform: p)
            f.titleOpacity = p; f.bodyOpacity = p; f.chromeOpacity = p
            return f
        }
        let content = 1 - CubicBezier.easeOut(progress(t, start: 0, duration: M.overlayExitContent))
        f.titleOpacity = content; f.bodyOpacity = content; f.chromeOpacity = content
        f.titleBlur = M.overlayExitTitleBlur * CGFloat(1 - content)
        f.atmosphere = BackdropTimeline.exit(at: t)
        return f
    }

    /// Exit length for the current Reduce Motion setting.
    public static func exitDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? BreakTiming.overlayExitReduced : BreakTiming.overlayExitTotal
    }

    static func progress(_ t: TimeInterval, start: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return t >= start ? 1 : 0 }
        return min(max((t - start) / duration, 0), 1)
    }
}

// MARK: - Breathing (SPEC §3.4)

/// The `breathe` ring as a function of seconds since the break started: 5.5 s in, 5.5 s out,
/// sine ease-in-out.
public enum BreathCycle {
    /// 0 (exhaled) … 1 (inhaled).
    public static func fullness(at t: TimeInterval) -> Double {
        let half = Theme.Motion.breatheHalfCycle
        let phase = max(0, t).truncatingRemainder(dividingBy: 2 * half)
        let p = phase < half ? phase / half : 1 - (phase - half) / half
        return 0.5 - 0.5 * cos(.pi * p)
    }

    /// True while breathing in.
    public static func isInhaling(at t: TimeInterval) -> Bool {
        max(0, t).truncatingRemainder(dividingBy: 2 * Theme.Motion.breatheHalfCycle) < Theme.Motion.breatheHalfCycle
    }

    /// Opacity of the "In" word (the "Out" word is 1 − this): cross-fades around each turn.
    public static func inWordOpacity(at t: TimeInterval) -> Double {
        let half = Theme.Motion.breatheHalfCycle
        let fade = BreakTiming.breatheWordFade
        let phase = max(0, t).truncatingRemainder(dividingBy: 2 * half)
        // Distance into the current half; the word swaps across each boundary.
        func ramp(_ x: Double) -> Double { min(max(x / fade + 0.5, 0), 1) }
        if phase < half {
            // In: fades in around t = 0 (from the previous Out) and out around t = half.
            return min(ramp(phase), ramp(half - phase))
        }
        return 1 - min(ramp(phase - half), ramp(2 * half - phase))
    }
}
