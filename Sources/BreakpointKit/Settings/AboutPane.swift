import SwiftUI
import BreakpointCore

// SPEC §3.9 About pane.

/// Version, Updates (§2.11), "General wellness, not medical advice.", evidence notes,
/// acknowledgements. The mark arrives with its signature motion (§4.6).
public struct AboutPane: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    @State private var arrived = false
    private let traits = DesignTraits()

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    /// Snapshots and Reduce Motion show the mark at rest; otherwise it slides 6 pt in on appear.
    private var atRest: Bool { arrived || !traits.runsContinuousAnimations }

    static let evidence: [String] = [
        "The stretch with a band is two minutes of elastic band exercise: three short sets with rests between them.",
        "Eye rests follow the common advice to look at something far away for about 20 seconds every so often.",
        "Breakpoint keeps no score and makes no promise about how you will feel. It offers the pause; the rest is up to you.",
    ]

    public var body: some View {
        PaneStack {
            HStack(alignment: .center, spacing: 16) {
                AppIconView()
                    .frame(width: 72, height: 72)
                    .offset(x: atRest ? 0 : -Theme.Motion.markArrivalOffset)
                    .opacity(atRest ? 1 : 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Breakpoint")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Break reminders that wait for your agent.")
                        .font(Theme.Typography.row)
                        .foregroundStyle(.secondary)
                    Text("Version \(BreakpointVersion.current)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                    Text(Copy.aboutTagline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .onAppear { withAnimation(traits.animation(.markArrival)) { arrived = true } }

            UpdatesSection(state: state, actions: actions)

            SettingsSection {
                SettingRow(BreakCopyLibrary.wellnessDisclaimer,
                           description: "Breakpoint suggests short movement and eye rests, and leaves the rest to you.",
                           systemImage: "heart.text.square")
            }

            SettingsSection("Evidence notes") {
                ForEach(Array(Self.evidence.enumerated()), id: \.offset) { index, line in
                    if index > 0 { SettingsDivider() }
                    Text(line)
                        .font(Theme.Typography.row)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsSection("Acknowledgements") {
                Text("Built with Swift and SwiftUI, with no third-party code. Symbols are SF Symbols. The chime is synthesised on your Mac. Thanks to everyone who tried early builds and said what got in their way.")
                    .font(Theme.Typography.row)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Settings → About → Updates: where things stand, Check now, Update (or the download page),
/// the automatic check and automatic installs (SPEC §2.11, §3.9).
struct UpdatesSection: View {
    @ObservedObject var state: AppState
    let actions: AppActions

    private var update: UpdateState { state.update }

    var body: some View {
        SettingsSection("Updates") {
            SettingRow(title, description: description, systemImage: symbol) {
                HStack(spacing: 8) {
                    switch update.phase {
                    case .checking, .installing:
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(title)
                    case .available:
                        RowButton("Check now") { actions.checkForUpdates() }
                        if update.canInstall {
                            RowButton("Update", prominent: true) { actions.installUpdate() }
                        } else {
                            RowButton("Download page…", prominent: true) { actions.openUpdate() }
                        }
                    case .installFailed:
                        RowButton("Open download page…", prominent: true) { actions.openUpdate() }
                    default:
                        RowButton("Check now") { actions.checkForUpdates() }
                    }
                }
            }
            SettingsDivider()
            ToggleRow(title: "Check for updates automatically", description: UpdateCopy.automaticDescription,
                      systemImage: "arrow.triangle.2.circlepath", isOn: settingBinding(state, actions, \.checkForUpdates))
            SettingsDivider()
            ToggleRow(title: "Install updates automatically", description: autoInstallDescription,
                      systemImage: "arrow.down.app", isOn: settingBinding(state, actions, \.installUpdatesAutomatically))
                .disabled(!state.settings.checkForUpdates || update.installBlocker != nil)
        }
    }

    private var autoInstallDescription: String {
        guard let blocker = update.installBlocker else { return UpdateCopy.autoInstallDescription }
        return blocker
    }

    private var title: String {
        switch update.phase {
        case .idle: return UpdateCopy.neverChecked
        case .checking: return UpdateCopy.checking
        case .upToDate: return UpdateCopy.upToDate
        case .available(let release): return UpdateCopy.available(version: release.version)
        case .installing(let release, _): return UpdateCopy.available(version: release.version)
        case .installFailed(let release, _): return UpdateCopy.installFailedTitle(version: release.version)
        case .failed: return UpdateCopy.failed
        }
    }

    private var lastChecked: String? {
        update.lastCheckedAt.map { UpdateCopy.lastChecked($0, now: state.now) + "." }
    }

    private var description: String? {
        switch update.phase {
        case .idle: return "You have version \(update.currentVersion)."
        case .checking, .upToDate: return lastChecked
        case .available(let release):
            let notes = UpdateCopy.promptDetail(notes: release.notes)
            if update.canInstall { return notes + " Update downloads it, checks its signature and reopens Breakpoint." }
            return notes + " The download page has the new copy; replace the app in Applications with it."
        case .installing(_, let step): return step.text
        case .installFailed(_, let reason): return reason + " The download page has the new copy."
        case .failed:
            return "No connection, or no release is published yet. Breakpoint tries again in a few hours."
        }
    }

    private var symbol: String {
        switch update.phase {
        case .idle, .checking: return "clock"
        case .upToDate: return "checkmark.circle"
        case .available, .installing: return "arrow.down.circle"
        case .installFailed: return "exclamationmark.circle"
        case .failed: return "wifi.slash"
        }
    }
}
