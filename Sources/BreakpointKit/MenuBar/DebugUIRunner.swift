import AppKit
import BreakpointCore

// Development-only hooks; compiled out of release
// builds (scripts/build-app.sh builds release).

@MainActor
enum DebugUIRunner {
    /// Called when the status item is installed.
    static func statusItemInstalled(_ controller: StatusItemController) {
        #if DEBUG
        DebugUISelfTest.startIfRequested(statusItem: controller)
        #endif
    }
}

#if DEBUG
/// `BREAKPOINT_UI_SELFTEST=<dir>` (debug builds only, and only together with `BREAKPOINT_HOME`):
/// drives the real popover, settings window and onboarding with synthesised key events, logs what
/// happened, writes window images to `<dir>` (drawn from the app's own views; no screen capture),
/// then quits. Takes about 12 s.
@MainActor
enum DebugUISelfTest {
    private static var outDir: URL!
    private static var failures = 0

    static func startIfRequested(statusItem: StatusItemController) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["BREAKPOINT_UI_SELFTEST"], env[BreakpointPaths.homeOverrideVariable] != nil else { return }
        outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            await run(statusItem)
            log("DONE failures=\(failures)")
            NSApp.terminate(nil)
        }
    }

    private static func run(_ item: StatusItemController) async {
        await pause(1.2)
        log("status item frame: \(item.statusItemFrame.map { "\($0)" } ?? "hidden")")
        log("status item diagnostics: \(item.visibilityDiagnostics)")

        // Onboarding (first run in a temporary home).
        if let onboarding = OnboardingWindowController.current, let window = onboarding.onboardingWindow, window.isVisible {
            check(onboarding.step == .welcome, "onboarding starts at Welcome")
            snapshot(window, "onboarding-1")
            for expected in [OnboardingStep.howItWorks, .connect, .pace, .done] {
                send(key: 36, chars: "\r", to: window)
                await pause(0.5)
                check(onboarding.step == expected, "Return advances onboarding to \(expected)")
                snapshot(window, "onboarding-\(expected.rawValue + 1)")
            }
            send(key: 53, chars: "\u{1b}", to: window)
            await pause(0.4)
            check(onboarding.step == .pace, "Esc goes back to Pace")
            send(key: 124, chars: "\u{F703}", to: window)
            await pause(0.3)
            send(key: 36, chars: "\r", to: window)
            await pause(0.4)
            send(key: 36, chars: "\r", to: window)       // Done → finishes
            await pause(0.8)
            check(!window.isVisible, "Done closes onboarding")
            check(item.isPopoverShown, "finishing onboarding opens the popover once")
            item.closePopover()
            await pause(1.0)
        } else {
            log("onboarding not showing (already completed in this home)")
        }

        // Popover.
        item.showPopover()
        await pause(0.6)
        check(item.isPopoverShown, "popover opens")
        if let window = item.popoverWindow {
            snapshot(window, "popover")
            send(key: 124, chars: "\u{F703}", to: window, viaApp: true)
            await pause(0.2)
            check(item.popoverFocus != nil, "→ shows keyboard focus in the popover (\(item.popoverFocus.map { "\($0)" } ?? "none"))")
            send(key: 124, chars: "\u{F703}", to: window, viaApp: true)
            await pause(0.2)
            log("focus after second →: \(item.popoverFocus.map { "\($0)" } ?? "none")")
            snapshot(window, "popover-focus")
            send(key: 53, chars: "\u{1b}", to: window, viaApp: true)
            await pause(0.6)
            check(!item.isPopoverShown, "Esc closes the popover")
        }
        await pause(0.6)
        item.togglePopover()
        await pause(0.5)
        check(item.isPopoverShown, "toggle opens it again")
        item.togglePopover()
        await pause(0.8)
        check(!item.isPopoverShown, "toggle closes it")
        // It hangs still under the mark, and leaving the Space closes it (SPEC §3.8).
        item.showPopover()
        await pause(0.7)
        log("popover window \(item.popoverWindow.map { "\($0.frame)" } ?? "none") under the mark at \(item.statusItemFrame.map { "\($0)" } ?? "hidden")")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        await pause(0.8)
        check(!item.isPopoverShown, "a Space change closes it")

        // Settings.
        guard let settings = SettingsWindowController.current else { return check(false, "settings controller exists") }
        settings.show(pane: .breaks)
        await pause(0.8)
        guard let window = settings.settingsWindow else { return check(false, "settings window exists") }
        check(window.isVisible, "settings window opens")
        log("settings window frame: \(window.frame.size)")
        if let root = window.contentView {
            for scroll in SettingsWindowController.allViews(of: NSScrollView.self, in: root) {
                log("scroll view \(type(of: scroll)) frame \(scroll.frame) doc \(scroll.documentView.map { "\(type(of: $0)) \($0.frame.size)" } ?? "nil")")
            }
            for table in SettingsWindowController.allViews(of: NSTableView.self, in: root) {
                log("table \(type(of: table)) rows \(table.numberOfRows) selected \(table.selectedRow)")
            }
        }
        for (index, pane) in SettingsPane.allCases.enumerated() {
            send(key: UInt16([18, 19, 20, 21, 23, 22, 26, 28][index]), chars: "\(index + 1)", modifiers: .command, to: window)
            await pause(0.35)
            check(settings.pane == pane, "⌘\(index + 1) selects \(pane.title)")
            let before = settings.contentScrollView?.contentView.bounds.origin.y ?? -1
            send(key: 121, chars: "\u{F72D}", to: window)          // Page Down
            await pause(0.5)
            let after = settings.contentScrollView?.contentView.bounds.origin.y ?? -1
            let height = settings.contentScrollView?.documentView?.frame.height ?? 0
            let visible = settings.contentScrollView?.contentView.bounds.height ?? 0
            log("\(pane.title): content \(Int(height)) pt in \(Int(visible)) pt, Page Down \(Int(before)) → \(Int(after))")
            if height > visible + 1 { check(after != before, "Page Down scrolls \(pane.title)") }
            snapshot(window, "settings-\(pane.rawValue)")
            send(key: 115, chars: "\u{F729}", to: window)          // Home
            await pause(0.15)
        }
        // Sidebar arrows (native table).
        settings.select(.breaks)
        await pause(0.3)
        if let table = SettingsWindowController.firstView(of: NSTableView.self, in: window.contentView) {
            window.makeFirstResponder(table)
            send(key: 125, chars: "\u{F701}", to: window)
            await pause(0.3)
            check(settings.pane == .routine, "↓ in the sidebar moves to Routine (now \(settings.pane.title))")
        }
        send(key: 13, chars: "w", modifiers: .command, to: window)
        await pause(0.4)
        check(!window.isVisible, "⌘W closes settings")
    }

    // MARK: Helpers

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func check(_ condition: Bool, _ what: String) {
        if !condition { failures += 1 }
        log("\(condition ? "PASS" : "FAIL") \(what)")
    }

    private static func log(_ line: String) {
        print("[ui-selftest] \(line)")
        fflush(stdout)
    }

    private static func send(key: UInt16, chars: String, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow,
                             viaApp: Bool = false) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: key) else { return }
        if viaApp {
            NSApp.sendEvent(event)
        } else if !modifiers.isEmpty {
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        } else {
            window.sendEvent(event)
        }
    }

    private static func snapshot(_ window: NSWindow, _ name: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        var image = rep.cgImage
        // Layer-backed SwiftUI content can come back empty from cacheDisplay; render the layer.
        if let cg = image, isBlank(cg), let layer = view.layer {
            let scale = window.backingScaleFactor
            let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
            if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                image = ctx.makeImage()
            }
        }
        guard let cg = image, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    private static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        var i = 0
        while i < length { if bytes[i] != 0 { return false }; i += 97 }
        return true
    }
}
#endif
