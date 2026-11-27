import AppKit
import BreakpointCore
import BreakpointKit

/// Owns the coordinator for the life of the app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var demo: BreakDemo?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions(arguments: CommandLine.arguments)
        if options.printSignals {
            printSignalReport()
            return
        }
        if let name = options.demo {
            runDemo(name, options: options)
            return
        }
        let coordinator = AppCoordinator(paths: .live(), options: options)
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Finder, Spotlight) shows the popover instead of a window.
        coordinator?.showPopover()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// `--signals`: prints the activity monitor's diagnostic report (every signal it reads, with
    /// one name-free line per audio device and the decision reached) and exits.
    private func printSignalReport() {
        let monitor = ActivityMonitor()
        monitor.start()
        // Let the lock and display notifications that are already queued arrive first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            print(monitor.diagnosticReport())
            monitor.stop()
            exit(0)
        }
    }

    /// `--demo NAME`: shows break screens on the real windows with sample data instead of starting
    /// the app (no socket, no menu-bar item, nothing recorded); quits when the scenario is over.
    private func runDemo(_ name: String, options: LaunchOptions) {
        if name == "list" {
            for entry in BreakDemo.catalogue { print("\(entry.name)\t\(entry.summary)") }
            exit(0)
        }
        let demo = BreakDemo(soundVolume: options.demoVolume ?? 0.5) { NSApp.terminate(nil) }
        self.demo = demo
        guard demo.run(name, maxDuration: options.quitAfter ?? 150) else {
            FileHandle.standardError.write(Data("unknown demo \(name); try --demo list\n".utf8))
            exit(2)
        }
    }
}

/// Launch arguments (SPEC §7.3).
struct LaunchOptions {
    /// `--debug-stall-main N`: block the main thread for N seconds during the next overlay.
    var debugStallMain: TimeInterval?
    /// `--show-onboarding`: show onboarding even if it was completed (development).
    var forceOnboarding = false
    /// `--tour`: start the one-minute tour after launch, as Settings → General would (SPEC §3.12).
    var startTour = false
    /// `--quit-after N`: quit normally after N seconds (smoke tests of launch and quit).
    var quitAfter: TimeInterval?
    /// `--demo NAME`: play a break-screen scenario instead of running the app (`--demo list`).
    var demo: String?
    /// `--demo-volume V`: chime volume in the demo, 0…1 (0 mutes it).
    var demoVolume: Double?
    /// `--signals`: print the activity monitor's diagnostic report and exit.
    var printSignals = false
    /// Debug-build-only options for the end-to-end harness (always off in release builds).
    var debug = DebugOptions()

    init(arguments: [String]) {
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
struct DebugOptions {
    var headless = false
    var simulate = false
    var trace = false
    var timers: (screen: TimeInterval, still: TimeInterval)?

    init() {}

    init(arguments: [String]) {
        headless = arguments.contains("--debug-headless")
        simulate = arguments.contains("--debug-simulate")
        trace = arguments.contains("--debug-trace")
        if let i = arguments.firstIndex(of: "--debug-timers"), i + 1 < arguments.count {
            let parts = arguments[i + 1].split(separator: ",").compactMap { TimeInterval($0) }
            if parts.count == 2 { timers = (parts[0], parts[1]) }
        }
    }
}
