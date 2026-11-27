import Foundation

/// The seam between `AppCoordinator` and every window or panel controller.
///
/// Controllers are created once by the coordinator with the shared `AppState` and `AppActions`.
/// After any change to `AppState`, the coordinator calls `sync()` on every controller (coalesced to
/// once per run-loop turn). A controller reads only its slice of the state and shows, updates or
/// hides its windows to match. It never mutates `AppState`; user intents go through `AppActions`.
@MainActor
public protocol SurfaceController: AnyObject {
    /// Reconcile windows with the current `AppState`. Idempotent and cheap when nothing changed.
    func sync()
    /// Close every window immediately, without animation (quit, watchdog, tests).
    func tearDown()
}
