import AppKit
import BreakpointCore
import BreakpointRuntime

/// Restores the previously frontmost app after a break (SPEC §7.2).
///
/// Contract: `recordFrontmost()` stores `NSWorkspace.shared.frontmostApplication` when a break
/// starts (or, when that is Breakpoint itself because the break started from the popover or the
/// menu, the last other app that was active). `restore()` on close: if Breakpoint is frontmost, reactivates the recorded app (unless it
/// quit); never acts if the user switched to another app during the break.
///
/// The overlay is a non-activating panel, so normally Breakpoint never becomes frontmost and there
/// is nothing to restore: the recorded app's window simply gets its key status back when the panel
/// closes. `restore()` matters when something did activate Breakpoint during the break (for
/// example the user clicked its menu-bar item).
@MainActor
public final class FocusRestorer {
    private var recorded: NSRunningApplication?
    private var userSwitched = false
    private var observer: NSObjectProtocol?
    /// The last app other than Breakpoint to become active. A break started from the popover or
    /// the menu begins while Breakpoint itself is frontmost; this is the app to give focus back to.
    private var lastOtherApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    public init() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID { lastOtherApp = front }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, app.processIdentifier != ownPID else { return }
                self?.lastOtherApp = app
            }
        }
    }

    public func recordFrontmost() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == ownPID {
            recorded = lastOtherApp.flatMap { $0.isTerminated ? nil : $0 }
        } else {
            recorded = front
        }
        userSwitched = false
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app else { return }
                // Activating Breakpoint itself, or the recorded app again, is not a switch.
                if app.processIdentifier == ownPID || app.processIdentifier == self.recorded?.processIdentifier { return }
                self.userSwitched = true
            }
        }
    }

    public func restore() {
        defer { reset() }
        guard let app = recorded, !userSwitched, !app.isTerminated else { return }
        guard NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            return
        }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    private func reset() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        recorded = nil
        userSwitched = false
    }
}
