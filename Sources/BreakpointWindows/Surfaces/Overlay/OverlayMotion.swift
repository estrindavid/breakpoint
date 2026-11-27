import BreakpointCore
import BreakpointRuntime
import Foundation

// The break overlay's numbers and timelines (SPEC §3.3, §3.4, §4.6) that the Windows `Theme` does
// not carry: the macOS app keeps them in BreakpointKit (`Theme.Layout`, `Theme.Motion`,
// `BreakTiming`, `BreathCycle`, `CompletionFrame`), which Windows does not link. Same values, same
// pure functions of time, so both apps draw the same frames.

/// Sizes and timings of the break overlay.
enum OverlayMetrics {
    // Layout (SPEC §3.3)
    static let kindLineGap: Float = 16
    static let hairlineToRingTop: Float = 32
    static let hintGap: Float = 12
    static let skipGuardRing: Float = 14
    static let cueChipHeight: Float = 24
    static let smallChipHeight: Float = 20
    static let coachHeight: Float = 36
    static let coachGap: Float = 6
    static let coachStem: Float = 22
    static let paceTravelArc: Double = 0.22
    static let completionMarkEyes: Float = 64
    static let completionCheckWidth: Float = 0.42
    static let completionCheckStroke: Float = 1.5
    /// The other displays' timer: 13 pt, 40 DIPs below the top.
    static let otherDisplayTimerTop: Float = 40

    // Backdrop (SPEC §3.3, §4.8). macOS lays its 60% scrim over a live blur of the desktop; a
    // Windows overlay has no backdrop material, so the sharp desktop would show through a 60%
    // scrim. The scrim is heavier here to read the same: the desktop stays faintly present.
    static let scrimOpacity: Float = 0.86
    static let scrimOpacityHighContrast: Float = 0.93
    static let scrimOpacityAmbient: Float = 0.93
    static let vignetteOpacity: Float = 0.45
    static let hushOpacity: Float = 0.22
    static let hushRadius: Float = 0.42
    static let auroraDeepStrength: Float = 0.55
    static let auroraStrength: Float = 0.12
    static let auroraTeal = Colour(hex: 0x26A8B8)
    static let auroraDeep = Colour(hex: 0x2B3FB8)
    static let auroraDeepTones: [Colour] = [
        Colour(hex: 0x0A5A4C), Colour(hex: 0x0B4A63), Colour(hex: 0x232C82), Colour(hex: 0x0E1A5C),
    ]

    // Motion (SPEC §4.6)
    static let reduceMotionFade: Double = 0.2
    static let overlayExitContent: Double = 0.2
    static let escPulseDuration: Double = 0.3
    static let ambientWake: Double = 0.3
    static let agentChipColour: Double = 0.3
    static let moveStepDuration: Double = 0.3
    static let moveStepSlide: Float = 12
    static let breatheHalfCycle: Double = 5.5
    static let breatheWordFade: Double = 0.5
    static let breatheReducedFill: ClosedRange<Double> = 0.10...0.30
    static let paceWordFade: Double = 0.5
    static let paceWordTurnOpacity: Double = 0.35
    static let completionFade: Double = 0.2
    static let completionTitleSwap: Double = 0.3
    static let completionRingClose: Double = 0.45
    static let completionCheckAt: Double = 0.3
    static let completionCheckDraw: Double = 0.3

    // Safety (SPEC §3.3, §7.2)
    static let heartbeatInterval: TimeInterval = 0.5
    static let watchdogCheckInterval: TimeInterval = 0.25
    static let watchdogLimit: TimeInterval = 3
    static let ceilingBackstopGrace: TimeInterval = 2

    /// The hard ceiling for a break: planned length (with extensions) + 60 s; `walk` 30 min.
    static func ceiling(for active: ActiveBreakState) -> TimeInterval {
        active.kind == .walk ? Timing.walkCeiling : active.plannedLength + Timing.overlayCeilingSlack
    }
}

/// Timing curves (CSS cubic Béziers, evaluated exactly), as `CubicBezier` on the Mac.
struct OverlayCurve: Sendable {
    let x1, y1, x2, y2: Double

    static let ease = OverlayCurve(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    static let easeOut = OverlayCurve(x1: 0, y1: 0, x2: 0.58, y2: 1)
    static let easeInOut = OverlayCurve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)

