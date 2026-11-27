import AppKit
import SwiftUI
import BreakpointCore

// SPEC §3.9.

/// Sidebar (groups Breaks · Connections · You, 20 pt tiles on the mint → indigo ramp) and the
/// selected pane (icon + 17 pt semibold title, inset grouped sections 24 pt apart).
public struct SettingsRootView: View {
    @ObservedObject private var state: AppState
    private let actions: AppActions
    @ObservedObject private var selection: SettingsSelection
    @Environment(\.colorScheme) private var scheme

    public init(state: AppState, actions: AppActions, selection: SettingsSelection) {
        self.state = state
        self.actions = actions
        self.selection = selection
    }

    static let groups = ["Breaks", "Connections", "You"]
    /// Height of the window's title bar with its (empty) unified toolbar.
    static let titlebarHeight: CGFloat = 52

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Theme.Layout.settingsSidebarWidth)
            Divider().ignoresSafeArea()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .tint(Theme.Colors.accent(for: scheme))
    }

    private var sidebar: some View {
        List(selection: Binding(get: { selection.pane }, set: { if let pane = $0 { selection.pane = pane } })) {
            ForEach(Self.groups, id: \.self) { group in
                Section(group) {
                    ForEach(SettingsPane.allCases.filter { $0.group == group }) { pane in
                        Label {
                            Text(pane.title)
                        } icon: {
                            SidebarTile(systemImage: pane.systemImage, index: pane.index)
                        }
                        .tag(pane)
                        .accessibilityLabel(pane.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Self.titlebarHeight - 8) }
        .background(SidebarMaterial())
        .accessibilityLabel("Settings sections")
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SidebarTile(systemImage: selection.pane.systemImage, index: selection.pane.index)
                Text(selection.pane.title)
                    .font(Theme.Typography.paneTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: Self.titlebarHeight)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    SettingsPaneView(pane: selection.pane, state: state, actions: actions)
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity)
                        .id(selection.pane)
                }
                .onChange(of: selection.pane) { _, pane in proxy.scrollTo(pane, anchor: .top) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The content of one pane (without the header), for the window and for snapshots.
public struct SettingsPaneView: View {
    private let pane: SettingsPane
    @ObservedObject private var state: AppState
    private let actions: AppActions

    public init(pane: SettingsPane, state: AppState, actions: AppActions) {
        self.pane = pane
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        switch pane {
        case .breaks: BreaksPane(state: state, actions: actions)
        case .routine: RoutinePane(state: state, actions: actions)
        case .pauses: PausesPane(state: state, actions: actions)
        case .windDown: WindDownPane(state: state, actions: actions)
        case .integrations: IntegrationsPane(state: state, actions: actions)
        case .general: GeneralPane(state: state, actions: actions)
        case .privacy: PrivacyPane(state: state, actions: actions)
        case .about: AboutPane(state: state, actions: actions)
        }
    }
}

/// Snapshot-only states that cannot be reached through `AppState` (sheets open).
public enum SettingsPanePreview {
    case callOptions
    case codexOptions
}

extension SettingsPaneView {
    /// A pane in a snapshot-only state.
    @MainActor @ViewBuilder
    public static func preview(_ preview: SettingsPanePreview, state: AppState) -> some View {
        switch preview {
        case .callOptions:
            CallOptionsSheet(isOn: .constant(state.settings.pauseForCamera)) {}
        case .codexOptions:
            CodexOptionsSheet(state: state, actions: .noop) {}
        }
    }
}

/// The sidebar material, following the system appearance.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
