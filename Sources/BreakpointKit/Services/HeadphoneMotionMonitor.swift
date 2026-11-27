import CoreMotion
import Foundation
import BreakpointCore

// The only API in the app that may show a permission prompt (Motion),
// and only after the user turns on "Check movement with AirPods" (SPEC §2.9).

/// Optional AirPods movement check during `move` and `walk` (SPEC §2.9).
///
/// Contract:
/// - `isAvailable`: `CMHeadphoneMotionManager.isDeviceMotionAvailable` and Motion access not
///   denied or restricted. Must not trigger the Motion prompt by itself.
/// - `prepare(enabled:)`: called by the coordinator every tick with the setting. When the setting
///   is switched on while the app runs and Motion access was never asked, it asks once (briefly
///   starting updates is the only way to show the system prompt). Never asks at launch, never asks
///   while the setting is off.
/// - `begin()`: starts head-motion updates; accumulates rotation activity in a `MovementDetector`
///   (Core; the threshold is documented there). Degrades silently when unavailable or denied,
///   or when no supported headphones are connected (no updates arrive).
/// - `end()`: stops updates and returns whether rotation activity crossed the threshold during
///   the break. No rep counting.
@MainActor
public protocol HeadphoneMotionMonitoring: AnyObject {
    var isAvailable: Bool { get }
    func prepare(enabled: Bool)
    func begin()
    func end() -> Bool
}

extension HeadphoneMotionMonitoring {
    public func prepare(enabled: Bool) {}
}

/// The live monitor, backed by `CMHeadphoneMotionManager` (macOS 14+).
@MainActor
public final class HeadphoneMotionMonitor: HeadphoneMotionMonitoring {
    private lazy var manager = CMHeadphoneMotionManager()
    private var detector = MovementDetector()
    private var running = false
    /// The setting as last seen; `nil` before the first `prepare` (launch never prompts).
    private var lastEnabled: Bool?
    private var accessProbe: DispatchWorkItem?

    public init() {}

    /// Access was not refused. `authorizationStatus()` is a class method and never prompts.
    private var accessAllowed: Bool {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted: return false
        case .notDetermined, .authorized: return true
        @unknown default: return false
        }
    }

    /// The app's Info.plist explains Motion use; without it the system would refuse (or end the
    /// process) when updates start, so the check stays off instead.
    private var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil
    }

    public var isAvailable: Bool {
        hasUsageDescription && accessAllowed && manager.isDeviceMotionAvailable
    }

    public func prepare(enabled: Bool) {
        defer { lastEnabled = enabled }
        guard enabled, lastEnabled == false, !running, hasUsageDescription,
              CMHeadphoneMotionManager.authorizationStatus() == .notDetermined,
              manager.isDeviceMotionAvailable else { return }
        // Switched on just now and never asked: a short start shows the Motion prompt once.
        manager.startDeviceMotionUpdates(to: .main) { _, _ in }
        let probe = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.running else { return }
                self.manager.stopDeviceMotionUpdates()
            }
        }
        accessProbe?.cancel()
        accessProbe = probe
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: probe)
    }

    public func begin() {
        detector.reset()
        guard !running, isAvailable else { return }
        accessProbe?.cancel()
        running = true
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                guard let self, self.running, error == nil, let motion else { return }
                let rate = motion.rotationRate
                self.detector.add(x: rate.x, y: rate.y, z: rate.z, timestamp: motion.timestamp)
            }
        }
    }

    public func end() -> Bool {
        if running {
            manager.stopDeviceMotionUpdates()
            running = false
        }
        let detected = detector.detected
        detector.reset()
        return detected
    }
}
