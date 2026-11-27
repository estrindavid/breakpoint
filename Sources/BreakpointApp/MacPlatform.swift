import AppKit
import BreakpointCore
import BreakpointKit
import UniformTypeIdentifiers

/// macOS's side of `AppPlatform`: AppKit for quitting, the pasteboard, the save panel and alerts,
/// the app bundle's layout, and the Kit services. The coordinator (BreakpointRuntime) holds the
/// behaviour; this is what used to be its AppKit calls.
@MainActor
final class MacPlatform: AppPlatform {
    func makeActivityMonitor() -> ActivityMonitoring { ActivityMonitor() }
    func makeHeadphoneMonitor() -> HeadphoneMotionMonitoring { HeadphoneMotionMonitor() }
    func makeSoundPlayer() -> SoundPlaying { SoundPlayer() }
    func makeLoginItem() -> LoginItemControlling { LoginItem() }
    func makeUpdateFetcher() -> UpdateFetching { UpdateFetcher() }

    func makeShell(state: AppState, actions: AppActions, options: LaunchOptions, paths: BreakpointPaths) -> PlatformShell {
        MacShell(state: state, actions: actions, options: options, paths: paths)
    }

    func quit() { NSApp.terminate(nil) }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportHistory(suggestedName: String, write: (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func confirm(title: String, message: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    var appLocation: URL { Bundle.main.bundleURL }

    /// The bundled CLI (Contents/Helpers/breakpoint) when running from the app bundle, else (a
    /// development build in `.build/…`) the `breakpoint` built next to the app's executable.
    var bundledCLI: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/breakpoint")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        guard let executable = Bundle.main.executableURL, Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("breakpoint")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    func relaunchHelper(in app: URL) -> URL { app.appendingPathComponent("Contents/Helpers/breakpoint") }

    func startRelaunchHelper(_ helper: URL, pid: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup \"$0\" update-relaunch --pid \"$1\" >/dev/null 2>&1 &", helper.path, "\(pid)"]
        try process.run()
        process.waitUntilExit()
    }

    func launchDiagnostics() -> String? {
        "activation policy: " + (NSApp.activationPolicy() == .accessory ? "accessory" : "regular")
    }
}

/// The macOS windows: the status item and popover, every pop-up through `TransientPanelStack`,
/// the overlay, Settings and Onboarding, created once as the coordinator used to create them.
@MainActor
final class MacShell: PlatformShell {
    let surfaces: [SurfaceController]
    private let statusItem: StatusItemController
    private let settingsWindow: SettingsWindowController
    private let onboarding: OnboardingWindowController
    private let hotKeys = HotKeyCenter()
    private let focusRestorer = FocusRestorer()
    private let watchdog: OverlayWatchdog
    private let panelStack: TransientPanelStack

    init(state: AppState, actions: AppActions, options: LaunchOptions, paths: BreakpointPaths) {
        watchdog = OverlayWatchdog(logURL: paths.watchdogLog, appURL: Bundle.main.bundleURL)
        let settingsForStack = { [weak state] in state?.settings.popupPosition ?? .topCentre }
        panelStack = TransientPanelStack(position: settingsForStack)
        statusItem = StatusItemController(state: state, actions: actions)
        statusItem.hotKeys = hotKeys
        settingsWindow = SettingsWindowController(state: state, actions: actions)
        onboarding = OnboardingWindowController(state: state, actions: actions)
        let overlay = BreakOverlayController(state: state, actions: actions, focusRestorer: focusRestorer, watchdog: watchdog)
        overlay.debugStallSeconds = options.debugStallMain
        surfaces = [
            statusItem,
            NudgePanelController(state: state, actions: actions, stack: panelStack, hotKeys: hotKeys),
            CountdownChipController(state: state, stack: panelStack),
            overlay,
            ResumeCardController(state: state, actions: actions, stack: panelStack, hotKeys: hotKeys),
            AwayNoteController(state: state, actions: actions, stack: panelStack),
            ToastController(state: state, actions: actions, stack: panelStack),
            WindDownCardController(state: state, actions: actions, stack: panelStack),
            UpdateCardController(state: state, actions: actions, stack: panelStack),
            TourCoachController(state: state, actions: actions, stack: panelStack, hotKeys: hotKeys),
            settingsWindow,
            onboarding,
        ]
    }

    var hasStatusItem: Bool { true }
    func installStatusItem() { statusItem.install() }
    func showPopover() { statusItem.showPopover() }
    func closePopover() { statusItem.closePopover() }

    func statusItemDiagnostics() -> String? {
        statusItem.statusItemFrame.map { "frame \($0)" }
            ?? "none (hidden by macOS: \(statusItem.visibilityDiagnostics))"
    }

    func showSettings() { settingsWindow.show() }
    func closeSettings() { settingsWindow.close() }
    func showOnboarding() { onboarding.show() }
    var isOnboardingVisible: Bool { onboarding.isVisible }

    func relayoutPopups() { panelStack.relayout() }
    func dismissAllPopups() { panelStack.dismissAll() }
    var onPopupEvicted: ((UUID) -> Void)? {
        get { panelStack.onEvicted }
        set { panelStack.onEvicted = newValue }
    }

    func stop() {
        hotKeys.unregisterAll()
        watchdog.stop()
    }

    var registeredHotKeys: Int { hotKeys.registeredCount }
}
