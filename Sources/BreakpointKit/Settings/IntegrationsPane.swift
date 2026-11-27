import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.9 Integrations pane, §5.6.

/// One row per tool: icon, name, status pill, Install / Remove (Install checks the hooks by itself
/// and the pill turns to ✓ "Connected", or the row says what is wrong), the Codex trust step and
/// legacy-notify Options…, the Codex folder override (only if `~/.codex` is absent) and the "Use
/// with any tool" one-liner with Copy.
public struct IntegrationsPane: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    @State private var showsCodexOptions: Bool

    public init(state: AppState, actions: AppActions) {
        self.init(state: state, actions: actions, showsCodexOptions: false)
    }

    init(state: AppState, actions: AppActions, showsCodexOptions: Bool) {
        self.state = state
        self.actions = actions
        _showsCodexOptions = State(initialValue: showsCodexOptions)
    }

    public static let anyToolCommand = "breakpoint emit agentStarted --source my-tool --session ID"

    public var body: some View {
        let rows = state.integrations.filter { IntegrationID.settingsRows.contains($0.id) }
        PaneStack {
            Text("Breakpoint hears from your tools through small hooks in their settings files. Nothing is written until you press Install, and Remove takes out only what Breakpoint added.")
                .font(Theme.Typography.row)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            SettingsSection("Tools") {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { SettingsDivider() }
                    IntegrationRow(row: row, now: state.now, actions: actions,
                                   options: row.id == .codex ? { showsCodexOptions = true } : nil)
                    if row.id == .codex, row.status == .notFound {
                        SettingsDivider()
                        CodexFolderRow(state: state, actions: actions)
                    }
                }
            }

            SettingsSection("Use with any tool") {
                AnyToolRow(command: Self.anyToolCommand)
            }
            SectionFootnote("Send agentFinished when it’s done. The command lives at ~/.breakpoint/bin/breakpoint once any tool is installed.")
        }
        .sheet(isPresented: $showsCodexOptions) {
            CodexOptionsSheet(state: state, actions: actions) { showsCodexOptions = false }
        }
    }

    /// The status pill's words (SPEC §5.6).
    static func statusText(_ status: IntegrationStatus, id: IntegrationID, now: Date) -> String {
        switch status {
        case .notFound: return "Not found"
        case .notInstalled: return "Not installed"
        case .connected(.none):
            return "Connected"
        case .connected(let date?):
            // Information only: a connected row needs no event to count.
            let ago = now.timeIntervalSince(date)
            return ago < 60 ? "Connected · last event just now" : "Connected · last event \(DurationFormat.minutes(ago)) ago"
        case .problem: return "Can’t read its settings"
        }
    }

    /// The pill's words for a row: the problem states say which problem it is.
    static func statusText(_ row: IntegrationRowState, now: Date) -> String {
        switch row.installState {
        case .outdated: return "Needs an update"
        case .modified: return "Edited outside Breakpoint"
        // Installed, but the install check found something in the way.
        case .installed where !row.status.isInstalled: return "Needs attention"
        default: return statusText(row.status, id: row.id, now: now)
        }
    }

    /// The button that installs again over Breakpoint's own entries: an older version's are
    /// updated, edited ones restored, and an install that failed its check is simply redone.
    static func reinstallLabel(_ state: IntegrationInstallState) -> String {
        switch state {
        case .outdated: return "Update"
        case .modified: return "Restore"
        default: return "Install again"
        }
    }

    /// What Install does, in one line.
    static func installLine(_ id: IntegrationID) -> String {
        switch id {
        case .claudeCode: return "Adds hooks to ~/.claude/settings.json."
        case .cursor: return "Adds hooks to ~/.cursor/hooks.json."
        case .codex: return "Adds hooks to ~/.codex/hooks.json. Codex asks you to trust them once, in /hooks."
        case .codexNotify: return "Adds one notify line to ~/.codex/config.toml."
        case .copilot: return "Adds one file, ~/.copilot/hooks/breakpoint.json."
        case .gemini: return "Adds hooks to ~/.gemini/settings.json."
        case .shell: return "Offers breaks while long commands run. Adds a small block to .zshrc and .bashrc."
        }
    }
}

// MARK: - Tool row

