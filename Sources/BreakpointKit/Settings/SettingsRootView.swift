import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

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
    /// Height of the pane header: the window's title bar with its (empty) unified toolbar on
    /// macOS 14 and 15 (taller on macOS 26).
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

    /// The pane scrolls under its header. The header is pinned over the scroll view's top edge on
    /// an opaque window-coloured backing with a hairline, so rows disappear beneath it cleanly.
    /// (On macOS 26 the title bar is taller than the header, and SwiftUI stretches a scroll view
    /// that starts inside the title bar up to the window's top; a header without a backing then
    /// had the scrolled rows drawn through it.)
    private var detail: some View {
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
            .safeAreaInset(edge: .top, spacing: 0) {
                PaneHeader(pane: selection.pane, height: Self.titlebarHeight)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The pane's icon and title above its content, on the window's own (opaque) colour, with a
/// hairline under it: a stronger one under Increase Contrast. Opaque, so Reduce Transparency
/// changes nothing here.
private struct PaneHeader: View {
    let pane: SettingsPane
    let height: CGFloat
    private let traits = DesignTraits()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SidebarTile(systemImage: pane.systemImage, index: pane.index)
                Text(pane.title)
                    .font(Theme.Typography.paneTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: height)
            if traits.increaseContrast {
                Rectangle()
                    .fill(Color.primary.opacity(Theme.TextStep.hairline.opacity))
                    .frame(height: 1)
            } else {
                Divider()
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
