import Foundation

/// Every behavioural time constant in SPEC §2–3, in seconds, in one place. Fixed values, not
/// settings (settings live in `Settings`). Tests and policies reference these names.
public enum Timing {
    // §2.4 Typing guard
    /// Input is busy when a key was pressed less than this long ago.
    public static let typingGuardKey: TimeInterval = 2
    /// Input is busy when a drag or click happened less than this long ago.
    public static let typingGuardDrag: TimeInterval = 1

    // §2.5 Opportunities
    /// An opportunity expires this long after creation.
    public static let opportunityLifetime: TimeInterval = 30
    /// A shell command becomes a `longCommand` opportunity after running this long.
    public static let longCommandDelay: TimeInterval = 20
    /// `typingPause`: no key press for at least this long.
    public static let typingPauseQuiet: TimeInterval = 8
    /// `typingPause`: a timer must be at least this multiple of its cadence.
    public static let typingPauseCadenceFactor: Double = 1.5

    // §2.4 Call pause
    /// A microphone counts as a call only once it has been on this long without a break.
    /// Dictating a prompt keeps it on for seconds, a call for many minutes. Shorter use only holds
    /// offers while it lasts: no pause, no toast, no cool-down. The camera counts at once.
    public static let microphoneCallAfter: TimeInterval = 60

    // §2.4 Cool-downs
    /// No nudge for this long after a pause ends, after returning from away, or after unlock/wake.
    public static let resumeCooldown: TimeInterval = 60
    /// No nudge within this long of the previous nudge or the end of any break.
    public static let nudgeSpacing: TimeInterval = 10 * 60
    /// A kind declined or ignored is not offered again for this long.
    public static let kindSpacing: TimeInterval = 10 * 60
    /// `breathe` replaces `move` after this many refusals in a row of the still-time slot.
    public static let moveRefusalsBeforeBreathe = 2
    /// From this many refusals in a row of a slot, each one spaces that slot for its whole cadence
    /// instead of `kindSpacing` (until a break of that slot is taken or away time resets its timer).
    public static let refusalsBeforeCadenceSpacing = 3

    // §2.3 Away and Undo
    /// An `AutoDecision` can be undone for this long.
    public static let undoWindow: TimeInterval = 10 * 60

    // §2.6 Sessions
    /// A working Claude Code session with no event for this long becomes idle (run discarded).
    public static let staleHeartbeatSource: TimeInterval = 10 * 60
    /// A working session of any other source with no event for this long becomes idle.
    public static let staleOtherSource: TimeInterval = 60 * 60
    /// Sessions with no event for this long are removed.
    public static let sessionExpiry: TimeInterval = 2 * 60 * 60
    /// Commands with no `commandFinished` after this long are removed.
    public static let commandExpiry: TimeInterval = 60 * 60
    /// The run-length estimator keeps this many runs per source.
    public static let runHistoryLength = 20
    /// Expected run length before any run was recorded.
    public static let defaultExpectedRun: TimeInterval = 90

    // §3.1 Nudge
    /// A nudge with no interaction is ignored after this long.
    public static let nudgeIgnoreAfter: TimeInterval = 10
    /// After hover ends, the nudge timer restarts at this (half its full time).
    public static let nudgeIgnoreAfterHover: TimeInterval = 5
    /// Eye-rest auto-start: the card counts down from this.
    public static let autoStartCountdown: TimeInterval = 10
    /// Eye-rest auto-start: the countdown chip takes over with this much remaining.
    public static let autoStartChipAt: TimeInterval = 5

    // §3.3 Overlay
    /// Skip is disabled for this long after a break starts.
    public static let skipGuard: TimeInterval = 3
    /// Two Esc presses within this interval skip the break.
    public static let doubleEscInterval: TimeInterval = 1.2
    /// Skip becomes Done (records `completed`) once this fraction of the planned length elapsed.
    public static let doneFraction: Double = 0.8
    /// "1 more minute" adds this much.
    public static let extensionLength: TimeInterval = 60
    /// "1 more minute" can be used at most this many times per break.
    public static let maxExtensions = 2
    /// A completed break (not skipped) holds its closing moment this long before the exit: the
    /// ring closes into a check and the title becomes the closing line.
    public static let completionMoment: TimeInterval = 1.2

