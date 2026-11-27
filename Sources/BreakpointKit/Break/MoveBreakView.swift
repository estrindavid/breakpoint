import SwiftUI
import BreakpointCore

// SPEC §3.4 `move`.

/// The `move` guide: `RoutinePlayerView` for the current step, then the whole routine's time left
/// ("1:24 left", 15 pt, 60%) under the step dots, where `breathe` keeps its time left too. That is
/// the screen's one clock: the ring paces the repetitions instead of counting the step down. The
/// overlay column adds the cue chip (kind line), the hairline and the footer "General wellness,
/// not medical advice." (this screen only).
public struct MoveBreakView: View {
    private let activeBreak: ActiveBreakState
    private let liveElapsed: TimeInterval?
    private let traits = DesignTraits()

    /// - `liveElapsed`: seconds since the break started at frame precision (snapshots and the demo
    ///   pass a fixed value; `nil` uses `activeBreak.elapsed`).
    public init(activeBreak: ActiveBreakState, liveElapsed: TimeInterval? = nil) {
        self.activeBreak = activeBreak
        self.liveElapsed = liveElapsed
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            RoutinePlayerView(step: activeBreak.step, breakStartedAt: activeBreak.startedAt,
                              breakElapsed: activeBreak.elapsed, liveElapsed: liveElapsed)
            RollingNumber("\(DurationFormat.clock(activeBreak.remaining)) left", value: activeBreak.remaining,
                          font: .system(size: 15, weight: .regular))
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                .accessibilityLabel("\(DurationFormat.spokenLength(activeBreak.remaining)) left in the break")
        }
    }
}

/// The step ring (140 pt, 4 pt mint, `LuminousRing`) and the step dots below (6 pt, 8 pt gap:
/// done mint, current white, upcoming 25%). On a step change the ring resets with a 0.2 s fade.
///
/// A step with a tempo shows `PaceRing`: the repetition's current phase on the same luminous ring.
/// A step without one keeps the plain ring: the step's progress with its seconds inside.
public struct RoutinePlayerView: View {
    private let step: RoutineStepState?
    private let breakStartedAt: Date?
    private let breakElapsed: TimeInterval
    private let liveElapsed: TimeInterval?
    private let traits = DesignTraits()
    @Environment(\.designOverrides) private var overrides

