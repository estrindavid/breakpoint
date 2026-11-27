import Foundation
import BreakpointCore

// The value types inside `AppState`. Views read them; only the coordinator
// writes them. Every field is plain data so previews and snapshots can build any state.

// MARK: - Menu bar (SPEC §3.7)

/// The mark layer of the status item. Priority: on a break > paused > break due > idle.
public enum MenuBarMark: String, Sendable, CaseIterable {
    case idle, due, onBreak, paused

    /// The `BrandMark` variant that draws this state.
    public var variant: MarkVariant {
        switch self {
        case .idle: return .idle
        case .due: return .due
        case .onBreak: return .onBreak
        case .paused: return .paused
        }
    }
}

public struct MenuBarState: Equatable, Sendable {
    public var mark: MenuBarMark
    /// Agent working (dot) / needs you (ring) / none.
    public var badge: MarkBadge
    /// Text next to the icon per `Settings.menuBarText` ("6m", "due", "Claude 3m", "Paused");
    /// `nil` for none.
    public var text: String?
    /// One sentence with the cause, for the tooltip and accessibility label
    /// ("Paused: microphone is on", "Eye rest in 6 min").
    public var tooltip: String
    /// The latest one-shot movement of the mark (SPEC §3.7); the status item plays each `id` once.
    public var cue: MarkCueEvent?

    public init(mark: MenuBarMark = .idle, badge: MarkBadge = .none, text: String? = nil, tooltip: String = "Breakpoint",
                cue: MarkCueEvent? = nil) {
        self.mark = mark
        self.badge = badge
        self.text = text
        self.tooltip = tooltip
        self.cue = cue
    }
}

// MARK: - Status (SPEC §3.8 popover status block)

public struct StatusState: Equatable, Sendable {
    /// The kind of the next break ("Eye rest in" / "Stretch due").
    public var nextBreakKind: BreakKind
    /// Seconds until it is due; ≤ 0 means due now.
    public var nextBreakIn: TimeInterval
    public var timers: TimerState
    public var cadence: Cadence
    public var pause: PauseState
    /// "Paused: microphone is on" / "Paused until 15:30"; `nil` when not paused.
    public var pauseSentence: String?
    /// End of a manual or wrap-up pause ("until 15:30"); `nil` for calls.
    public var pausedUntil: Date?
    public var isAway: Bool
    /// What Breakpoint is waiting for ("Why not now?", SPEC §3.7, §3.8); `nil` before the first tick.
    public var whyNotNow: WaitReason?
    /// Still time has counted only since Breakpoint started (no break or time away reset it yet),
    /// so it says nothing about when the user last moved.
    public var stillCountedSinceLaunch: Bool

    public init(nextBreakKind: BreakKind = .eyes, nextBreakIn: TimeInterval = 20 * 60, timers: TimerState = .zero,
                cadence: Cadence = Settings.defaults.cadence, pause: PauseState = .none, pauseSentence: String? = nil,
                pausedUntil: Date? = nil, isAway: Bool = false, whyNotNow: WaitReason? = nil,
                stillCountedSinceLaunch: Bool = false) {
        self.nextBreakKind = nextBreakKind
        self.nextBreakIn = nextBreakIn
        self.timers = timers
        self.cadence = cadence
        self.pause = pause
        self.pauseSentence = pauseSentence
        self.pausedUntil = pausedUntil
        self.isAway = isAway
        self.whyNotNow = whyNotNow
        self.stillCountedSinceLaunch = stillCountedSinceLaunch
    }

    public var isDue: Bool { nextBreakIn <= 0 }
    public var isPaused: Bool { pause.isPaused }
    /// Still time as a fraction of the move cadence (the popover's 44 pt ring), 0…1.
    public var stillProgress: Double { min(1, timers.stillTime / max(1, cadence.moveEvery)) }
    /// Progress toward the break the caption names (the popover's ring), 0…1: screen time against
    /// the eye cadence for an eye rest, still time against the move cadence otherwise.
    public var nextBreakProgress: Double {
        nextBreakKind == .eyes ? min(1, timers.screenTime / max(1, cadence.eyesEvery)) : stillProgress
    }
}

// MARK: - Nudge (SPEC §3.1, §3.2)

