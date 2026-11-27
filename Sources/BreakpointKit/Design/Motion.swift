import SwiftUI
import BreakpointCore
import BreakpointRuntime

extension Theme {
    /// Every motion value of SPEC §4.6. Springs never overshoot visibly (damping ≥ 0.8). Under
    /// Reduce Motion, every discrete animation becomes a ≤ 0.2 s opacity cross-fade
    /// (`Motion.animation(_:reduceMotion:)` does the substitution); continuous animations stop.
    public enum Motion {
        /// Named moments, so call sites read like the spec table.
        public enum Moment: Sendable, CaseIterable {
            case popupIn, popupOutTimeout, popupOutAction, subtitleSwap, digitRoll, markArrival,
                 agentChipColor, moveStep, ringReset, windDownRelease, connectedFlash, nudgeStartExit,
                 ambientWake
        }

        /// The animation for `moment`, or the Reduce Motion substitute.
        public static func animation(_ moment: Moment, reduceMotion: Bool) -> Animation {
            if reduceMotion {
                return moment == .digitRoll ? .linear(duration: 0.01) : .easeInOut(duration: reduceMotionFade)
            }
            switch moment {
            case .popupIn: return popupIn
            case .popupOutTimeout: return .easeIn(duration: popupOutTimeoutDuration)
            case .popupOutAction: return .easeOut(duration: popupOutActionDuration)
            case .subtitleSwap: return .easeInOut(duration: subtitleSwapDuration)
            case .digitRoll: return .easeInOut(duration: digitRollDuration)
            case .markArrival: return markArrival
            case .agentChipColor: return .easeInOut(duration: agentChipColorDuration)
            case .moveStep: return .easeInOut(duration: moveStepDuration)
            case .ringReset: return .easeOut(duration: ringResetDuration)
            case .windDownRelease: return .spring(response: windDownReleaseDuration, dampingFraction: 1)
            case .connectedFlash: return .easeOut(duration: connectedFlashDuration)
            case .nudgeStartExit: return .easeOut(duration: nudgeStartExitDuration)
            case .ambientWake: return .easeOut(duration: ambientWakeDuration)
            }
        }

        // Pop-ups (§3.0, §3.1, §4.6)
        /// Pop-up in: the glass grows out of a small capsule under the card's top edge and the
        /// content comes into focus (6 pt blur, 6 pt drop); spring 0.5 / 0.82, settled by 0.6 s.
        /// The shapes are `LiquidMotion.pose` (BreakpointCore).
        public static let popupIn = Animation.spring(response: LiquidMotion.arrivalResponse,
                                                     dampingFraction: LiquidMotion.arrivalDamping)
        public static let popupInDuration: TimeInterval = LiquidMotion.arrivalSettles
        /// Pop-up out on timeout: folds back up into its seed (content first) with a 4 pt upward
        /// drift, 0.35 s ease-in.
        public static let popupOutTimeoutDuration: TimeInterval = 0.35
        /// Pop-up out after an action, or withdrawn: settles to 96% towards the top edge and fades, 0.2 s.
        public static let popupOutActionDuration: TimeInterval = 0.2
        /// Nudge subtitle swap: 0.2 s cross-fade after the pointer rests 300 ms.
        public static let subtitleSwapDuration: TimeInterval = 0.2
        public static let hoverRestDelay: TimeInterval = 0.3
        /// Exit on Start: card scales 1.0 → 1.04 and fades over 0.2 s.
        public static let nudgeStartExitDuration: TimeInterval = 0.2
        /// Countdown chip cancelled mid-handoff: a 0.2 s window fade. (Otherwise it leaves like a
        /// pop-up: swells into the overlay in 0.2 s, or folds into its leading end in 0.35 s.)
        public static let countdownChipExit: TimeInterval = 0.2

        // Numbers
        /// Digit roll: 0.25 s per change.
        public static let digitRollDuration: TimeInterval = 0.25

        // Brand mark arrival (onboarding Welcome, About): slides 6 pt in from the leading edge,
        // spring 0.35 / 0.8.
        public static let markArrival = Animation.spring(response: 0.35, dampingFraction: 0.8)
        public static let markArrivalOffset: CGFloat = 6

        // Overlay entrance (§4.6 table, ≈ 1.55 s). The backdrop's layers (blur, vignette, scrim,
        // aurora) follow `BackdropTimeline` (Core); the content's steps are these.
        /// t = 0.55: title opacity 0 → 1 and blur 8 → 0 over 0.35 s.
        public static let overlayTitleAt: TimeInterval = 0.55
        public static let overlayTitleDuration: TimeInterval = 0.35
        public static let overlayTitleBlur: CGFloat = 8
        /// t = 0.95: instruction, kind line, hairline, guide: opacity + 6 pt rise over 0.35 s.
        public static let overlayBodyAt: TimeInterval = 0.95
        public static let overlayBodyDuration: TimeInterval = 0.35
        public static let overlayBodyRise: CGFloat = 6
        /// t = 1.25: agent chip, controls, hint: opacity over 0.3 s (done ≈ 1.55 s).
        public static let overlayChromeAt: TimeInterval = 1.25
        public static let overlayChromeDuration: TimeInterval = 0.3
        public static var overlayEntranceTotal: TimeInterval { overlayChromeAt + overlayChromeDuration }
        /// Reduce Motion: the whole entrance is one 0.25 s fade.
        public static let overlayEntranceReduced: TimeInterval = 0.25
        /// Overlay exit: content 0.2 s fade while the title defocuses by this much; the backdrop
        /// lets go in layers over 0.75 s (`BackdropTimeline.exit`).
        public static let overlayExitContent: TimeInterval = 0.2
        public static let overlayExitTitleBlur: CGFloat = 4

