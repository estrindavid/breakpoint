import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.9 Pauses pane.

/// Pause during calls (Options…: also when the camera is on), the away threshold sentence, and the
/// read-only notes about typing, dictation and the one-minute cool-down, and about presenting.
public struct PausesPane: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    @State private var showsCallOptions: Bool

    public init(state: AppState, actions: AppActions) {
        self.init(state: state, actions: actions, showsCallOptions: false)
    }

    init(state: AppState, actions: AppActions, showsCallOptions: Bool) {
        self.state = state
        self.actions = actions
        _showsCallOptions = State(initialValue: showsCallOptions)
    }

    public var body: some View {
        PaneStack {
            SettingsSection("Calls") {
                ToggleRow(title: "Pause during calls",
                          description: callDescription,
                          systemImage: "mic", isOn: settingBinding(state, actions, \.pauseForMicrophone),
                          options: { showsCallOptions = true },
                          optionsDisabled: !state.settings.pauseForMicrophone)
                if let signals = state.status.pause.callSignals, let phrase = signals.phrase {
                    SettingsDivider()
                    SettingRow("Paused now: \(phrase)",
                               description: "Breaks come back a minute after the call ends.",
                               systemImage: "pause.circle") {
                        RowButton("Resume now") { actions.resume() }
                    }
                }
            }
            SectionFootnote("Breakpoint sees only that a microphone or camera is in use, never which app or what is said.",
                            systemImage: "lock")

            SettingsSection("Away") {
                SentenceRow {
                    Text("Treat me as away after")
                    MinutePicker(label: "Treat me as away after \(state.settings.awayThresholdMinutes) minutes without input",
                                 values: Array(Settings.awayThresholdRange),
                                 value: settingBinding(state, actions, \.awayThresholdMinutes))
                    Text("min without input")
                }
                SettingsDivider()
                SettingRow("Time away counts",
                           description: "Coming back resets your timers, and a long enough absence counts as a break. You can undo it from the menu bar.",
                           systemImage: "figure.walk.departure")
            }
            SectionFootnote("Locking your Mac or letting the display sleep counts as away straight away.")

            SettingsSection("Always") {
                SettingRow("Breakpoint also waits while you type, drag or dictate, and for 1 minute after a pause ends.",
                           systemImage: "hourglass")
                SettingsDivider()
                SettingRow("Quiet while you present or watch",
                           description: "While a display is mirrored or kept awake, only an agent run or a long command offers a break, and eye rests never start by themselves.",
                           systemImage: "play.rectangle")
            }
        }
        .sheet(isPresented: $showsCallOptions) {
            CallOptionsSheet(isOn: settingBinding(state, actions, \.pauseForCamera)) { showsCallOptions = false }
        }
    }

    private var callDescription: String {
        guard state.settings.pauseForMicrophone else { return "Breaks may be offered during calls." }
        return state.settings.pauseForCamera
            ? "No break is offered while any microphone or camera is in use."
            : "No break is offered while any microphone is in use."
    }
}

/// Options… for "Pause during calls".
struct CallOptionsSheet: View {
    @Binding var isOn: Bool
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Call options").font(Theme.Typography.paneTitle)
            SettingsSection {
                ToggleRow(title: "Also pause when the camera is on",
                          description: "Turn this off if your camera is often on outside calls.",
                          systemImage: "video", isOn: $isOn)
            }
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
