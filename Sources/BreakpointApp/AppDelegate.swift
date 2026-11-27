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
        let coordinator = AppCoordinator(paths: .live(), options: options, platform: MacPlatform())
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

// `LaunchOptions` and `DebugOptions` are shared with the Windows app (BreakpointRuntime,
// Platform/AppPlatform.swift).
