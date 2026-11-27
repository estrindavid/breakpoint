import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.9 Routine pane.

/// Resistance band toggle; the routines stretches rotate through, each with a checkbox to leave it
/// out, and Preview a stretch; the experimental AirPods movement check.
public struct RoutinePane: View {
    @ObservedObject var state: AppState
    let actions: AppActions

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    private var settings: Settings { state.settings }
    private var routines: [Routine] { BuiltInRoutines.available(for: settings) }

    public var body: some View {
        PaneStack {
            SettingsSection("Equipment") {
                ToggleRow(title: "I have a resistance band",
                          description: "Band routines join the rotation.",
                          systemImage: "figure.strengthtraining.functional",
                          isOn: settingBinding(state, actions, \.hasBand))
            }

            SettingsSection("Stretches") {
                ForEach(Array(routines.enumerated()), id: \.element.id) { index, routine in
                    if index > 0 { SettingsDivider() }
                    routineRow(routine)
                }
                SettingsDivider()
                HStack(spacing: 10) {
                    Text("Each stretch is the next routine in turn, two minutes each.")
                        .font(Theme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    RowButton("Preview a stretch") { actions.previewBreak(.move) }
                }
                .padding(.vertical, 8)
                .frame(minHeight: Theme.Layout.settingRowMinHeight)
            }

            SettingsSection("Experimental") {
                ToggleRow(title: "Check movement with AirPods",
                          description: "Uses head motion during stretches and walks. macOS will ask for Motion access.",
                          systemImage: "airpods", isOn: settingBinding(state, actions, \.airpodsMovementCheck))
            }
            SectionFootnote("Shows a small tick in your history when movement was detected. Nothing else is recorded.")
        }
    }

    private var includedCount: Int {
        routines.filter { !settings.excludedRoutines.contains($0.id) }.count
    }

    /// Name, summary and a checkbox; unticking leaves the routine out. The last one ticked stays.
    private func routineRow(_ routine: Routine) -> some View {
        let included = !settings.excludedRoutines.contains(routine.id)
        return SettingRow(routine.name, description: routine.summary, systemImage: Self.symbol(for: routine)) {
            Toggle("Use \(routine.name)", isOn: Binding(
                get: { included },
                set: { on in actions.updateSettings { $0.setRoutine(routine.id, excluded: !on) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(included && includedCount <= 1)
        }
        .opacity(included ? 1 : 0.5)
    }

    /// A symbol for each built-in routine (routines from elsewhere get a generic figure).
    static func symbol(for routine: Routine) -> String {
        switch routine.id {
        case "neck-and-shoulders": return "figure.cooldown"
        case "wrists-and-forearms": return "hand.raised"
        case "upper-back": return "figure.flexibility"
        case "chest-opener": return "figure.arms.open"
        case "hips-and-calves": return "figure.step.training"
        case "stand-and-reach": return "figure.stand"
        case "seated-legs": return "shoeprints.fill"
        case "band-pull-aparts": return "figure.strengthtraining.traditional"
        default: return routine.equipment == .band ? "figure.strengthtraining.functional" : "figure.mixed.cardio"
        }
    }
}
