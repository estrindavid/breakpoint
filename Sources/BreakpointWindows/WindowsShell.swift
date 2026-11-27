import BreakpointCore
import BreakpointRuntime
import Foundation
import WinSDK

/// The Windows windows: the tray icon and its flyout, every pop-up through `PopupStack`, the
/// break overlay on every monitor, Settings, Onboarding and the tour's coach. Created once by the
/// coordinator.
@MainActor
public final class WindowsShell: PlatformShell {
    public private(set) var surfaces: [SurfaceController] = []
    let stack: PopupStack
    let hotKeys = HotKeys()
    let tray: TrayController
    let settingsWindow: SettingsController
    let onboarding: OnboardingController
    let overlay: OverlayController
    let tourCoach: TourCoachController

    init(state: AppState, actions: AppActions, options: LaunchOptions, paths: BreakpointPaths) {
        SystemEvents.shared.start()
        stack = PopupStack(position: { [weak state] in state?.settings.popupPosition ?? .topCentre })
        tray = TrayController(state: state, actions: actions, hotKeys: hotKeys)
        settingsWindow = SettingsController(state: state, actions: actions)
        onboarding = OnboardingController(state: state, actions: actions)
        overlay = OverlayController(state: state, actions: actions)
        overlay.debugStallSeconds = options.debugStallMain
        let nudge = NudgeController(state: state, actions: actions, stack: stack, hotKeys: hotKeys)
        let chip = CountdownChipController(state: state, stack: stack)
        let cards = CardsController(state: state, actions: actions, stack: stack, hotKeys: hotKeys)
        tourCoach = TourCoachController(state: state, actions: actions, stack: stack, hotKeys: hotKeys, tray: tray)
        nudge.tourCaption = tourCoach.attachedCaption
        cards.tourCaption = tourCoach.attachedCaption
        onboarding.trayIconFrame = { [weak tray] in tray?.iconFrame }
        // The overlay first: when a break starts in the same sync as a pop-up leaves, the screen
        // is covered before anything else moves.
        surfaces = [tray, overlay, nudge, chip, cards, tourCoach, settingsWindow, onboarding]
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
        for surface in surfaces { surface.tearDown() }
        hotKeys.unregisterAll()
        tray.remove()
    }

    public var registeredHotKeys: Int { hotKeys.registeredCount }
}
