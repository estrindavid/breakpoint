import AppKit

// The menu-bar app's entry point. The bundle's Info.plist sets LSUIElement, and
// the activation policy is set to `.accessory` here as well, so there is never a Dock icon.

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