    private func sample(_ t: Double, _ a1: Double, _ a2: Double) -> Double {
        let c = 3 * a1, b = 3 * (a2 - a1) - c, a = 1 - c - b
        return ((a * t + b) * t + c) * t
    }

    func callAsFunction(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        if x == 0 || x == 1 { return x }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            let value = sample(t, x1, x2)
            if abs(value - x) < 1e-6 { break }
            if value < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sample(t, y1, y2)
    }

    /// Linear progress 0…1 of `t` through `start` + `duration`.
    static func progress(_ t: Double, start: Double, duration: Double) -> Double {
        guard duration > 0 else { return t >= start ? 1 : 0 }
        return min(max((t - start) / duration, 0), 1)
    }
}

/// The `breathe` ring as a function of seconds since the break started: 5.5 s in, 5.5 s out, sine
/// ease-in-out (SPEC §3.4).
enum OverlayBreath {
    /// 0 (exhaled) … 1 (inhaled).
    static func fullness(at t: TimeInterval) -> Double {
        let half = OverlayMetrics.breatheHalfCycle
        let phase = max(0, t).truncatingRemainder(dividingBy: 2 * half)
        let p = phase < half ? phase / half : 1 - (phase - half) / half
        return 0.5 - 0.5 * cos(.pi * p)
    }

    static func isInhaling(at t: TimeInterval) -> Bool {
        max(0, t).truncatingRemainder(dividingBy: 2 * OverlayMetrics.breatheHalfCycle) < OverlayMetrics.breatheHalfCycle
    }

    /// Opacity of "In" ("Out" is 1 − this), cross-fading around each turn.
    static func inWordOpacity(at t: TimeInterval) -> Double {
        let half = OverlayMetrics.breatheHalfCycle
        let fade = OverlayMetrics.breatheWordFade
        let phase = max(0, t).truncatingRemainder(dividingBy: 2 * half)
        func ramp(_ x: Double) -> Double { min(max(x / fade + 0.5, 0), 1) }
        if phase < half { return min(ramp(phase), ramp(half - phase)) }
        return 1 - min(ramp(phase - half), ramp(2 * half - phase))
    }
}

/// The closing moment of a completed break as a function of the seconds since it completed
/// (SPEC §3.3 Closing moment): the content fades (0.2 s), the title swaps to the closing line
/// (0.3 s), the ring closes (0.45 s) and the check draws from 0.3 s over 0.3 s. Reduce Motion: one
/// 0.2 s cross-fade, content out then the closed mark and the line in.
struct OverlayCompletionFrame: Equatable {
    var content: Double = 1
    var title: Double = 1
    var line: Double = 0
    var mark: Double = 0
    var ring: Double = 0
    var check: Double = 0

    static func at(_ t: TimeInterval, reduceMotion: Bool) -> OverlayCompletionFrame {
        typealias M = OverlayMetrics
        func progress(_ start: Double, _ duration: Double) -> Double { OverlayCurve.progress(t, start: start, duration: duration) }
        var f = OverlayCompletionFrame()
        if reduceMotion {
            let out = progress(0, M.reduceMotionFade / 2), into = progress(M.reduceMotionFade / 2, M.reduceMotionFade / 2)
            f.content = 1 - out; f.title = 1 - out; f.line = into; f.mark = into; f.ring = 1; f.check = 1
            return f
        }
        let half = M.completionTitleSwap / 2
        f.content = 1 - OverlayCurve.easeOut(progress(0, M.completionFade))
        f.title = 1 - OverlayCurve.easeOut(progress(0, half))
        f.line = OverlayCurve.easeOut(progress(half, half))
        f.mark = 1
        f.ring = OverlayCurve.easeInOut(progress(0, M.completionRingClose))
        f.check = OverlayCurve.easeOut(progress(M.completionCheckAt, M.completionCheckDraw))
        return f
    }

    /// True once nothing moves any more (the clock can stop).
    static func isSettled(_ t: TimeInterval, reduceMotion: Bool) -> Bool {
        t >= (reduceMotion ? OverlayMetrics.reduceMotionFade : OverlayMetrics.completionCheckAt + OverlayMetrics.completionCheckDraw)
    }
}
