import BreakpointCore
import BreakpointRuntime
import BreakpointWindows
import CBreakpointWin32
import Foundation
import WinSDK

// The Windows tray app's entry point (the release build names it Breakpoint.exe). One process, one
// UI thread: the Win32 message loop (`MessageLoop`) also runs DispatchQueue.main and Foundation's
// timers, so the shared coordinator runs exactly as on macOS.
//
// Launch arguments are macOS's (SPEC §7.3): --show-onboarding, --tour, --quit-after N,
// --debug-stall-main N, --signals, and in debug builds the end-to-end harness's --debug-* flags.
// Windows only: --write-icon FILE (packaging) and --debug-snapshots DIR (every surface as PNGs).

_ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
_ = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))
// Notification-area and taskbar grouping; the same ID the installer's shortcut carries.
_ = SetCurrentProcessExplicitAppUserModelID("com.breakpointapp.Breakpoint".wide)
PlatformLogSink.extra = { line in OutputDebugStringW(line.wide) }

let options = LaunchOptions(arguments: CommandLine.arguments)

let status: Int32 = MainActor.assumeIsolated {
    if options.printSignals {
        // `--signals`: the activity monitor's report (for `breakpoint doctor` when the app is not running).
        let monitor = WindowsActivityMonitor()
        monitor.start()
        let report = monitor.diagnosticReport()
        monitor.stop()
        Console.attachToParent()
        print(report)
        return 0
    }
    if let index = CommandLine.arguments.firstIndex(of: "--write-icon"), index + 1 < CommandLine.arguments.count {
        // Packaging (scripts/windows/package.ps1): the icon file, drawn by the same code as the app's.
        _ = bp_graphics_start()
        do {
            try AppIcon.writeICO(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return 0
        } catch {
            return 1
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--debug-snapshots"), index + 1 < CommandLine.arguments.count {
        // Every surface in every preview state, as PNGs (the Windows UI's review loop).
        _ = bp_graphics_start()
        Console.attachToParent()
        do {
            let count = try SnapshotCatalogue.writeAll(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            print("Wrote \(count) snapshots.")
            return 0
        } catch {
            print("Snapshots failed: \(error)")
            return 1
        }
    }
    if options.demo != nil {
        Console.attachToParent()
        print("The break demos (--demo) are only in the macOS app; scripts/windows/run.ps1 shows the real screens.")
        return 2
    }
    _ = bp_graphics_start()
    let platform = WindowsPlatform()
    let coordinator = AppCoordinator(paths: .live(), options: options, platform: platform)
    platform.willQuit = { [weak coordinator] in coordinator?.stop() }
    coordinator.start()
    let code = MessageLoop.run()
    platform.willQuit?()
    withExtendedLifetime(coordinator) {}
    return code
}
exit(status)