public enum NudgePhase: String, Sendable {
    /// A normal offer (Start / Not now), ignored after 10 s.
    case offer
    /// Eye-rest auto-start, step 1: the card's title counts down from 10.
    case autoStartCard
    /// Eye-rest auto-start, step 2: the card is gone; the countdown chip follows the pointer.
    case countdownChip
}

public struct NudgeState: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var offer: BreakOffer
    public var phase: NudgePhase
    /// "2-min stretch?" or, during auto-start, "20-sec eye rest in 10".
    public var title: String
    /// "Claude is working".
    public var subtitle: String
    /// Hover line: "18 min overdue · Claude usually takes 4 min".
    public var whyNow: String
    /// Seconds left before the eye rest starts by itself; `nil` when not auto-starting.
    public var autoStartRemaining: TimeInterval?
    /// ⌃⌥⌘B / ⌃⌥⌘. are registered (their keycaps show in the buttons, brighter on hover).
    public var hotkeysEnabled: Bool
    /// A Settings preview: records nothing.
    public var isPreview: Bool
    /// The tour's sample nudge (SPEC §3.12): records nothing, never times out, carries a coach line.
    public var isRehearsal: Bool
    public var shownAt: Date
    /// The first-use hint under the buttons (SPEC §3.12): the first real nudge only.
    public var hint: String?

    public init(id: UUID = UUID(), offer: BreakOffer, phase: NudgePhase = .offer, title: String, subtitle: String,
                whyNow: String, autoStartRemaining: TimeInterval? = nil, hotkeysEnabled: Bool = true,
                isPreview: Bool = false, isRehearsal: Bool = false, shownAt: Date, hint: String? = nil) {
        self.id = id
        self.offer = offer
        self.phase = phase
        self.title = title
        self.subtitle = subtitle
        self.whyNow = whyNow
        self.autoStartRemaining = autoStartRemaining
        self.hotkeysEnabled = hotkeysEnabled
        self.isPreview = isPreview
        self.isRehearsal = isRehearsal
        self.shownAt = shownAt
        self.hint = hint
    }

    public var kind: BreakKind { offer.kind }
    /// Auto-start progress for the badge ring, 0…1 (`nil` when not auto-starting).
    public var autoStartProgress: Double? {
        autoStartRemaining.map { 1 - min(1, max(0, $0 / Timing.autoStartCountdown)) }
    }
}

// MARK: - Overlay (SPEC §3.3, §3.4)

/// The overlay's agent chip (SPEC §3.3 row 1).
public enum AgentChipState: Equatable, Sendable {
    /// No agent: time of day.
    case clock(Date)
    /// "Claude is still working · 1:42" (indigo, pulsing).
    case working(agent: String, elapsed: TimeInterval)
    /// "2 agents working".
    case severalWorking(Int)
    /// "Claude is done. No rush." (mint).
    case done(agent: String)
    /// "Claude needs you" (amber).
    case needsYou(agent: String)

    public var text: String {
        switch self {
        case .clock(let date): return TimeFormat.timeOfDay(date)
        case .working(let agent, let elapsed): return Copy.chipWorking(agent: agent, elapsed: elapsed)
        case .severalWorking(let count): return Copy.agentsWorking(count)
        case .done(let agent): return Copy.chipDone(agent: agent)
        case .needsYou(let agent): return Copy.needsYou(agent: agent)
        }
    }

    /// `nil` for the clock (no dot).
    public var tone: Tone? {
        switch self {
        case .clock: return nil
        case .working, .severalWorking: return .agent
        case .done: return .mint
        case .needsYou: return .needsYou
        }
    }

    public var isWorking: Bool {
        switch self {
        case .working, .severalWorking: return true
        default: return false
        }
    }
}

/// The `move` routine's current step, as the overlay shows it.
public struct RoutineStepState: Equatable, Sendable {
    public var index: Int
    public var count: Int
    public var step: RoutineStep
    /// Seconds left in this step (the ring's timer).
    public var remaining: TimeInterval

    public init(index: Int, count: Int, step: RoutineStep, remaining: TimeInterval) {
        self.index = index
        self.count = count
        self.step = step
        self.remaining = remaining
    }

    /// Fraction of the step elapsed, 0…1 (the 140 pt ring of a step without a tempo).
    public var progress: Double { step.duration > 0 ? min(1, max(0, 1 - remaining / step.duration)) : 1 }
    /// Seconds since the step started (as of the last tick).
    public var elapsed: TimeInterval { max(0, step.duration - remaining) }
}

