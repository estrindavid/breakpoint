import SwiftUI
import BreakpointCore

// SPEC §3.4 `breathe`.

/// The `breathe` guide: a 220 pt ring (mint 20% fill + 3 pt mint stroke) scaling 0.72 → 1.0 over
/// 5.5 s and back (sine ease-in-out), "In" / "Out" inside (rounded medium 22) cross-fading at each
/// turn, time left below (15 pt, 60%). Here the ring is the content, so it is the loudest thing
/// on screen after the title. Reduce Motion: no scaling; the fill's opacity rises 10% → 30% and
/// falls back with the same timing.
///
/// The cycle is a function of time since the break started, so every frame (live, snapshot or
/// demo step) is reproducible.
public struct BreatheBreakView: View {
    private let activeBreak: ActiveBreakState
    private let now: Date
    private let liveElapsed: TimeInterval?
    private let traits = DesignTraits()

    public init(activeBreak: ActiveBreakState, now: Date, liveElapsed: TimeInterval? = nil) {
        self.activeBreak = activeBreak
        self.now = now
        self.liveElapsed = liveElapsed
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Group {
                if traits.runsContinuousAnimations || (traits.reduceMotion && !frozen) {
                    TimelineView(.animation) { context in
                        ring(at: context.date.timeIntervalSince(activeBreak.startedAt))
                    }
                } else {
                    ring(at: liveElapsed ?? activeBreak.elapsed)
                }
            }
            .frame(width: Theme.Layout.breatheRing, height: Theme.Layout.breatheRing)
            RollingNumber(DurationFormat.clock(activeBreak.remaining), value: activeBreak.remaining,
                          font: .system(size: 15, weight: .regular))
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                .accessibilityLabel("\(DurationFormat.spokenLength(activeBreak.remaining)) left")
        }
    }

    /// Snapshots freeze continuous animation; Reduce Motion alone still breathes (by opacity).
    @Environment(\.designOverrides) private var overrides
    private var frozen: Bool { overrides.freezeContinuousAnimations }

    private func ring(at t: TimeInterval) -> some View {
        let fullness = BreathCycle.fullness(at: t)
        let reduce = traits.reduceMotion
        let scale = reduce ? 1 : Theme.Layout.breatheMinScale + (1 - Theme.Layout.breatheMinScale) * fullness
        let range = Theme.Motion.breatheReducedFill
        let fill = reduce ? range.lowerBound + (range.upperBound - range.lowerBound) * fullness : 0.20
        let inOpacity = BreathCycle.inWordOpacity(at: t)
        return ZStack {
            ZStack {
                Circle().fill(Theme.Colors.mint.opacity(fill))
                Circle().strokeBorder(Theme.Colors.mint, lineWidth: Theme.Layout.breatheRingStroke / scale)
            }
            .scaleEffect(scale)
            ZStack {
                Text("In").opacity(inOpacity)
                Text("Out").opacity(1 - inOpacity)
            }
            .font(Theme.Typography.breatheWord)
            .foregroundStyle(Theme.Colors.white(.title))
        }
        .accessibilityElement()
        .accessibilityLabel(BreathCycle.isInhaling(at: t) ? "Breathe in" : "Breathe out")
    }
}
