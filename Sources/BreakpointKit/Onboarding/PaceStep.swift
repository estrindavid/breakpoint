import SwiftUI
import BreakpointCore

// SPEC §3.10 step 4.

/// The preset cards from Settings, Balanced preselected. ← → change the selection.
public struct PaceStep: View {
    @ObservedObject var state: AppState
    let actions: AppActions

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        OnboardingPage(title: "Pick your pace",
                       sentence: "Choose how often breaks are offered. Each card shows two hours of steady work; you can change it any time in Settings.") {
            VStack(alignment: .leading, spacing: 10) {
                PresetCardRow(state: state, actions: actions)
                HStack {
                    PresetTimelineLegend()
                    Spacer()
                    KeyHint([.key("←"), .key("→"), .text("to choose")])
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 496)
        }
    }
}
