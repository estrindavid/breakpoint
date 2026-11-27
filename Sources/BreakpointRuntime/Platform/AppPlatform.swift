import Foundation
import BreakpointCore

/// Everything the coordinator needs from the operating system that is not a service
/// (`PlatformServices.swift`) or a window (`PlatformShell`): quitting, the clipboard, the save
/// panel and alerts, opening a web page, where the app lives, and starting the update helper.
///
/// macOS: `MacPlatform` (Sources/BreakpointApp). Windows: `WindowsPlatform`
/// (Sources/BreakpointWindows). Both are thin; the behaviour is the coordinator's.
@MainActor
public protocol AppPlatform: AnyObject {
    // MARK: Services (the debug harness may replace each)

    func makeActivityMonitor() -> ActivityMonitoring
    func makeHeadphoneMonitor() -> HeadphoneMotionMonitoring
    func makeSoundPlayer() -> SoundPlaying
    func makeLoginItem() -> LoginItemControlling
    func makeUpdateFetcher() -> UpdateFetching

    /// The windows, pop-ups and the menu-bar or tray item, created once.
    func makeShell(state: AppState, actions: AppActions, options: LaunchOptions, paths: BreakpointPaths) -> PlatformShell

    // MARK: System

    /// Quits the app (the platform calls the coordinator's `stop()` on the way out).
    func quit()
    /// Puts text on the clipboard (the wind-down note).
    func copyText(_ text: String)
    /// Asks where to save the history (a save panel) and writes it there with `write`; reports a
    /// failure itself.
    func exportHistory(suggestedName: String, write: (URL) throws -> Void)
    /// Asks once whether to delete all data (`title`, `message`, a destructive `confirm` button).
    func confirm(title: String, message: String, confirm: String) -> Bool
    /// Tells the person something in a modal alert (an error, the socket's problem).
    func alert(title: String, message: String)
    /// Opens a web page in the default browser.
    func open(_ url: URL)

    /// The installed app an update replaces (the bundle, or the install folder on Windows).
    var appLocation: URL { get }
    /// The `breakpoint` CLI shipped with the app, copied to `~/.breakpoint/bin` (SPEC §5.2).
    var bundledCLI: URL? { get }
    /// The update helper inside an app bundle (`breakpoint update-relaunch`).
    func relaunchHelper(in app: URL) -> URL
    /// Starts `helper update-relaunch --pid PID` so it outlives this process.
    func startRelaunchHelper(_ helper: URL, pid: Int32) throws
    /// One line about the app's presence (the macOS activation policy; the Windows tray), logged
    /// at launch.
    func launchDiagnostics() -> String?
}

/// The app's windows, pop-ups and menu-bar (tray) item: the controllers the coordinator syncs, and
/// the few things it asks of them directly.
@MainActor
public protocol PlatformShell: AnyObject {
    /// Every controller, synced after each state change.
    var surfaces: [SurfaceController] { get }
    /// A real menu-bar or tray item exists (false headless).
    var hasStatusItem: Bool { get }

    func installStatusItem()
    func showPopover()
    func closePopover()
    /// Where the status item is, logged once after launch.
    func statusItemDiagnostics() -> String?

    func showSettings()
    func closeSettings()
    func showOnboarding()
    var isOnboardingVisible: Bool { get }

    /// The pop-up position setting changed.
    func relayoutPopups()
    func dismissAllPopups()
    /// A pop-up was pushed out by a higher-priority one (SPEC §3.0).
    var onPopupEvicted: ((UUID) -> Void)? { get set }

    /// Hotkeys off, watchdog stopped: before quitting.
    func stop()
    /// Global hotkeys registered now (the debug state).
    var registeredHotKeys: Int { get }
}

/// No windows at all (`--debug-headless`): the harness's recorder stands in for every surface.
@MainActor
final class HeadlessShell: PlatformShell {
    let surfaces: [SurfaceController]
    var onPopupEvicted: ((UUID) -> Void)?

