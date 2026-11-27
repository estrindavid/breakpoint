import Combine
import Foundation
import BreakpointCore

/// Everything every screen shows (SPEC §7.2). Views depend only on `AppState`, `AppActions` and
/// Core models. Only `AppCoordinator` writes it, on the main thread; window controllers observe it.
///
/// Fields follow SPEC §7.2 one for one, plus `now` (the coordinator's clock, so
/// views and snapshots never read the system clock).
@MainActor
public final class AppState: ObservableObject {
    /// The status item: mark, badge, text, tooltip.
    @Published public var menuBar: MenuBarState
    /// Next break, still time, pause state (popover status block).
    @Published public var status: StatusState
    /// The undoable decision for the popover's decision line (only while undoable).
    @Published public var lastDecision: AutoDecision?
    /// Agent sessions, most urgent first.
    @Published public var sessions: [AgentSession]
    /// Running long commands.
    @Published public var commands: [RunningCommand]
    /// Breaks taken today (debug harness; the popover shows `totals`).
    @Published public var today: DaySummary
    /// The popover's all-time figures and example line (SPEC §3.8).
    @Published public var totals: HistoryTotals
    /// The visible nudge or countdown chip, if any.
    @Published public var nudge: NudgeState?
    /// The break in progress, if any.
    @Published public var activeBreak: ActiveBreakState?
    /// Pop-ups other than the nudge (resume cards, away note, toasts, wind-down), oldest first.
    /// `TransientPanelStack` decides which (at most 2) are visible.
    @Published public var cards: [CardState]
    /// Settings → Integrations and onboarding step 3.
    @Published public var integrations: [IntegrationRowState]
    @Published public var settings: Settings
    /// The update check: this version, the last result, a newer release (Settings → About).
    @Published public var update: UpdateState
    /// The coordinator's clock as of the last tick.
    @Published public var now: Date
    /// The one-minute tour, while it runs (SPEC §3.12).
    @Published public var tour: TourPresentation?
    /// The first-use hint at the bottom of the popover, while it is open the first time (§3.12).
    @Published public var popoverHint: String?

    public init(
        menuBar: MenuBarState = MenuBarState(),
        status: StatusState = StatusState(),
        lastDecision: AutoDecision? = nil,
        sessions: [AgentSession] = [],
        commands: [RunningCommand] = [],
        today: DaySummary? = nil,
        totals: HistoryTotals = .empty,
        nudge: NudgeState? = nil,
        activeBreak: ActiveBreakState? = nil,
        cards: [CardState] = [],
        integrations: [IntegrationRowState] = IntegrationID.settingsRows.map { IntegrationRowState(id: $0) },
        settings: Settings = .defaults,
        update: UpdateState = UpdateState(),
        now: Date = Date(),
        tour: TourPresentation? = nil
    ) {
        self.menuBar = menuBar
        self.status = status
        self.lastDecision = lastDecision
        self.sessions = sessions
        self.commands = commands
        self.today = today ?? DaySummary(dayStart: BreakpointDay.start(of: now))
        self.totals = totals
        self.nudge = nudge
        self.activeBreak = activeBreak
        self.cards = cards
        self.integrations = integrations
        self.settings = settings
        self.update = update
        self.now = now
        self.tour = tour
    }

    /// The integration row for `id`.
    public func integration(_ id: IntegrationID) -> IntegrationRowState? {
        integrations.first { $0.id == id }
    }

    /// The decision, if still undoable at `now`.
    public var undoableDecision: AutoDecision? {
        guard let decision = lastDecision, decision.isUndoable(at: now) else { return nil }
        return decision
    }
}