/// The closing moment of a completed break (SPEC §3.3 Ending): the ring closes into a mint check
/// and the title becomes `line` for `Timing.completionMoment`, then the normal exit.
public struct BreakCompletionState: Equatable, Sendable {
    /// "That's two minutes." / "Shoulders done."
    public var line: String
    /// Seconds after the break's start at which it completed (the moment's clock starts here).
    public var at: TimeInterval

    public init(line: String, at: TimeInterval) {
        self.line = line
        self.at = at
    }
}

public struct ActiveBreakState: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: BreakKind
    /// Overlay title (`move`: the step title).
    public var title: String
    /// Overlay instruction (`move`: the step instruction).
    public var instruction: String
    /// `move` only.
    public var step: RoutineStepState?
    /// A second line under the instruction (`walk`: an idea for the walk), shown as the kind line.
    public var detail: String?
    /// Set once the break completed: the closing moment is showing (the break itself is over).
    public var completion: BreakCompletionState?
    public var startedAt: Date
    /// Seconds since the break started (as of the last tick).
    public var elapsed: TimeInterval
    /// Planned length including extensions (walk: the target).
    public var plannedLength: TimeInterval
    public var extensionsUsed: Int
    /// "1 more minute" is offered (move / breathe, fewer than 2 used).
    public var canExtend: Bool
    /// Elapsed time at which Skip enables (3 s).
    public var skipEnabledAt: TimeInterval
    /// Skip reads "Done" (≥ 80% elapsed; never on walk).
    public var doneAvailable: Bool
    public var agentChip: AgentChipState
    /// An agent needs the user: chip amber, primary "Back to work".
    public var needsYou: Bool
    /// `walk` ambient mode (scrim 85%, controls hidden until the pointer moves).
    public var ambient: Bool
    /// `walk`: input returned after ≥ 60 s idle; the primary reads "Welcome back".
    public var welcomeBack: Bool
    /// Show the full break on every display (setting).
    public var fullOnAllDisplays: Bool
    /// A Settings preview: records nothing, ends after 5 s or Esc.
    public var isPreview: Bool
    /// The tour's sample break (SPEC §3.12): records nothing; the screen carries coach lines and
    /// says it is a rehearsal.
    public var isRehearsal: Bool
    /// The first-use hint under the agent chip (SPEC §3.12): the first real break only.
    public var hint: String?

    public init(id: UUID = UUID(), kind: BreakKind, title: String, instruction: String, step: RoutineStepState? = nil,
                detail: String? = nil, completion: BreakCompletionState? = nil, startedAt: Date,
                elapsed: TimeInterval, plannedLength: TimeInterval, extensionsUsed: Int = 0,
                canExtend: Bool = false, skipEnabledAt: TimeInterval = Timing.skipGuard, doneAvailable: Bool = false,
                agentChip: AgentChipState, needsYou: Bool = false, ambient: Bool = false, welcomeBack: Bool = false,
                fullOnAllDisplays: Bool = false, isPreview: Bool = false, isRehearsal: Bool = false,
                hint: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.instruction = instruction
        self.step = step
        self.detail = detail
        self.completion = completion
        self.startedAt = startedAt
        self.elapsed = elapsed
        self.plannedLength = plannedLength
        self.extensionsUsed = extensionsUsed
        self.canExtend = canExtend
        self.skipEnabledAt = skipEnabledAt
        self.doneAvailable = doneAvailable
        self.agentChip = agentChip
        self.needsYou = needsYou
        self.ambient = ambient
        self.welcomeBack = welcomeBack
        self.fullOnAllDisplays = fullOnAllDisplays
        self.isPreview = isPreview
        self.isRehearsal = isRehearsal
        self.hint = hint
    }

    /// Seconds left (0 when over; walk: to the target).
    public var remaining: TimeInterval { max(0, plannedLength - elapsed) }
    /// 0…1 of the planned length.
    public var progress: Double { plannedLength > 0 ? min(1, elapsed / plannedLength) : 1 }
    public var skipEnabled: Bool { elapsed >= skipEnabledAt }
}

// MARK: - Cards (SPEC §3.0 priority, §3.5, §3.6)