private struct IntegrationRow: View {
    let row: IntegrationRowState
    let now: Date
    let actions: AppActions
    let options: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SourceTile(symbol: MenuBarGlyphs.integrationSymbol(row.id), size: Theme.Layout.settingRowIcon)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.displayName).font(Theme.Typography.row).fixedSize()
                    IntegrationStatusPill(row: row, now: now)
                }
                Text(description)
                    .font(Theme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(visibleNotes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(Theme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = row.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.rowDescription)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let options {
                    RowButton("Options…", action: options)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .opacity(row.status == .notFound ? 0.75 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.displayName), \(IntegrationsPane.statusText(row, now: now))")
    }

    private var visibleNotes: [String] {
        // The Codex trust step is already the row's description once installed.
        row.id == .codex && row.status.isInstalled ? row.notes.filter { !$0.contains("/hooks") } : row.notes
    }

    private var description: String {
        switch row.status {
        case .notFound:
            return row.id == .shell ? IntegrationsPane.installLine(row.id) : "Not found on this Mac. Install \(row.displayName) first, then come back."
        case .problem(let reason):
            return reason
        case .connected(.none) where row.id == .codex:
            // Codex skips hooks until they are trusted; its first event shows that was done.
            return "One more step: in Codex, open /hooks and trust Breakpoint’s entries."
        default:
            return IntegrationsPane.installLine(row.id)
        }
    }

    @ViewBuilder private var trailing: some View {
        if row.isBusy {
            ProgressView().controlSize(.small)
                .accessibilityLabel("Working")
        } else {
            switch row.status {
            case .notInstalled:
                RowButton("Install", prominent: true) { actions.install(row.id) }
            case .problem where row.canRemove:
                // Outdated, edited or failing its check: Install brings the entries up to date (and
                // checks again); Remove takes them out.
                HStack(spacing: 8) {
                    RowButton("Remove") { actions.uninstall(row.id) }
                    RowButton(IntegrationsPane.reinstallLabel(row.installState), prominent: true) { actions.install(row.id) }
                }
            case .problem:
                RowButton("Try again") { actions.install(row.id) }
            case .connected:
                RowButton("Remove") { actions.uninstall(row.id) }
            case .notFound:
                EmptyView()
            }
        }
    }
}

/// The status pill: ✓ "Connected" (mint; "· last event 2 min ago" once the tool has sent one),
/// "Not installed" / "Not found" (no glyph), a problem (triangle). When an install has just been
/// verified it flashes mint for a moment (SPEC §4.6: 0.4 s).
struct IntegrationStatusPill: View {
    let row: IntegrationRowState
    let now: Date
    @State private var flashing = false
    @State private var lastSeenConnectedAt: Date?
    @Environment(\.colorScheme) private var scheme
    private let traits = DesignTraits()

    var body: some View {
        HStack(spacing: 5) {
            icon
            Text(IntegrationsPane.statusText(row, now: now))
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(flashing ? Theme.Colors.onMint : foreground)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule(style: .circular).fill(flashing ? accent : background))
        .animation(traits.animation(.connectedFlash), value: flashing)
        .onAppear { lastSeenConnectedAt = row.connectedAt }
        .onChange(of: row.connectedAt) { _, connectedAt in
            guard let connectedAt, connectedAt != lastSeenConnectedAt else { lastSeenConnectedAt = connectedAt; return }
            lastSeenConnectedAt = connectedAt
            flashing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { flashing = false }
        }
        .fixedSize()
    }

    @ViewBuilder private var icon: some View {
        switch row.status {
        case .connected: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
        case .problem: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
        case .notInstalled, .notFound: EmptyView()
        }
    }

    private var accent: Color { Theme.Colors.accent(for: scheme) }

    private var foreground: Color {
        switch row.status {
        case .connected: return scheme == .dark ? accent : Color(hex: 0x0B7A63)
        default: return .secondary
        }
    }

    private var background: Color {
        switch row.status {
        case .connected: return accent.opacity(0.14)
        default: return Color.primary.opacity(0.06)
        }
    }
}

// MARK: - Codex

/// Codex folder override, shown only while Codex is not found in its default folder.
private struct CodexFolderRow: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    @State private var draft: String = ""

    var body: some View {
        SettingRow("Codex folder", description: "If Codex keeps its settings somewhere other than ~/.codex, choose that folder.",
                   systemImage: "folder") {
            HStack(spacing: 8) {
                TextField("~/.codex", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(commit)
                    .accessibilityLabel("Codex folder")
                RowButton("Choose…") { choose() }
            }
        }
        .onAppear { draft = state.settings.codexHome ?? "" }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        actions.updateSettings { $0.codexHome = trimmed.isEmpty ? nil : trimmed }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft = url.path
        commit()
    }
}

/// Options… on the Codex row: the legacy `notify` fallback for older Codex versions.
struct CodexOptionsSheet: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    let done: () -> Void

    var body: some View {
        let hooksInstalled = state.integration(.codex)?.canRemove ?? false
        let legacy = state.integration(.codexNotify)
        VStack(alignment: .leading, spacing: 16) {
            Text("Codex options").font(Theme.Typography.paneTitle)
            Text("Older Codex versions have no hooks. For those, Breakpoint can add one notify line to ~/.codex/config.toml instead; it reports only when a turn finishes.")
                .font(Theme.Typography.row)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsSection {
                SettingRow("Use legacy notify (older Codex)",
                           description: hooksInstalled
                               ? "Remove the Codex hooks first; the two are never installed together."
                               : "Refused if config.toml already has a notify line of its own.",
                           systemImage: "bell.badge") {
                    if legacy?.isBusy == true {
                        ProgressView().controlSize(.small)
                    } else if legacy?.canRemove == true {
                        RowButton("Remove") { actions.uninstall(.codexNotify) }
                    } else {
                        RowButton("Install") { actions.install(.codexNotify) }
                            .disabled(hooksInstalled)
                    }
                }
                if let error = legacy?.errorMessage ?? legacy.flatMap(Self.problem) {
                    SettingsDivider()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.rowDescription)
                        .foregroundStyle(.orange)
                        .padding(.vertical, 8)
                }
            }
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// What an install check found wrong with legacy notify (it has no status pill of its own).
    static func problem(_ row: IntegrationRowState) -> String? {
        if case .problem(let reason) = row.status { return reason }
        return nil
    }
}

// MARK: - Any tool

private struct AnyToolRow: View {
    let command: String
    @State private var copied = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05)))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 64)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(copied ? "Copied" : "Copy the command")
        }
        .padding(.vertical, 8)
    }
}
