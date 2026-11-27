import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.9 Privacy pane.

/// "No permissions needed." first, then Keep prompt snippets, the plain list of what Breakpoint
/// reads and what it never reads, where the data lives, Export history · Delete all data.
public struct PrivacyPane: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    @Environment(\.colorScheme) private var scheme

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    static let reads: [(String, String)] = [
        ("keyboard", "How long since your last key press, click or scroll. Never which keys."),
        ("cursorarrow.motionlines", "Whether a mouse button is held, and where the pointer is, to place pop-ups."),
        ("mic", "Whether any microphone or camera is in use. Never which app, never the audio."),
        ("lock", "Screen lock, display sleep and the screen saver."),
        ("tv", "Whether something is keeping the display awake, such as a video, and whether a display is mirrored. No app names."),
        ("point.3.connected.trianglepath.dotted", "Events from tools you connect: what happened and why, the project folder and the snippets above."),
    ]

    static let neverReads: [(String, String)] = [
        ("rectangle.dashed", "Your screen: no screenshots, no recording."),
        ("text.cursor", "What you type, your code, or window titles."),
        ("square.grid.2x2", "Which apps or websites you use."),
        ("network.slash", "The network, except for updates (About): a daily version check that sends nothing about you, and the new version when you install it."),
    ]

    public var body: some View {
        PaneStack {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Theme.Colors.accent(for: scheme))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No permissions needed.")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Breakpoint never asks for Accessibility, Input Monitoring, Screen Recording, Calendar, Notifications, Camera or Microphone access. Only the optional AirPods check asks for Motion access, when you turn it on.")
                        .font(Theme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.settingsSection, style: .continuous)
                    .fill(Theme.Colors.accent(for: scheme).opacity(scheme == .dark ? 0.12 : 0.08)))
            .accessibilityElement(children: .combine)

            SettingsSection("Stored on this Mac") {
                ToggleRow(title: "Keep prompt snippets",
                          description: "The first line of your prompt and of the agent's last reply, and the command it asks to run, label sessions and resume cards. Secrets are masked.",
                          systemImage: "text.quote", isOn: settingBinding(state, actions, \.storePromptSnippets))
            }

            SettingsSection("What Breakpoint reads") {
                ForEach(Array(Self.reads.enumerated()), id: \.offset) { index, item in
                    if index > 0 { SettingsDivider() }
                    PrivacyLine(symbol: item.0, text: item.1, positive: true)
                }
            }

            SettingsSection("What it never reads") {
                ForEach(Array(Self.neverReads.enumerated()), id: \.offset) { index, item in
                    if index > 0 { SettingsDivider() }
                    PrivacyLine(symbol: item.0, text: item.1, positive: false)
                }
            }

            SettingsSection("Your data") {
                SettingRow("Everything stays in your Library folder",
                           description: "~/Library/Application Support/Breakpoint, plus the command-line copy in ~/.breakpoint.",
                           systemImage: "folder") {
                    RowButton("Show in Finder") { revealData() }
                }
                SettingsDivider()
                SettingRow("Export history", description: "Saves your break history as a JSON file.",
                           systemImage: "square.and.arrow.up") {
                    RowButton("Export…") { actions.exportHistory() }
                }
                SettingsDivider()
                SettingRow("Delete all data",
                           description: "Removes your break history and agent run estimates. Settings, connected tools and their config backups stay. Asks first.",
                           systemImage: "trash") {
                    Button("Delete…", role: .destructive) { actions.deleteAllData() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func revealData() {
        let paths = BreakpointPaths.live()
        let url = FileManager.default.fileExists(atPath: paths.appSupport.path) ? paths.appSupport : paths.home
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct PrivacyLine: View {
    let symbol: String
    let text: String
    let positive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Theme.Layout.settingRowIcon, height: Theme.Layout.settingRowIcon)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Typography.row)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: positive ? "checkmark" : "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(positive ? "Read" : "Never read")
        }
        .padding(.vertical, 8)
        .frame(minHeight: Theme.Layout.settingRowMinHeight)
        .accessibilityElement(children: .combine)
    }
}
