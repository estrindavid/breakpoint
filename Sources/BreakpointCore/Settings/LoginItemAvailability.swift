import Foundation

/// Whether this run of Breakpoint may register itself as a login item (SPEC §3.9 General, §3.10
/// Done). Pure: decided from where the app runs and its environment, so it can be tested.
///
/// A login item points at the app where it is now. Registered from Downloads, a disk image, a
/// copy macOS translocated or a build folder, it points at an app that moves or is deleted; so
/// Breakpoint registers only from an Applications folder (`/Applications`, `~/Applications`, or a
/// folder inside either), where the installer puts it.
public enum LoginItemAvailability: Equatable, Sendable {
    /// Running from an app bundle in an Applications folder.
    case available
    /// `BREAKPOINT_HOME` is set: a development run that must never change the real login items.
    case developmentRun
    /// An app bundle outside every Applications folder.
    case outsideApplications
    /// Not an app bundle at all (`swift run`, a bare executable).
    case notFromApp

    public static func evaluate(bundlePath: String, isAppBundle: Bool,
                                environment: [String: String]) -> LoginItemAvailability {
        if environment[BreakpointPaths.homeOverrideVariable] != nil { return .developmentRun }
        guard isAppBundle else { return .notFromApp }
        return isInApplicationsFolder(bundlePath) ? .available : .outsideApplications
    }

    /// True when some folder above the bundle is named Applications.
    public static func isInApplicationsFolder(_ bundlePath: String) -> Bool {
        URL(fileURLWithPath: bundlePath).standardizedFileURL.pathComponents.dropLast().contains("Applications")
    }

    /// Registering is allowed only from an Applications folder.
    public var allowsRegistering: Bool { self == .available }

    /// Removing a registration is always safe from a real app (it may point at an older copy);
    /// development runs leave the login items alone.
    public var allowsUnregistering: Bool { self == .available || self == .outsideApplications }

    /// "Open at login" starts off on a first launch that cannot register it. Development runs keep
    /// the setting as it is (they never register anything anyway).
    public var defaultsToOff: Bool { self == .outsideApplications || self == .notFromApp }
}
