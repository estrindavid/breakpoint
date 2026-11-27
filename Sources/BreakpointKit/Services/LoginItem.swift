import Foundation
import ServiceManagement
import BreakpointCore

/// "Open at login" (SPEC §3.9 General, §3.10 Done) via `SMAppService.mainApp`.
///
/// Contract: `isEnabled` reads the service status; `setEnabled` registers or unregisters and
/// throws on failure (the settings row then shows the error in its description). Registers only
/// from an app bundle in an Applications folder (`LoginItemAvailability`); a no-op otherwise.
@MainActor
public protocol LoginItemControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// The login item's real state, for the General pane's description.
public enum LoginItemStatus: Equatable, Sendable {
    /// Registered and allowed: Breakpoint opens at login.
    case enabled
    /// Not registered.
    case off
    /// Registered, but the user turned it off in System Settings → General → Login Items.
    case requiresApproval
    /// Not available: not running from an app bundle in an Applications folder, or a development
    /// run with a temporary home (`BREAKPOINT_HOME`), which must never change the real login items.
    case unavailable(reason: String)
}

/// `SMAppService.mainApp` behind `LoginItemControlling`. Reading the status never prompts.
@MainActor
public final class LoginItem: LoginItemControlling {
    public init() {}

    /// The current state, read from the system each time.
    public static var status: LoginItemStatus {
        if let reason = unavailableReason() { return .unavailable(reason: reason) }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    public var isEnabled: Bool { Self.status == .enabled }

    public func setEnabled(_ enabled: Bool) throws {
        let availability = Self.availability()
        let service = SMAppService.mainApp
        if enabled {
            // Never from outside an Applications folder: the item would point at a copy that
            // moves or is deleted.
            guard availability.allowsRegistering, service.status != .enabled else { return }
            try service.register()
        } else {
            // Still allowed from outside one, so an item left by an older copy can be turned off.
            guard availability.allowsUnregistering,
                  service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }

    /// Opens System Settings → General → Login Items (for `.requiresApproval`).
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The General pane's note when the login item is unavailable (it follows "Breakpoint starts
    /// quietly in the menu bar.").
    public static let developmentRunNote = "Development runs leave your login items alone."
    public static let notFromAppNote = "This works once Breakpoint runs from its app."
    public static let outsideApplicationsNote = "This works once Breakpoint is in your Applications folder."

    /// Where this run stands (SPEC §3.9 General, §3.10 Done).
    public static func availability(bundle: Bundle = .main,
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> LoginItemAvailability {
        LoginItemAvailability.evaluate(bundlePath: bundle.bundleURL.path,
                                       isAppBundle: bundle.bundleURL.pathExtension == "app" && bundle.bundleIdentifier != nil,
                                       environment: environment)
    }

    /// Why the login item cannot be used in this run, or `nil` when it can.
    static func unavailableReason(bundle: Bundle = .main,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        switch availability(bundle: bundle, environment: environment) {
        case .available: return nil
        case .developmentRun: return developmentRunNote
        case .outsideApplications: return outsideApplicationsNote
        case .notFromApp: return notFromAppNote
        }
    }
}