/// Pop-up priority when a third pop-up arrives (lowest is removed), SPEC §3.0:
/// needs-you resume card > wind-down > other resume cards and away note > toasts > nudge.
public enum PopupPriority: Int, Comparable, Sendable {
    case nudge = 0
    case toast = 1
    case resumeOrAwayNote = 2
    case windDown = 3
    case needsYouResume = 4

    public static func < (lhs: PopupPriority, rhs: PopupPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One row of a resume card: a session, or a long shell command (source `shell`, the shell's PID
/// as session id). What it says comes from `ResumeFacts` (Core), so the wording is tested there.
public struct ResumeItem: Equatable, Sendable, Identifiable {
    public var id: SessionKey
    public var facts: ResumeFacts

    public init(id: SessionKey, facts: ResumeFacts) {
        self.id = id
        self.facts = facts
    }

    /// "Claude finished · ran 6 min" / "Claude hit the usage limit" / "Claude needs you" /
    /// "swift failed after 4 min".
    public var title: String { facts.headline }
}

public struct ResumeCardContent: Equatable, Sendable {
    /// At least one item, needs-you first; the card shows up to 3 rows when there are several.
    public var items: [ResumeItem]

    /// The first-use hint at the bottom (SPEC §3.12): the first real resume card only.
    public var hint: String?

    public init(items: [ResumeItem], hint: String? = nil) {
        self.items = items
        self.hint = hint
    }

    public var needsYou: Bool { items.contains { $0.facts.needsYou } }
    /// One item: its headline. Several: "3 agents finished", "Claude needs you", "3 runs finished".
    public var title: String {
        if items.count == 1 { return items[0].title }
        return Copy.resumeSeveralTitle(items.map(\.facts))
    }
    /// The supporting line of a one-row card (several rows show no extra line).
    public var detail: ResumeLine? { items.count == 1 ? items[0].facts.detail : nil }
}

public struct AwayNoteContent: Equatable, Sendable {
    public var decisionID: UUID
    /// The larger credited kind (badge).
    public var kind: BreakKind
    /// "Counted your 6 min away as a break".
    public var text: String

    public init(decisionID: UUID, kind: BreakKind, text: String) {
        self.decisionID = decisionID
        self.kind = kind
        self.text = text
    }
}

public struct ToastContent: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// "Resume" on the call-pause toast → `AppActions.resume`.
        case resumeFromCall
    }

    public var text: String
    public var action: Action?
    /// The first-use hint under the text (SPEC §3.12): the first call pause only.
    public var hint: String?

    public init(text: String, action: Action? = nil, hint: String? = nil) {
        self.text = text
        self.action = action
        self.hint = hint
    }
}

public struct WindDownCardContent: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// "It's 23:20." with 15 more minutes / Wrap up.
        case asking
        /// "Where you left off": one line per open session.
        case note(lines: [String])
    }

    public var now: Date
    public var stopTime: TimeOfDay
    /// The hold "15 more minutes" needs now (3, 6 or 10 s).
    public var holdDuration: TimeInterval
    public var phase: Phase

    public init(now: Date, stopTime: TimeOfDay, holdDuration: TimeInterval, phase: Phase = .asking) {
        self.now = now
        self.stopTime = stopTime
        self.holdDuration = holdDuration
        self.phase = phase
    }
}

public enum CardContent: Equatable, Sendable {
    case resume(ResumeCardContent)
    case awayNote(AwayNoteContent)
    case toast(ToastContent)
    case windDown(WindDownCardContent)
    /// "Breakpoint 0.3.0 is ready" (SPEC §2.11).
    case update(UpdateCardContent)
}