    // §2.2 Routines
    /// Every routine lasts exactly this long (band routines included).
    public static let routineLength: TimeInterval = 120
    /// The shortest a routine step may be.
    public static let routineStepShortest: TimeInterval = 10
    /// The longest a routine step may be.
    public static let routineStepLongest: TimeInterval = 120
    /// Hard ceiling: planned length + extensions + this.
    public static let overlayCeilingSlack: TimeInterval = 60
    /// Hard ceiling for `walk`.
    public static let walkCeiling: TimeInterval = 30 * 60
    /// `walk` goes ambient after this long with no input.
    public static let walkAmbientAfter: TimeInterval = 30
    /// `walk`: input after at least this long idle wakes the overlay with "Welcome back".
    public static let walkWelcomeBackAfter: TimeInterval = 60
    /// Previews (Settings) last this long or until Esc.
    public static let previewLength: TimeInterval = 5

    // §3.5 Cards
    /// Resume card and away note auto-hide after this long (needs-you cards stay).
    public static let cardAutoHide: TimeInterval = 10
    /// Toasts auto-hide after this long.
    public static let toastAutoHide: TimeInterval = 3
    /// When the pointer leaves a hovered card, its countdown resumes with whatever it had left, but
    /// never less than this fraction of its full time (hover never shortens a card's stay).
    public static let cardHoverResumeFloor: Double = 0.5

    // §2.8 Wind-down
    /// Hold durations for successive "15 more minutes" choices in one night.
    public static let windDownHolds: [TimeInterval] = [3, 6, 10]
    /// Each "15 more minutes" adds this much.
    public static let windDownExtension: TimeInterval = 15 * 60

    /// The day boundary hour: a Breakpoint day runs 05:00 to 05:00 (SPEC §2.7).
    public static let dayBoundaryHour = 5

    // §5.8 Terminal
    /// `breakpoint status --line` waits at most this long for the app's answer (a prompt or an
    /// agent's status bar runs it on every draw), then prints nothing.
    public static let statusLineTimeout: TimeInterval = 0.25

    // §2.11 Update check
    /// Automatic checks happen at most this often.
    public static let updateCheckInterval: TimeInterval = 24 * 60 * 60
    /// After a check that could not reach the feed, the next try waits this long instead.
    public static let updateRetryAfterFailure: TimeInterval = 3 * 60 * 60
    /// No automatic check in the first minutes after launch (a login, a wake).
    public static let updateFirstCheckDelay: TimeInterval = 2 * 60
    /// "Later" (or a prompt left to hide itself) puts off asking about that version for this long.
    public static let updatePostpone: TimeInterval = 3 * 24 * 60 * 60
    /// The update prompt hides itself after this long (hover holds it).
    public static let updateCardAutoHide: TimeInterval = 20
    /// The prompt waits until no key was pressed for this long.
    public static let updatePromptQuiet: TimeInterval = 30
    /// Give up on a check after this long.
    public static let updateRequestTimeout: TimeInterval = 15
    /// Give up on downloading an update archive after this long.
    public static let updateDownloadTimeout: TimeInterval = 5 * 60
    /// After an in-place update the new copy must confirm it started within this long, or the
    /// old copy is put back.
    public static let updateConfirmTimeout: TimeInterval = 30
    /// How long the relaunch helper waits for the old copy to quit.
    public static let updateOldCopyExitTimeout: TimeInterval = 15

    // §5.6 Install check
    /// After Install, the hook command the app runs must reach it within this long (a freshly
    /// copied binary's first run can take a few seconds while macOS checks it).
    public static let installCheckTimeout: TimeInterval = 10

    // §3.12 The one-minute tour
    /// The sample break: a shortened eye rest, long enough to read its two coach lines and see the
    /// agent chip turn, short enough to stay a rehearsal.
    public static let tourBreakLength: TimeInterval = 15
    /// The sample agent finishes this far into the sample break (the chip turns mint).
    public static let tourAgentFinishesAfter: TimeInterval = 6
}
