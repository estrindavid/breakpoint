import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.4 `eyes`.

/// The `eyes` guide: the plain timer (rounded semibold 38, 60%, `m:ss`, rolling), quieter than the
/// title and instruction. The overlay layout puts its optical centre 66 pt below the hairline. The
/// screen deliberately offers nothing to look at but the words: the point is to look elsewhere.
public struct EyesBreakView: View {
    private let activeBreak: ActiveBreakState
    private let traits = DesignTraits()

    public init(activeBreak: ActiveBreakState) { self.activeBreak = activeBreak }

    public var body: some View {
        RollingNumber(DurationFormat.clock(activeBreak.remaining), value: activeBreak.remaining)
            .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
            .accessibilityLabel("\(DurationFormat.spokenLength(activeBreak.remaining)) left")
    }
}