/// A pop-up other than the nudge, as shown by `TransientPanelStack`.
public struct CardState: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var content: CardContent
    public var createdAt: Date
    /// The tour's sample card (SPEC §3.12): stays until the user moves on, carries a coach line.
    public var isRehearsal: Bool

    public init(id: UUID = UUID(), content: CardContent, createdAt: Date, isRehearsal: Bool = false) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.isRehearsal = isRehearsal
    }

    public var priority: PopupPriority {
        switch content {
        case .resume(let card): return card.needsYou ? .needsYouResume : .resumeOrAwayNote
        case .awayNote: return .resumeOrAwayNote
        case .toast: return .toast
        case .windDown: return .windDown
        // Shown only when nothing else is on screen; anything that arrives later outranks it.
        case .update: return .toast
        }
    }

    /// Seconds after which the card hides itself; `nil` = stays until dismissed
    /// (needs-you resume cards, wind-down).
    public var autoHideAfter: TimeInterval? {
        // The tour moves on when the user does, never under them.
        if isRehearsal { return nil }
        switch content {
        case .resume(let card): return card.needsYou ? nil : Timing.cardAutoHide
        case .awayNote: return Timing.cardAutoHide
        // A toast with a hint has a second line to read: it stays as long as a card.
        case .toast(let toast): return toast.hint == nil ? Timing.toastAutoHide : Timing.cardAutoHide
        case .windDown: return nil
        // An offer hides itself; progress and a failure stay until done or closed.
        case .update(let card): return card.stage == .offer ? Timing.updateCardAutoHide : nil
        }
    }
}

// MARK: - Integrations (SPEC §3.9 Integrations pane, §3.10 step 3)

public struct IntegrationRowState: Equatable, Sendable, Identifiable {
    public var id: IntegrationID
    public var status: IntegrationStatus
    /// Notes from the last install ("Open /hooks in Codex and trust the new entries.").
    public var notes: [String]
    /// The last install or uninstall failed: one sentence.
    public var errorMessage: String?
    /// An install (with its check, `InstallCheck`) or an uninstall is running.
    public var isBusy: Bool
    /// When the check after this run's Install passed: the ✓ plays its movement once (§3.10, §4.6).
    public var connectedAt: Date?
    /// What the installer found on disk. Tells the "problem" states apart: an outdated or edited
    /// install still has Breakpoint's entries (so it offers Remove as well as Install), an
    /// unreadable file does not.
    public var installState: IntegrationInstallState

    public init(id: IntegrationID, status: IntegrationStatus = .notInstalled, notes: [String] = [], errorMessage: String? = nil,
                isBusy: Bool = false, connectedAt: Date? = nil, installState: IntegrationInstallState? = nil) {
        self.id = id
        self.status = status
        self.notes = notes
        self.errorMessage = errorMessage
        self.isBusy = isBusy
        self.connectedAt = connectedAt
        self.installState = installState ?? Self.installState(for: status)
    }

    /// The install state a status implies, for previews that give only the status.
    static func installState(for status: IntegrationStatus) -> IntegrationInstallState {
        switch status {
        case .notFound: return .notFound
        case .notInstalled: return .notInstalled
        case .connected: return .installed
        case .problem(let reason): return .unreadable(reason: reason)
        }
    }

    /// Breakpoint's entries are in the tool's file (installed, outdated or edited): Remove applies.
    public var canRemove: Bool { installState.hasBreakpointEntries }

    public var displayName: String { id.displayName }
}

// MARK: - The one-minute tour (SPEC §3.12)

/// The tour as the screens show it: which step, its coach line, and its progress.
public struct TourPresentation: Equatable, Sendable {
    public var step: TourStep
    /// The part of the popover being named (`popover` step).
    public var popoverPart: TourPopoverPart
    public var coach: TourCoach
    /// The sample agent's name ("Claude").
    public var agent: String
    /// ⌃⌥⌘B / ⌃⌥⌘. work on the coach cards (the nudge hotkeys setting).
    public var hotkeysEnabled: Bool

    public init(step: TourStep, popoverPart: TourPopoverPart = .status, coach: TourCoach, agent: String = "Claude",
                hotkeysEnabled: Bool = true) {
        self.step = step
        self.popoverPart = popoverPart
        self.coach = coach
        self.agent = agent
        self.hotkeysEnabled = hotkeysEnabled
    }

    /// A step as the app would show it, with its own coach line (previews, snapshots).
    public static func at(_ step: TourStep, part: TourPopoverPart = .status, agent: String = "Claude",
                          hotkeys: Bool = true) -> TourPresentation {
        TourPresentation(step: step, popoverPart: part, coach: TourCopy.coach(step, part: part, agent: agent, hotkeys: hotkeys),
                         agent: agent, hotkeysEnabled: hotkeys)
    }

    /// 1-based place in the progress dots; `nil` on the offer.
    public var progressIndex: Int? { step.progressIndex }
    public var progressCount: Int { TourStep.progressCount }
}