    public init(step: RoutineStepState?, breakStartedAt: Date? = nil, breakElapsed: TimeInterval = 0,
                liveElapsed: TimeInterval? = nil) {
        self.step = step
        self.breakStartedAt = breakStartedAt
        self.breakElapsed = breakElapsed
        self.liveElapsed = liveElapsed
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ZStack {
                if let step, !step.step.tempo.isEmpty {
                    paced(step)
                        .id(step.index)
                        .transition(.opacity.animation(traits.animation(.ringReset)))
                } else {
                    plain
                }
            }
            .frame(width: Theme.Layout.moveRing, height: Theme.Layout.moveRing)
            .animation(traits.animation(.ringReset), value: step?.index ?? 0)
            if let step {
                HStack(spacing: Theme.Layout.stepDotGap) {
                    ForEach(0..<step.count, id: \.self) { i in
                        Circle()
                            .fill(i < step.index ? Theme.Colors.mint : (i == step.index ? Color.white : Theme.Colors.white(.hairline)))
                            .frame(width: Theme.Layout.stepDot, height: Theme.Layout.stepDot)
                    }
                }
                .animation(traits.animation(.moveStep), value: step.index)
                .accessibilityElement()
                .accessibilityLabel("Step \(step.index + 1) of \(step.count)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The step's progress, for a step without a tempo.
    private var plain: some View {
        ZStack {
            LuminousRing(progress: step?.progress ?? 0, lineWidth: Theme.Layout.moveRingStroke) { EmptyView() }
                .animation(.linear(duration: 1), value: step?.progress ?? 0)
                .id(step?.index ?? 0)
                .transition(.opacity.animation(traits.animation(.ringReset)))
            RollingNumber(DurationFormat.clock(step?.remaining ?? 0), value: step?.remaining ?? 0)
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
        }
    }

    /// Seconds into the step at `breakTime` seconds after the break started.
    private func stepElapsed(_ step: RoutineStepState, breakTime: TimeInterval) -> TimeInterval {
        let stepStart = breakElapsed - step.elapsed
        // Just short of the end: at exactly the step's length the pace would wrap into a new rep.
        return min(max(breakTime - stepStart, 0), max(0, step.step.duration - 0.001))
    }

    /// Live: redrawn every frame from the clock (stepped by whole seconds under Reduce Motion).
    /// Snapshots freeze continuous animation and draw the frame at `liveElapsed`.
    @ViewBuilder private func paced(_ step: RoutineStepState) -> some View {
        let frozen = overrides.freezeContinuousAnimations
        if let startedAt = breakStartedAt, !frozen {
            TimelineView(.animation(minimumInterval: traits.reduceMotion ? 0.1 : nil)) { context in
                PaceRing(step: step.step, stepElapsed: stepElapsed(step, breakTime: context.date.timeIntervalSince(startedAt)),
                         reduceMotion: traits.reduceMotion)
            }
        } else {
            PaceRing(step: step.step, stepElapsed: stepElapsed(step, breakTime: liveElapsed ?? breakElapsed),
                     reduceMotion: traits.reduceMotion)
        }
    }
}

/// One step's repetitions, the way the `breathe` ring paces a breath (SPEC §3.4 `move`), drawn on
/// the overlay's `LuminousRing` so it brightens toward its leading end like every other ring:
/// - an "out" phase ("up", "squeeze", "one side") fills the mint arc clockwise from 12 o'clock over
///   its seconds, a "back" phase returns it, and a "hold" keeps it full; a one-phase repetition
///   ("circle") sends a short arc once around the ring, its glowing head leading;
/// - the disc inside brightens with the arc (mint 10% → 30%, the `breathe` Reduce Motion range),
///   so the rhythm reads from the corner of the eye;
/// - the phase word sits inside (rounded medium 22, like "In" / "Out"), dipping to 35% at each
///   turn as it changes.
///
/// Reduce Motion: the arc and the disc move in whole-second steps (a counted beat, no sweep), the
/// travelling arc jumps by the second, and the word swaps with a 0.2 s fade.
public struct PaceRing: View {
    private let step: RoutineStep
    private let stepElapsed: TimeInterval
    private let reduceMotion: Bool

    public init(step: RoutineStep, stepElapsed: TimeInterval, reduceMotion: Bool) {
        self.step = step
        self.stepElapsed = stepElapsed
        self.reduceMotion = reduceMotion
    }

    private var lineWidth: CGFloat { Theme.Layout.moveRingStroke }

    public var body: some View {
        let frame = TempoPacing.frame(tempo: step.tempo, at: stepElapsed, stepped: reduceMotion)
        return ZStack {
            if let frame {
                let range = Theme.Motion.breatheReducedFill
                let level = frame.motion == .around ? 0 : frame.fullness
                let around = frame.motion == .around
                let head = around ? frame.fullness : min(frame.fullness, 1)
                LuminousRing(progress: head, tail: around ? head - Double(Theme.Layout.paceTravelArc) : 0,
                             lineWidth: lineWidth) {
                    ZStack {
                        Circle()
                            .fill(Theme.Colors.mint.opacity(range.lowerBound + (range.upperBound - range.lowerBound) * level))
                            .padding(lineWidth)
                        words(frame)
                            .font(Theme.Typography.breatheWord)
                            .foregroundStyle(Theme.Colors.white(.title))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: Theme.Layout.moveRing * 0.74)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(frame.map { Self.word($0.label) } ?? step.cue)
    }

    /// The current word. Around each turn the old word dims over the phase's last quarter second
    /// and the new one brightens over the next phase's first (never at the step's own start or
    /// end), so two words never sit on top of each other and the dip marks the turn.
    private func words(_ frame: PaceFrame) -> some View {
        let half = (reduceMotion ? Theme.Motion.reduceMotionFade : Theme.Motion.paceWordFade) / 2
        let neighbours = TempoPacing.neighbours(tempo: step.tempo, phaseIndex: frame.phaseIndex)
        let isFirstPhase = frame.repetition == 0 && frame.phaseIndex == 0
        let isLastPhase = stepElapsed + frame.phaseRemaining >= step.duration - 0.001
        let low = Theme.Motion.paceWordTurnOpacity
        var opacity = 1.0
        if frame.phaseElapsed < half, !isFirstPhase, neighbours.previous != frame.label {
            opacity = low + (1 - low) * frame.phaseElapsed / half
        } else if frame.phaseRemaining < half, !isLastPhase, neighbours.next != frame.label {
            opacity = low + (1 - low) * frame.phaseRemaining / half
        }
        return Text(Self.word(frame.label)).opacity(opacity)
    }

    /// "up" → "Up", "one side" → "One side".
    static func word(_ label: String) -> String {
        label.prefix(1).uppercased() + label.dropFirst()
    }
}
