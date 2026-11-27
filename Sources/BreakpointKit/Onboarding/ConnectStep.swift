import SwiftUI
import BreakpointCore

// SPEC §3.10 step 3.

/// Detected tools, each with Install. Install is the whole step: the app writes the hooks, checks
/// them by itself (`InstallCheck`) and the row turns to a mint ✓ "Connected" at once. If the check
/// fails, the row says what is wrong and what to do instead. Codex alone keeps one line until it
/// is first heard from: it runs the hooks only once they are trusted in /hooks. "Skip for now"
/// (the footer's Continue until something is installed) is the step's only skip control. Nothing
/// is written until Install is pressed.
public struct ConnectStep: View {
    @ObservedObject var state: AppState
    let actions: AppActions

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        let rows = state.integrations.filter { IntegrationID.settingsRows.contains($0.id) }
        let detected = rows.filter { $0.status != .notFound }
        let missing = rows.filter { $0.status == .notFound }
        OnboardingPage(title: "Connect your agent",
                       sentence: "Breakpoint adds a few small hooks to your tool’s settings, so it knows when an agent starts and stops. Nothing is written until you press Install.") {
            VStack(alignment: .leading, spacing: 10) {
                if detected.isEmpty {
                    Text("No supported tools found on this Mac yet. You can connect one later in Settings → Integrations.")
                        .font(Theme.Typography.row)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OnboardingCard())
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(detected.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider().padding(.leading, 46) }
                            ConnectRow(row: row, actions: actions)
                        }
                    }
                    .background(OnboardingCard())
                }
                if !missing.isEmpty {
                    Text("Not on this Mac: \(missing.map(\.displayName).joined(separator: ", ")).")
                        .font(Theme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .frame(width: 456)
        }
    }
}

struct OnboardingCard: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.settingsSection, style: .continuous)
        shape.fill(scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))
            .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07), lineWidth: 1))
    }
}

private struct ConnectRow: View {
    let row: IntegrationRowState
    let actions: AppActions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            SourceTile(symbol: MenuBarGlyphs.integrationSymbol(row.id), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName).font(Theme.Typography.bodySemibold)
                detail
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 46)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var detail: some View {
        switch row.status {
        case .notInstalled:
            Text(Self.shortLine(row.id))
                .font(Theme.Typography.rowDescription).foregroundStyle(.secondary).lineLimit(1)
        case .connected(let lastEvent):
            Text(Self.connectedLine(row, lastEvent: lastEvent))
                .font(Theme.Typography.rowDescription).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .problem(let reason):
            // In place of the ✓: what is wrong and what to do, in one line.
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typography.rowDescription).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .notFound:
            EmptyView()
        }
        if let error = row.errorMessage {
            Text(error).font(Theme.Typography.rowDescription).foregroundStyle(.orange).lineLimit(2)
        }
    }

    /// Under a connected row: Codex's trust step until Codex is first heard from (it skips hooks
    /// nobody trusted), else the install's own note where there is one ("Open a new terminal
    /// window to start."), else where the hooks live.
    static func connectedLine(_ row: IntegrationRowState, lastEvent: Date?) -> String {
        if row.id == .codex { return lastEvent == nil ? codexTrustLine : shortLine(row.id) }
        return row.notes.isEmpty ? shortLine(row.id) : row.notes.joined(separator: " ")
    }

    static let codexTrustLine = "One step in Codex: open /hooks and trust the entries."

    static func shortLine(_ id: IntegrationID) -> String {
        switch id {
        case .claudeCode: return "Hooks in ~/.claude/settings.json"
        case .cursor: return "Hooks in ~/.cursor/hooks.json"
        case .codex, .codexNotify: return "Hooks in ~/.codex/hooks.json"
        case .copilot: return "One file in ~/.copilot/hooks"
        case .gemini: return "Hooks in ~/.gemini/settings.json"
        case .shell: return "Breaks during long commands"
        }
    }

    @ViewBuilder private var trailing: some View {
        if row.isBusy {
            Spinner().accessibilityLabel("Installing \(row.displayName)")
        } else {
            switch row.status {
            case .problem where row.installState == .installed:
                // A failed install check: trying again is the one thing to do here (Remove is in
                // Settings → Integrations), which leaves the explanation room.
                PillButton("Install again", role: .primary, size: .small) { actions.install(row.id) }
                    .accessibilityLabel("Install \(row.displayName) again")
            case .problem where row.canRemove:
                HStack(spacing: 6) {
                    PillButton("Remove", role: .tertiary, size: .small) { actions.uninstall(row.id) }
                        .accessibilityLabel("Remove \(row.displayName)")
                    PillButton(IntegrationsPane.reinstallLabel(row.installState), role: .primary, size: .small) {
                        actions.install(row.id)
                    }
                    .accessibilityLabel("Install \(row.displayName) again")
                }
            case .notInstalled, .problem:
                PillButton("Install", role: .primary, size: .small) { actions.install(row.id) }
                    .accessibilityLabel("Install \(row.displayName)")
            case .connected:
                ConnectedPill(connectedAt: row.connectedAt)
                    .accessibilityLabel("\(row.displayName) connected")
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .notFound:
                EmptyView()
            }
        }
    }
}

/// A small indeterminate spinner drawn in SwiftUI (static under Reduce Motion).
struct Spinner: View {
    private let traits = DesignTraits()

    var body: some View {
        Group {
            if traits.runsContinuousAnimations {
                TimelineView(.animation) { context in
                    arc.rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                }
            } else {
                arc
            }
        }
        .frame(width: 16, height: 16)
    }

    private var arc: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}
