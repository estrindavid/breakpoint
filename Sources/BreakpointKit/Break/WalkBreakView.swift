import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.4 `walk`.

/// The `walk` guide: a 160 pt ring (3 pt mint, `LuminousRing`) filling toward the target with the elapsed time
/// inside, counting up. Past the target the ring stays full and the overlay waits for I'm back.
/// The overlay dims the rest of the column in ambient mode; the ring and timer stay as they are.
public struct WalkBreakView: View {
    private let activeBreak: ActiveBreakState
    private let traits = DesignTraits()

    public init(activeBreak: ActiveBreakState) { self.activeBreak = activeBreak }

    public var body: some View {
        LuminousRing(progress: activeBreak.progress, lineWidth: Theme.Layout.walkRingStroke) {
            RollingNumber(DurationFormat.clock(activeBreak.elapsed, rounding: .down), value: activeBreak.elapsed,
                          countsDown: false)
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
        }
        .animation(.linear(duration: 1), value: activeBreak.progress)
        .frame(width: Theme.Layout.walkRing, height: Theme.Layout.walkRing)
        .accessibilityLabel("\(DurationFormat.minutes(activeBreak.elapsed)) walked of \(DurationFormat.minutes(activeBreak.plannedLength, rounding: .nearest))")
    }
}
