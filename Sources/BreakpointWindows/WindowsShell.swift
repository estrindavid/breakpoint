// Enabled once every Windows surface it creates exists (the controllers land one by one).
#if false
import BreakpointCore
import BreakpointRuntime
import Foundation
import WinSDK

/// The Windows windows: the tray icon and its flyout, every pop-up through `PopupStack`, the
/// break overlay on every monitor, Settings and Onboarding. Created once by the coordinator.
@MainActor
public final class WindowsShell: PlatformShell {
    public private(set) var surfaces: [SurfaceController] = []
    let stack: PopupStack
    let hotKeys = HotKeys()
    let tray: TrayController
    let settingsWindow: SettingsController
    let onboarding: OnboardingController

    init(state: AppState, actions: AppActions, options: LaunchOptions, paths: BreakpointPaths) {
        stack = PopupStack(position: { [weak state] in state?.settings.popupPosition ?? .topCentre })
        tray = TrayController(state: state, actions: actions, hotKeys: hotKeys)
        settingsWindow = SettingsController(state: state, actions: actions)
        onboarding = OnboardingController(state: state, actions: actions)
        let overlay = OverlayController(state: state, actions: actions)
        overlay.debugStallSeconds = options.debugStallMain
        surfaces = [
            tray,
            NudgeController(state: state, actions: actions, stack: stack, hotKeys: hotKeys),
            CountdownChipController(state: state, stack: stack),
            overlay,
            CardsController(state: state, actions: actions, stack: stack, hotKeys: hotKeys),
            TourCoachController(state: state, actions: actions, stack: stack, hotKeys: hotKeys, tray: tray),
            settingsWindow,
            onboarding,
        ]
    }

    public var hasStatusItem: Bool { true }
    public func installStatusItem() { tray.install() }
    public func showPopover() { tray.showFlyout() }
    public func closePopover() { tray.closeFlyout() }
    public func statusItemDiagnostics() -> String? { tray.diagnostics }

    public func showSettings() { settingsWindow.show() }
    public func closeSettings() { settingsWindow.close() }
    public func showOnboarding() { onboarding.show() }
    public var isOnboardingVisible: Bool { onboarding.isVisible }

    public func relayoutPopups() { stack.relayout() }
    public func dismissAllPopups() { stack.dismissAll() }
    public var onPopupEvicted: ((UUID) -> Void)? {
        get { stack.onEvicted }
        set { stack.onEvicted = newValue }
    }

    public func stop() {
        hotKeys.unregisterAll()
        tray.remove()
    }

    public var registeredHotKeys: Int { hotKeys.registeredCount }
}
#endif
