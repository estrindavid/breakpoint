import Foundation
import BreakpointCore

// The system services the coordinator uses, as protocols. Each app supplies its own
// implementations (macOS: BreakpointKit/Services and Break/SoundPlayer.swift; Windows:
// BreakpointWindows/Services); the debug harness supplies simulated ones (DebugHarness.swift).

/// The input and presence signals of SPEC §2.4.
///
/// Contract:
/// - `sample()` is cheap (called by the coordinator at 1 Hz, 10 Hz while a nudge or countdown is
///   visible) and returns timings only: `CGEventSource.secondsSinceLastEventType` for key-down
///   and any input, seconds since the last left-mouse down/drag and since the last scroll,
///   `NSEvent.pressedMouseButtons`, whether any `PreventUserIdleDisplaySleep` assertion is held
///   (`IOPMCopyAssertionsStatus`, count only) and whether any display is mirrored
///   (`CGDisplayIsInMirrorSet`).
/// - `callSignals`: the microphone signal comes from the shape and state of every audio device
///   (transport type, input and output streams, `kAudioDevicePropertyDeviceIsRunningSomewhere`,
///   nominal sample rate) through `MicrophoneUse` (Core); the camera signal is CoreMediaIO
///   `kCMIODevicePropertyDeviceIsRunningSomewhere` on every video device. Both are kept current with
///   property listeners; changes are reported through `onCallSignalsChange` on the main thread.
/// - Lock/unlock, display sleep/wake, system sleep/wake, screensaver start/stop and session
///   resign/activate are reported through `onPresenceEvent` on the main thread.
/// - `start()` installs listeners; `stop()` removes them. Both idempotent.
@MainActor
public protocol ActivityMonitoring: AnyObject {
    var onCallSignalsChange: ((CallSignals) -> Void)? { get set }
    var onPresenceEvent: ((PresenceEvent) -> Void)? { get set }
    /// The current call signals (unfiltered by settings).
    var callSignals: CallSignals { get }
    func sample() -> InputSample
    func start()
    func stop()
    /// Every signal the monitor reads, in plain text with no names (`breakpoint doctor`,
    /// `--signals`).
    func diagnosticReport() -> String
}

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

/// Synthesised sounds (SPEC §4.7): the chimes are two sine partials, ≥ 30 ms attack, ~1.5 s
/// exponential decay, no transient spike, ≤ −18 LUFS at full volume, via `AVAudioEngine`; the
/// step tick is a short, quieter cue of the same family.
///
/// Contract: `play` returns immediately; `volume` is 0…1 (`Settings.volume`). The coordinator never
/// calls it while a call signal is active. No bundled audio files.
@MainActor
public protocol SoundPlaying: AnyObject {
    func play(_ sound: SoundID, volume: Double)
}

/// "Open at login" (SPEC §3.9 General, §3.10 Done) via `SMAppService.mainApp`.
///
/// Contract: `isEnabled` reads the service status; `setEnabled` registers or unregisters and
/// throws on failure (the settings row then shows the error in its description). Registers only
/// from an app bundle in an Applications folder (`LoginItemAvailability`); a no-op otherwise.
@MainActor
public protocol LoginItemControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    /// Whether this copy may register itself (SPEC §3.10), and whether the first launch defaults
    /// "Open at login" to off because it cannot.
    func availability() -> LoginItemAvailability
}

/// Fetches the release feed (SPEC §2.11). The app's only network access lives here.
@MainActor
public protocol UpdateFetching: AnyObject {
    /// Calls `completion` on the main queue with the feed's bytes or an error.
    func fetch(_ completion: @escaping @MainActor (Result<Data, Error>) -> Void)
    /// Downloads an update archive into `folder` (a file only this user can read) and calls
    /// `completion` on the main queue with its location or an error.
    func download(_ url: URL, into folder: URL, _ completion: @escaping @MainActor (Result<URL, Error>) -> Void)
}
