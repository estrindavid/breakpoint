import AppKit
import SwiftUI
import BreakpointCore

// SPEC §3.9 General pane.

/// Getting started (the tour and hints, SPEC §3.12), open at login, menu-bar text with a live
/// preview, pop-up position thumbnails, nudge hotkeys, popover shortcut recorder, chimes with ▶
/// and a volume slider.
public struct GeneralPane: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    @Environment(\.loginItemStatusProvider) private var loginStatusProvider
    @Environment(\.colorScheme) private var scheme
    @State private var loginStatus: LoginItemStatus?
    @State private var volumeDraft: Double?

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        PaneStack {
            SettingsSection("Getting started") {
                SettingRow("The one-minute tour",
                           description: "Rehearses one break with sample data, on the real screens. Nothing is recorded.",
                           systemImage: "figure.wave") {
                    RowButton("Take the tour") { actions.replayTour() }
                }
                SettingsDivider()
                ToggleRow(title: "Show hints",
                          description: "The first time a pop-up or the break screen appears, one short line says how to use it. Each shows once.",
                          systemImage: "lightbulb", isOn: settingBinding(state, actions, \.showHints))
            }

            SettingsSection("Startup") {
                ToggleRow(title: "Open at login", description: loginDescription, systemImage: "power",
                          isOn: settingBinding(state, actions, \.launchAtLogin))
                if loginStatus == .requiresApproval, state.settings.launchAtLogin {
                    SettingsDivider()
                    SettingRow("Allow Breakpoint in Login Items",
                               description: "macOS needs your OK in System Settings → General → Login Items.",
                               systemImage: "exclamationmark.circle") {
                        RowButton("Open Login Items") { LoginItem.openSystemSettings() }
                    }
                }
            }

            SettingsSection("Menu bar") {
                HStack(spacing: 12) {
                    SentenceRow {
                        Text("Show")
                        Picker("Menu-bar text", selection: settingBinding(state, actions, \.menuBarText)) {
                            Text("nothing").tag(MenuBarTextMode.nothing)
                            Text("time to next break").tag(MenuBarTextMode.timeToNextBreak)
                            Text("agent state").tag(MenuBarTextMode.agentState)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityLabel("Show next to the menu-bar icon")
                        Text("next to the menu-bar icon")
                    }
                    MenuBarStripPreview([menuBarSample], backdrop: scheme == .dark ? .dark : .light)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                        .accessibilityHidden(true)
                }
            }
            SectionFootnote("While breaks are paused it reads “Paused”, whatever you choose.")

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Pop-ups")
                HStack(spacing: 12) {
                    ForEach(PopupPosition.allCases, id: \.self) { position in
                        PresetCard(title: Self.positionTitle(position),
                                   detail: Self.positionDetail(position),
                                   isSelected: state.settings.popupPosition == position,
                                   action: { actions.updateSettings { $0.popupPosition = position } }) {
                            PositionThumbnail(position: position, isSelected: state.settings.popupPosition == position)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            SectionFootnote("Pop-ups appear on the display your pointer is on.")

            SettingsSection("Keyboard") {
                ToggleRow(title: "Hotkeys for the nudge",
                          description: "⌃⌥⌘B starts the offered break. ⌃⌥⌘. dismisses it, or a resume card.",
                          systemImage: "keyboard", isOn: settingBinding(state, actions, \.nudgeHotkeys))
                SettingsDivider()
                SettingRow("Popover shortcut", description: "Opens and closes Breakpoint’s menu-bar window from anywhere.",
                           systemImage: "command") {
                    ShortcutRecorder(combo: settingBinding(state, actions, \.popoverHotkey))
                }
            }

            SettingsSection("Sounds") {
                SettingRow("Chime when an agent needs you during a break",
                           description: "A soft two-note chime, once. Never while a microphone or camera is on.",
                           systemImage: "bell") {
                    HStack(spacing: 10) {
                        PlayButton(label: "Play the needs-you chime") { actions.previewSound(.needsYouChime) }
                        Toggle("Chime when an agent needs you", isOn: settingBinding(state, actions, \.chimeNeedsYou))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                SettingsDivider()
                SettingRow("Chime when a break ends", description: "Plays as a completed break closes.",
                           systemImage: "bell.and.waves.left.and.right") {
                    HStack(spacing: 10) {
                        PlayButton(label: "Play the break-end chime") { actions.previewSound(.breakEndChime) }
                        Toggle("Chime when a break ends", isOn: settingBinding(state, actions, \.chimeBreakEnd))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                SettingsDivider()
                SettingRow("Tick at each new stretch step",
                           description: "A short, quiet tone, so you can follow a stretch without watching.",
                           systemImage: "metronome") {
                    HStack(spacing: 10) {
                        PlayButton(label: "Play the step tick") { actions.previewSound(.stepTick) }
                        Toggle("Tick at each new stretch step", isOn: settingBinding(state, actions, \.stepTick))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                SettingsDivider()
                HStack(spacing: 10) {
                    Text("Volume").font(Theme.Typography.row)
                    Spacer(minLength: 12)
                    Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: volumeBinding, in: 0...1) { editing in
                        if !editing, let draft = volumeDraft {
                            actions.updateSettings { $0.volume = draft }
                            volumeDraft = nil
                            actions.previewSound(.needsYouChime)
                        }
                    }
                    .frame(width: 180)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(volumePercent) percent")
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("\(volumePercent)%")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.vertical, 8)
                .frame(minHeight: Theme.Layout.settingRowMinHeight)
            }
        }
        .onAppear { loginStatus = loginStatusProvider() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginStatus = loginStatusProvider()
        }
        .onChange(of: state.settings.launchAtLogin) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loginStatus = loginStatusProvider() }
        }
    }

    private var loginDescription: String {
        switch loginStatus {
        case .unavailable(let reason)?: return "Breakpoint starts quietly in the menu bar. \(reason)"
        default: return "Breakpoint starts quietly in the menu bar."
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { volumeDraft ?? state.settings.volume }, set: { volumeDraft = $0 })
    }

    private var volumePercent: Int { Int(((volumeDraft ?? state.settings.volume) * 100).rounded()) }

    /// What the item would show with the chosen text option, using the current state.
    private var menuBarSample: MenuBarState {
        var sample = state.menuBar
        switch state.settings.menuBarText {
        case .nothing: sample.text = nil
        case .timeToNextBreak: sample.text = Copy.menuBarCountdown(state.status.nextBreakIn)
        case .agentState:
            let working = state.sessions.first { $0.state == .working }
            sample.text = Copy.menuBarAgent(working?.displayName ?? "Claude", elapsed: working?.runElapsed(at: state.now) ?? 180)
        }
        if state.status.isPaused { sample.text = "Paused" }
        return sample
    }

    static func positionDetail(_ position: PopupPosition) -> String {
        switch position {
        case .topLeft: return "Near the menus"
        case .topCentre: return "The default"
        case .topRight: return "Near the clock"
        }
    }

    static func positionTitle(_ position: PopupPosition) -> String {
        switch position {
        case .topLeft: return "Top left"
        case .topCentre: return "Top centre"
        case .topRight: return "Top right"
        }
    }
}

/// A miniature desktop showing where pop-ups land: wallpaper, menu bar (app menus on the left,
/// status icons with Breakpoint's mark on the right), a window for scale, and a small nudge card
/// (gradient badge, title and subtitle lines) 8 pt-equivalent under the menu bar at the chosen
/// position. Proportions follow a 1512 × 982 display, with the card drawn a little larger so it
/// reads at thumbnail size.
struct PositionThumbnail: View {
    let position: PopupPosition
    var isSelected = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let menuBar = max(5, h * 0.075)
            let inset = w * 0.05
            let card = CGSize(width: w * 0.36, height: h * 0.2)
            let x: CGFloat = {
                switch position {
                case .topLeft: return inset
                case .topCentre: return (w - card.width) / 2
                case .topRight: return w - inset - card.width
                }
            }()
            ZStack(alignment: .topLeading) {
                wallpaper
                // A window, for scale.
                RoundedRectangle(cornerRadius: h * 0.04, style: .continuous)
                    .fill(Color.white.opacity(dark ? 0.10 : 0.55))
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(dark ? 0.08 : 0.5)).frame(height: h * 0.06)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: h * 0.04, style: .continuous))
                    .frame(width: w * 0.52, height: h * 0.48)
                    .offset(x: w * 0.24, y: h * 0.42)
                menuBarStrip(width: w, height: menuBar)
                miniNudge(size: card)
                    .offset(x: x, y: menuBar + h * 0.035)
                    .opacity(isSelected ? 1 : 0.8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var dark: Bool { scheme == .dark }

    private var wallpaper: some View {
        LinearGradient(colors: dark
                       ? [Color(hex: 0x23443F), Color(hex: 0x272C52)]
                       : [Color(hex: 0xCDEDE4), Color(hex: 0xD8DCF6)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func menuBarStrip(width w: CGFloat, height: CGFloat) -> some View {
        let ink = dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45)
        return ZStack {
            Rectangle().fill(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.6))
            HStack(spacing: height * 0.6) {
                ForEach([0.07, 0.05, 0.05, 0.06], id: \.self) { fraction in
                    Capsule().fill(ink).frame(width: w * fraction, height: height * 0.28)
                }
                Spacer(minLength: 0)
                BrandMark(.idle).foregroundStyle(ink).frame(height: height * 0.6)
                Capsule().fill(ink).frame(width: w * 0.04, height: height * 0.28)
                Capsule().fill(ink).frame(width: w * 0.07, height: height * 0.28)
            }
            .padding(.horizontal, w * 0.03)
        }
        .frame(width: w, height: height)
    }

    /// The nudge in miniature: dark glass, gradient badge, a title and a subtitle line.
    private func miniNudge(size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: size.height * 0.3, style: .continuous)
        let badge = size.height * 0.42
        return HStack(alignment: .top, spacing: size.width * 0.05) {
            Circle().fill(Theme.Colors.brandGradient).frame(width: badge, height: badge)
            VStack(alignment: .leading, spacing: size.height * 0.1) {
                Capsule().fill(Color.white.opacity(0.9)).frame(width: size.width * 0.38, height: size.height * 0.1)
                Capsule().fill(Color.white.opacity(0.45)).frame(width: size.width * 0.5, height: size.height * 0.08)
                HStack(spacing: size.width * 0.03) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: size.width * 0.17, height: size.height * 0.16)
                    Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                        .frame(width: size.width * 0.2, height: size.height * 0.16)
                }
                .padding(.top, size.height * 0.02)
            }
            .padding(.top, size.height * 0.04)
            Spacer(minLength: 0)
        }
        .padding(size.height * 0.13)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(shape.fill(Theme.Colors.glassApproximation))
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

// MARK: - Login item status (injectable for snapshots)

private struct LoginItemStatusProviderKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> LoginItemStatus = { LoginItem.status }
}

extension EnvironmentValues {
    var loginItemStatusProvider: @MainActor @Sendable () -> LoginItemStatus {
        get { self[LoginItemStatusProviderKey.self] }
        set { self[LoginItemStatusProviderKey.self] = newValue }
    }
}

extension View {
    /// Snapshots: show the General pane as if the login item were in `status`.
    public func loginItemStatusPreview(_ status: LoginItemStatus) -> some View {
        environment(\.loginItemStatusProvider, { status })
    }
}