        // Overlay details
        /// Agent chip colour change: 0.3 s cross-fade.
        public static let agentChipColorDuration: TimeInterval = 0.3
        /// Working dot (overlay chip and menu-bar badge) pulses at 0.5 Hz.
        public static let pulseFrequency: Double = 0.5
        /// `move` step change: 0.3 s ease-in-out, 12 pt slide; ring reset 0.2 s fade.
        public static let moveStepDuration: TimeInterval = 0.3
        public static let moveStepSlide: CGFloat = 12
        public static let ringResetDuration: TimeInterval = 0.2
        /// `breathe`: 5.5 s in / 5.5 s out, sine ease-in-out. Reduce Motion: fill opacity 10% → 30%.
        public static let breatheHalfCycle: TimeInterval = 5.5
        public static let breatheReducedFill: ClosedRange<Double> = 0.10...0.30
        /// `move` pacing: each phase of a repetition eases over its own seconds with the `breathe`
        /// curve (sine ease-in-out); the phase word cross-fades over this long around each turn.
        /// Reduce Motion: the arc moves in whole-second steps and the word swaps with a 0.2 s fade.
        public static let paceWordFade: TimeInterval = 0.5
        /// At the turn itself the word is at this opacity (old fading down to it, new rising from
        /// it), so the ring is never without a word and two words never overlap.
        public static let paceWordTurnOpacity: Double = 0.35
        /// A completed break's closing moment (`Timing.completionMoment`, 1.2 s, then the exit):
        /// the guide, instruction, kind line, controls and hint fade (0.2 s) and the title
        /// cross-fades to the closing line (0.3 s); the ring closes (0.45 s, ease-in-out); the check
        /// draws from 0.3 s over 0.3 s (ease-out). Reduce Motion: one 0.2 s cross-fade (content
        /// out, then the closed ring with its check and the line in).
        public static let completionFade: TimeInterval = 0.2
        public static let completionTitleSwap: TimeInterval = 0.3
        public static let completionRingClose: TimeInterval = 0.45
        public static let completionCheckAt: TimeInterval = 0.3
        public static let completionCheckDraw: TimeInterval = 0.3
        /// Single Esc pulses the hint: opacity 1 → 0.5 → 1 over 0.3 s.
        public static let escPulseDuration: TimeInterval = 0.3
        /// `walk` ambient wake: 0.3 s.
        public static let ambientWakeDuration: TimeInterval = 0.3

        // Wind-down
        /// Hold fill is linear over 3 / 6 / 10 s; releasing early springs back over 0.3 s.
        public static let windDownReleaseDuration: TimeInterval = 0.3
        /// Card grows into the note: spring 0.45 / 0.85.
        public static let cardGrow = Animation.spring(response: 0.45, dampingFraction: 0.85)

        // Settings
        /// An install verified: the row's ✓ pill flashes mint, 0.4 s.
        public static let connectedFlashDuration: TimeInterval = 0.4

        // Controls and windows
        /// Pressed feedback on capsules and the wind-down hold button (scale 0.97).
        public static let press = Animation.easeOut(duration: 0.12)
        /// Hover fade of a pop-up's corner × button.
        public static let closeButtonFade = Animation.easeOut(duration: 0.15)
        /// Onboarding: page change and the demo's scene cross-fades (a discrete move, ≤ 0.5 s).
        public static let pageChange = Animation.easeInOut(duration: 0.3)
        public static let demoScene = Animation.easeInOut(duration: 0.35)
        /// Onboarding Done: the arrow's slow bob toward the status item (continuous, 0.9 s each way;
        /// still under Reduce Motion).
        public static let arrowBob = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)

        // Menu-bar mark movements (§3.7): each plays once at its moment, never loops; none plays
        // under Reduce Motion or while the screen is locked or the displays sleep.
        /// An agent finished: the working dot slides into the notch and disappears.
        public static let markSettleDuration: TimeInterval = 0.4
        /// An agent needs you: the eyes grow about a point taller and settle.
        public static let markLiftDuration: TimeInterval = 0.3
        /// Wrapped up: the two eyes fold into the rest bar.
        public static let markFoldDuration: TimeInterval = 0.45
        /// Frames per second of a mark movement (each frame is a template image).
        public static let markFrameRate: Double = 30
        /// Onboarding: the ✓ in "Connected" hops 4 pt once, as the pill flashes mint.
        public static let connectedHopDuration: TimeInterval = 0.45

        public static func markCueDuration(_ cue: MarkCue) -> TimeInterval {
            switch cue {
            case .settle: return markSettleDuration
            case .lift: return markLiftDuration
            case .fold: return markFoldDuration
            }
        }

        /// Reduce Motion substitute for every discrete animation.
        public static let reduceMotionFade: TimeInterval = 0.2
    }
}
