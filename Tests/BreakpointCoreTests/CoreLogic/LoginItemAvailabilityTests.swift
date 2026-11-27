import Foundation
import Testing
@testable import BreakpointCore

/// Where a login item may be registered (SPEC §3.9 General, §3.10 Done).
@Suite("Login item placement")
struct LoginItemAvailabilityTests {
    let none: [String: String] = [:]

    @Test func onlyFromAnApplicationsFolder() {
        for path in ["/Applications/Breakpoint.app", "/Users/dev/Applications/Breakpoint.app",
                     "/Applications/Utilities/Breakpoint.app"] {
            let availability = LoginItemAvailability.evaluate(bundlePath: path, isAppBundle: true, environment: none)
            #expect(availability == .available, "\(path)")
            #expect(availability.allowsRegistering && availability.allowsUnregistering && !availability.defaultsToOff)
        }
    }

    @Test func notFromDownloadsADiskImageATranslocatedCopyOrABuildFolder() {
        for path in ["/Users/dev/Downloads/Breakpoint.app", "/Volumes/Breakpoint/Breakpoint.app",
                     "/private/var/folders/x/AppTranslocation/1234/d/Breakpoint.app",
                     "/Users/dev/Documents/breakpoint/build/Breakpoint.app",
                     "/Users/dev/Applications.old/Breakpoint.app"] {
            let availability = LoginItemAvailability.evaluate(bundlePath: path, isAppBundle: true, environment: none)
            #expect(availability == .outsideApplications, "\(path)")
            // An item left by an older copy can still be turned off from here.
            #expect(!availability.allowsRegistering && availability.allowsUnregistering && availability.defaultsToOff)
        }
    }

    @Test func notFromABareExecutable() {
        let bare = LoginItemAvailability.evaluate(bundlePath: "/Users/dev/breakpoint/.build/debug", isAppBundle: false,
                                                  environment: none)
        #expect(bare == .notFromApp)
        #expect(!bare.allowsRegistering && !bare.allowsUnregistering && bare.defaultsToOff)
    }

    @Test func developmentRunsLeaveLoginItemsAndTheSettingAlone() {
        let dev = LoginItemAvailability.evaluate(bundlePath: "/Applications/Breakpoint.app", isAppBundle: true,
                                                 environment: [BreakpointPaths.homeOverrideVariable: "/tmp/bp"])
        #expect(dev == .developmentRun)
        #expect(!dev.allowsRegistering && !dev.allowsUnregistering && !dev.defaultsToOff)
    }
}
