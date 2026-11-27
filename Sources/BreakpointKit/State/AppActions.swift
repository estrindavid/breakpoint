import Foundation
import BreakpointCore

/// Sounds the app can preview (Settings → General ▶).
public enum SoundID: String, Sendable, CaseIterable {
    /// Two-partial chime when an agent needs you during a break (SPEC §4.7).
    case needsYouChime
    /// Chime when a break ends (off by default).
    case breakEndChime
    /// Soft tick at each step change of a stretch (on by default, quieter than the chimes).
    case stepTick
}

/// Every user intent a view can express (SPEC §7.2), as closures implemented by `AppCoordinator`.
/// Views call these and never mutate `AppState`. All closures are called on the main thread.
///
/// The first block is SPEC §7.2 one for one; the second block lists the additions
/// the screens need (documented in docs/INTERFACES.md).
@MainActor
public struct AppActions {
    // MARK: SPEC §7.2

    /// Start on the nudge (or ⌃⌥⌘B): starts the offered break.
    public var acceptNudge: () -> Void
    /// Not now (or ⌃⌥⌘.): records `declined`, kind spacing.
    public var declineNudge: () -> Void
    /// Take a break ▸ kind (popover, status-item menu): starts the overlay directly (`manual`).
    public var startBreak: (BreakKind) -> Void
    /// Skip (after the guard) or Esc twice: ends the break, which still counts (`endedEarly`, or
    /// `completed` past 80%; SPEC §2.7).
    public var skipBreak: () -> Void
    /// Done / I'm back / Welcome back / Back to work.
    public var finishBreak: (BreakFinishReason) -> Void
    /// 1 more minute (move, breathe; at most twice).
    public var extendBreak: () -> Void
    /// → / ← on `move`: +1 next step, −1 previous step.
    public var stepRoutine: (Int) -> Void
    /// Undo on the away note or the popover decision line.
    public var undoLastDecision: () -> Void
    /// Pause ▸ 30 min / 1 h / until tomorrow.
    public var pause: (PauseDuration) -> Void
    /// Resume now (popover) / Resume (call-pause toast).
    public var resume: () -> Void
    /// Close a card (× button, click on a resume card, Done on the wrap-up note).
    public var dismissCard: (UUID) -> Void
    /// "15 more minutes" after the hold completed.
    public var windDownExtend: () -> Void
    /// Wrap up: the card grows into "Where you left off"; pauses until 05:00.
    public var windDownWrapUp: () -> Void
    /// Copy note (⌘C) on the wrap-up note.
    public var copyWrapUpNote: () -> Void
    public var install: (IntegrationID) -> Void
    public var uninstall: (IntegrationID) -> Void
    /// Changes settings; the coordinator normalises, saves and applies them.
    public var updateSettings: ((inout Settings) -> Void) -> Void
    /// Preview nudge (Settings): the real nudge for 5 s; records nothing.
    public var previewNudge: (BreakKind) -> Void
    /// Preview break (Settings): the real overlay for 5 s or until Esc; records nothing.
    public var previewBreak: (BreakKind) -> Void
    public var openSettings: () -> Void
    public var quit: () -> Void

    // MARK: Additions (see docs/INTERFACES.md)

    /// The nudge timed out (10 s without interaction, hover pauses) or the countdown chip was
    /// cancelled by input: records `ignored`, kind spacing. Called by the nudge controller.
    public var ignoreNudge: () -> Void
    /// Hovering the card or pressing Not now during eye-rest auto-start (step 1) reverts it to a
    /// normal offer; during the chip (step 2) it records `ignored`. Key presses and clicks are
    /// detected by the coordinator itself.
    public var cancelAutoStart: () -> Void
    /// Settings → Privacy → Export history (the coordinator shows the save panel).
    public var exportHistory: () -> Void
    /// Settings → Privacy → Delete all data (the coordinator confirms first).
    public var deleteAllData: () -> Void
    /// ▶ on a sound row: plays at the current volume (silent while a call signal is active).
    public var previewSound: (SoundID) -> Void
    /// Onboarding finished or closed: marks it done, registers the login item if on, opens the
    /// popover once.
    public var completeOnboarding: () -> Void
    /// Settings → About → Check now: asks the feed at once, whatever the moment (SPEC §2.11).
    public var checkForUpdates: () -> Void
    /// Open download page (the update prompt when this copy cannot install, a failed install,
    /// Settings → About): opens the release page and closes the prompt. "Later" is `dismissCard`.
    public var openUpdate: () -> Void
    /// Update: download, verify, replace and reopen (SPEC §2.11).
    public var installUpdate: () -> Void
    /// Settings → General → Take the tour: the one-minute tour from its first step (SPEC §3.12).
    public var replayTour: () -> Void
    /// What the user did on a coach line or a tour surface: Next, Skip tour, the popover closing.
    /// Start, Not now, Skip and dismissing the sample card arrive through their usual actions.
    public var tour: (TourInput) -> Void
    /// The popover opened (true) or closed (false), however it was opened: its first-use hint,
    /// and the tour's popover step moving on when it closes (SPEC §3.12).
    public var popoverVisibilityChanged: (Bool) -> Void
    /// Something that may close the popover happened (a click outside it, Esc, another app, a
    /// Space or display change, the menu bar sliding away); the Bool says whether the pointer is on
    /// the popover. The coordinator asks `PopoverPolicy` and closes it if it should (SPEC §3.8).
    public var popoverMayClose: (PopoverCloseCause, Bool) -> Void

