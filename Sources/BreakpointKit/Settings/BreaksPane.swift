import SwiftUI
import BreakpointCore

// SPEC §3.9 Breaks pane.

/// Preset cards (with mini timelines), the three cadence sentence rows, auto-start, strict mode,
/// full break on every display, Preview nudge · Preview break.
public struct BreaksPane: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    @State private var previewKind: BreakKind = .move

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        PaneStack {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Pace", detail: state.settings.preset == .custom ? "Custom" : nil)
                PresetCardRow(state: state, actions: actions)
                PresetTimelineLegend().padding(.horizontal, 4).padding(.top, 2)
            }

            SettingsSection("Timing") {
                SentenceRow {
                    Text("Offer an eye rest after")
                    MinutePicker(label: "Offer an eye rest after \(state.settings.eyesEveryMinutes) minutes of screen time",
                                 values: Array(stride(from: 10, through: 60, by: 5)),
                                 value: cadenceBinding(\.eyesEveryMinutes))
                    Text("min of screen time")
                }
                SettingsDivider()
                SentenceRow {
                    Text("Offer a stretch after")
                    MinutePicker(label: "Offer a stretch after \(state.settings.moveEveryMinutes) minutes without moving",
                                 values: Array(stride(from: 20, through: 120, by: 5)),
                                 value: cadenceBinding(\.moveEveryMinutes))
                    Text("min without moving")
                }
                SettingsDivider()
                SentenceRow {
                    Text("Offer a walk when \(agentPossessive) run is likely over")
                    MinutePicker(label: "Offer a walk when an agent's run is likely over \(state.settings.walkThresholdMinutes) minutes",
                                 values: Array(5...20),
                                 value: settingBinding(state, actions, \.walkThresholdMinutes))
                    Text("min")
                }
            }

            SettingsSection("When breaks start") {
                ToggleRow(title: "Start eye rests by themselves",
                          description: "A 10-second countdown runs first; typing, clicking or scrolling cancels it.",
                          systemImage: "eye", isOn: settingBinding(state, actions, \.autoStartEyes))
                SettingsDivider()
                ToggleRow(title: "Only during agent runs",
                          description: "Breakpoint offers breaks only when an agent or long command starts, never when you pause typing.",
                          systemImage: "sparkle", isOn: settingBinding(state, actions, \.strictAgentOnly))
                SettingsDivider()
                ToggleRow(title: "Show the full break on every display",
                          description: "Otherwise other displays show the blurred backdrop and a small timer.",
                          systemImage: "display.2", isOn: settingBinding(state, actions, \.fullBreakOnAllDisplays))
            }

            SettingsSection("Preview") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: Theme.Layout.settingRowIcon, height: Theme.Layout.settingRowIcon)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("See a nudge or a break").font(Theme.Typography.row)
                            Text("Shows the real one for 5 seconds; Esc ends a break early. Nothing is recorded.")
                                .font(Theme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 8) {
                        Picker("Break kind", selection: $previewKind) {
                            ForEach(BreakKind.allCases) { kind in
                                Label(kind.menuTitle, systemImage: kind.symbolName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        RowButton("Preview nudge", systemImage: "rectangle.topthird.inset.filled") {
                            actions.previewNudge(previewKind)
                        }
                        RowButton("Preview break", systemImage: "rectangle.inset.filled") {
                            actions.previewBreak(previewKind)
                        }
                        Spacer()
                    }
                    .padding(.leading, Theme.Layout.settingRowIcon + 10)
                }
                .padding(.vertical, 10)
            }
        }
    }

    /// "your agent's" or, with one tool in use, e.g. "Claude's".
    private var agentPossessive: String {
        let sources = Set(state.integrations.filter { $0.status.isInstalled && $0.id != .shell }.map(\.id.source))
        if sources.count == 1, let source = sources.first { return "\(source.displayName)'s" }
        return "your agent's"
    }

    /// Editing either cadence goes through `setCadence`, which selects Custom (or the matching
    /// preset) per SPEC §2.1.
    private func cadenceBinding(_ keyPath: KeyPath<Settings, Int>) -> Binding<Int> {
        Binding(get: { state.settings[keyPath: keyPath] }, set: { value in
            actions.updateSettings { settings in
                if keyPath == \Settings.eyesEveryMinutes {
                    settings.setCadence(eyesEveryMinutes: value)
                } else {
                    settings.setCadence(moveEveryMinutes: value)
                }
            }
        })
    }
}
