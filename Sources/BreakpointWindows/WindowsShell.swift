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

    init(state: AppState, actions: AppActions, options: LaunchOptions, paths: BreakpointPaths) {
        SystemEvents.shared.start()
        stack = PopupStack(position: { [weak state] in state?.settings.popupPosition ?? .topCentre })
        tray = TrayController(state: state, actions: actions, hotKeys: hotKeys)
        surfaces = [tray]
    }

    public var hasStatusItem: Bool { true }
    public func installStatusItem() { tray.install() }
    public func showPopover() { tray.showFlyout() }
    public func closePopover() { tray.closeFlyout() }
    public func statusItemDiagnostics() -> String? { tray.diagnostics }

    public func showSettings() {}
    public func closeSettings() {}
    public func showOnboarding() {}
    public var isOnboardingVisible: Bool { false }

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