    public init(
        acceptNudge: @escaping () -> Void = {},
        declineNudge: @escaping () -> Void = {},
        startBreak: @escaping (BreakKind) -> Void = { _ in },
        skipBreak: @escaping () -> Void = {},
        finishBreak: @escaping (BreakFinishReason) -> Void = { _ in },
        extendBreak: @escaping () -> Void = {},
        stepRoutine: @escaping (Int) -> Void = { _ in },
        undoLastDecision: @escaping () -> Void = {},
        pause: @escaping (PauseDuration) -> Void = { _ in },
        resume: @escaping () -> Void = {},
        dismissCard: @escaping (UUID) -> Void = { _ in },
        windDownExtend: @escaping () -> Void = {},
        windDownWrapUp: @escaping () -> Void = {},
        copyWrapUpNote: @escaping () -> Void = {},
        install: @escaping (IntegrationID) -> Void = { _ in },
        uninstall: @escaping (IntegrationID) -> Void = { _ in },
        updateSettings: @escaping ((inout Settings) -> Void) -> Void = { _ in },
        previewNudge: @escaping (BreakKind) -> Void = { _ in },
        previewBreak: @escaping (BreakKind) -> Void = { _ in },
        openSettings: @escaping () -> Void = {},
        quit: @escaping () -> Void = {},
        ignoreNudge: @escaping () -> Void = {},
        cancelAutoStart: @escaping () -> Void = {},
        exportHistory: @escaping () -> Void = {},
        deleteAllData: @escaping () -> Void = {},
        previewSound: @escaping (SoundID) -> Void = { _ in },
        completeOnboarding: @escaping () -> Void = {},
        checkForUpdates: @escaping () -> Void = {},
        openUpdate: @escaping () -> Void = {},
        installUpdate: @escaping () -> Void = {},
        replayTour: @escaping () -> Void = {},
        tour: @escaping (TourInput) -> Void = { _ in },
        popoverVisibilityChanged: @escaping (Bool) -> Void = { _ in },
        popoverMayClose: @escaping (PopoverCloseCause, Bool) -> Void = { _, _ in }
    ) {
        self.acceptNudge = acceptNudge
        self.declineNudge = declineNudge
        self.startBreak = startBreak
        self.skipBreak = skipBreak
        self.finishBreak = finishBreak
        self.extendBreak = extendBreak
        self.stepRoutine = stepRoutine
        self.undoLastDecision = undoLastDecision
        self.pause = pause
        self.resume = resume
        self.dismissCard = dismissCard
        self.windDownExtend = windDownExtend
        self.windDownWrapUp = windDownWrapUp
        self.copyWrapUpNote = copyWrapUpNote
        self.install = install
        self.uninstall = uninstall
        self.updateSettings = updateSettings
        self.previewNudge = previewNudge
        self.previewBreak = previewBreak
        self.openSettings = openSettings
        self.quit = quit
        self.ignoreNudge = ignoreNudge
        self.cancelAutoStart = cancelAutoStart
        self.exportHistory = exportHistory
        self.deleteAllData = deleteAllData
        self.previewSound = previewSound
        self.completeOnboarding = completeOnboarding
        self.checkForUpdates = checkForUpdates
        self.openUpdate = openUpdate
        self.installUpdate = installUpdate
        self.replayTour = replayTour
        self.tour = tour
        self.popoverVisibilityChanged = popoverVisibilityChanged
        self.popoverMayClose = popoverMayClose
    }

    /// Does nothing: for previews and snapshots.
    public static var noop: AppActions { AppActions() }
}