    init(surfaces: [SurfaceController]) { self.surfaces = surfaces }

    var hasStatusItem: Bool { false }
    func installStatusItem() {}
    func showPopover() {}
    func closePopover() {}
    func statusItemDiagnostics() -> String? { nil }
    func showSettings() {}
    func closeSettings() {}
    func showOnboarding() {}
    var isOnboardingVisible: Bool { false }
    func relayoutPopups() {}
    func dismissAllPopups() {}
    func stop() {}
    var registeredHotKeys: Int { 0 }
}

/// Launch arguments (SPEC §7.3), the same on both platforms.
public struct LaunchOptions {
    /// `--debug-stall-main N`: block the main thread for N seconds during the next overlay.
    public var debugStallMain: TimeInterval?
    /// `--show-onboarding`: show onboarding even if it was completed (development).
    public var forceOnboarding = false
    /// `--tour`: start the one-minute tour after launch, as Settings → General would (SPEC §3.12).
    public var startTour = false
    /// `--quit-after N`: quit normally after N seconds (smoke tests of launch and quit).
    public var quitAfter: TimeInterval?
    /// `--demo NAME`: play a break-screen scenario instead of running the app (`--demo list`).
    public var demo: String?
    /// `--demo-volume V`: chime volume in the demo, 0…1 (0 mutes it).
    public var demoVolume: Double?
    /// `--signals`: print the activity monitor's diagnostic report and exit.
    public var printSignals = false
    /// Debug-build-only options for the end-to-end harness (always off in release builds).
    public var debug = DebugOptions()

    public init(arguments: [String]) {
        if let i = arguments.firstIndex(of: "--debug-stall-main"), i + 1 < arguments.count {
            debugStallMain = TimeInterval(arguments[i + 1])
        }
        forceOnboarding = arguments.contains("--show-onboarding")
        startTour = arguments.contains("--tour")
        if let i = arguments.firstIndex(of: "--quit-after"), i + 1 < arguments.count {
            quitAfter = TimeInterval(arguments[i + 1])
        }
        if let i = arguments.firstIndex(of: "--demo"), i + 1 < arguments.count {
            demo = arguments[i + 1]
        }
        if let i = arguments.firstIndex(of: "--demo-volume"), i + 1 < arguments.count {
            demoVolume = Double(arguments[i + 1])
        }
        printSignals = arguments.contains("--signals")
        #if DEBUG
        debug = DebugOptions(arguments: arguments)
        #endif
    }
}

/// Launch options of the end-to-end harness (CLAUDE.md, "Testing the whole app"). Parsed only in
/// debug builds; a release build ignores the flags and every value stays off.
///
/// - `--debug-headless`: all logic runs, but no window, panel, status item, popover, alert, sound
///   or hotkey is shown or registered; recording surfaces log what would have been shown, and
///   time out nudges and cards the way the real ones do (without hover).
/// - `--debug-simulate`: the activity monitor, call signals, presence and the AirPods check are
///   simulated and driven by `breakpoint debug input|call|presence|headphones`; the app's clock
///   can be moved with `breakpoint debug advance|jump`.
/// - `--debug-timers SCREEN,STILL`: start with these timer values in seconds.
/// - `--debug-trace`: print every change of what is (or would be) on screen, with the clock.
public struct DebugOptions {
    public var headless = false
    public var simulate = false
    public var trace = false
    public var timers: (screen: TimeInterval, still: TimeInterval)?

    public init() {}

    public init(arguments: [String]) {
        headless = arguments.contains("--debug-headless")
        simulate = arguments.contains("--debug-simulate")
        trace = arguments.contains("--debug-trace")
        if let i = arguments.firstIndex(of: "--debug-timers"), i + 1 < arguments.count {
            let parts = arguments[i + 1].split(separator: ",").compactMap { TimeInterval($0) }
            if parts.count == 2 { timers = (parts[0], parts[1]) }
        }
    }
}
