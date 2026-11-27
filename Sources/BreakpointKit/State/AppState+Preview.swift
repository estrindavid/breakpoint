import Foundation
import BreakpointCore

/// Named states for previews and snapshots. Every screen's snapshot is built from one of these, so
/// every picture shows the same sample data.
public enum PreviewScenario: Equatable, Sendable {
    /// Nothing going on: timers mid-way, no agents.
    case idle
    /// One agent working, timers mid-way.
    case agentWorking
    /// A move break is due and its nudge is showing for an agent run.
    case breakDue(BreakKind = .move)
    /// Eye-rest auto-start with `remaining` seconds (≥ 5: card; < 5: countdown chip).
    case autoStart(remaining: TimeInterval)
    /// On a break of `kind`, `progress` (0…1) through it.
    case onBreak(BreakKind, progress: Double)
    /// Paused because the microphone is on.
    case pausedForCall
    /// Paused from the menu until 15:30.
    case pausedManual
    /// Back from 6 min away: credited, away note showing, decision line in the popover.
    case awayCredited
    /// It is 23:20, past the 23:00 stop time; `wrapUp` shows the note instead of the question.
    case windDown(wrapUp: Bool)
    /// Three agents (working, needs you, idle) and a long command.
    case severalAgents
    /// Resume cards after a break: `.one`, `.several` or `.needsYou`.
    case resume(ResumeVariant)
    /// The "Timers restored" toast.
    case toast
    /// First launch: defaults, nothing installed, nothing recorded.
    case firstRun

    public enum ResumeVariant: Sendable { case one, several, needsYou }
}

extension AppState {
    /// The fixed clock of every preview: Sunday 22 November 2026, 14:05 in the current time zone.
    nonisolated public static var previewNow: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 14, minute: 5)) ?? Date()
    }

    /// A fully populated state for `scenario`.
    @MainActor
    public static func preview(_ scenario: PreviewScenario, now: Date = AppState.previewNow) -> AppState {
        let p = PreviewData(now: now)
        let state = AppState(
            menuBar: MenuBarState(mark: .idle, badge: .none, text: nil, tooltip: "Eye rest in 6 min"),
            status: StatusState(nextBreakKind: .eyes, nextBreakIn: 6 * 60,
                                timers: TimerState(screenTime: 14 * 60, stillTime: 42 * 60)),
            today: DaySummary(dayStart: BreakpointDay.start(of: now), breaksTaken: 4, takenByKind: [.eyes: 3, .move: 1]),
            totals: p.totals(.weekIn),
            integrations: p.integrations(connected: true),
            settings: p.settings(onboarded: true),
            now: now)

        switch scenario {
        case .idle:
            break

        case .agentWorking:
            state.sessions = [p.claudeWorking]
            state.menuBar = MenuBarState(mark: .idle, badge: .working, text: nil, tooltip: "Claude is working")

        case .breakDue(let kind):
            state.sessions = [p.claudeWorking]
            state.status.timers = TimerState(screenTime: 17 * 60, stillTime: 68 * 60)
            state.status.nextBreakKind = kind == .eyes ? .eyes : .move
            state.status.nextBreakIn = 0
            state.menuBar = MenuBarState(mark: .due, badge: .working, text: nil, tooltip: "Stretch due")
            state.nudge = p.nudge(kind: kind)

        case .autoStart(let remaining):
            state.status.timers = TimerState(screenTime: 21 * 60, stillTime: 30 * 60)
            state.status.nextBreakIn = 0
            state.menuBar = MenuBarState(mark: .due, badge: .none, text: nil, tooltip: "Eye rest due")
            var nudge = p.nudge(kind: .eyes)
            nudge.autoStartRemaining = remaining
            nudge.phase = remaining > Timing.autoStartChipAt ? .autoStartCard : .countdownChip
            nudge.title = Copy.autoStartTitle(kind: .eyes, length: 20, remaining: remaining)
            state.nudge = nudge

        case .onBreak(let kind, let progress):
            state.sessions = [p.claudeWorking]
            state.menuBar = MenuBarState(mark: .onBreak, badge: .working, text: nil, tooltip: "On a break")
            state.activeBreak = p.activeBreak(kind: kind, progress: progress)

        case .pausedForCall:
            let pause = PauseState(reasons: [.call(.microphone)])
            state.status.pause = pause
            state.status.pauseSentence = Copy.pauseSentence(.call(.microphone), now: now)
            state.menuBar = MenuBarState(mark: .paused, badge: .none, text: "Paused", tooltip: "Paused: microphone is on")

        case .pausedManual:
            let until = now.addingTimeInterval(85 * 60)
            state.status.pause = PauseState(reasons: [.manual(until: until)])
            state.status.pauseSentence = Copy.pauseSentence(.manual(until: until), now: now)
            state.status.pausedUntil = until
            state.menuBar = MenuBarState(mark: .paused, badge: .none, text: "Paused", tooltip: state.status.pauseSentence ?? "Paused")

        case .awayCredited:
            let decision = p.creditedDecision
            state.lastDecision = decision
            state.status.timers = .zero
            state.status.nextBreakIn = 20 * 60
            state.cards = [CardState(content: .awayNote(AwayNoteContent(decisionID: decision.id, kind: .move,
                                                                        text: Copy.creditedAway(duration: 6 * 60))),
                                     createdAt: now)]

        case .windDown(let wrapUp):
            let late = Calendar.current.date(bySettingHour: 23, minute: 20, second: 0, of: now) ?? now
            state.now = late
            state.settings.windDownEnabled = true
            state.sessions = [p.claudeIdle, p.codexIdle]
            let lines = WindDownPolicy.wrapUpNote(sessions: state.sessions)
            state.cards = [CardState(content: .windDown(WindDownCardContent(
                now: late, stopTime: TimeOfDay(hour: 23, minute: 0), holdDuration: 3,
                phase: wrapUp ? .note(lines: lines) : .asking)), createdAt: late)]

        case .severalAgents:
            state.sessions = [p.claudeNeedsYou, p.codexWorking, p.cursorIdle]
            state.commands = [p.swiftTest]
            state.menuBar = MenuBarState(mark: .idle, badge: .needsYou, text: nil, tooltip: "Claude needs you")

        case .resume(let variant):
            state.sessions = [p.claudeIdle]
            let items: [ResumeItem]
            switch variant {
            case .one:
                items = [p.resumeItem(p.claudeIdle, .finished(duration: 6 * 60))]
            case .several:
                items = [p.resumeItem(p.claudeIdle, .finished(duration: 6 * 60)),
                         p.resumeItem(p.codexIdle, .finished(duration: 3 * 60)),
                         p.resumeItem(p.cursorIdle)]
            case .needsYou:
                items = [p.resumeItem(p.claudeNeedsYou)]
            }
            state.cards = [CardState(content: .resume(ResumeCardContent(items: items)), createdAt: now)]

        case .toast:
            state.cards = [CardState(content: .toast(ToastContent(text: Copy.timersRestored)), createdAt: now)]

        case .firstRun:
            state.settings = p.settings(onboarded: false)
            state.status.timers = .zero
            state.status.nextBreakIn = 20 * 60
            state.status.stillCountedSinceLaunch = true
            state.today = DaySummary(dayStart: BreakpointDay.start(of: now))
            state.totals = .empty
            state.integrations = p.integrations(connected: false)
        }
        return state
    }
}

/// Sample data shared by the preview scenarios.
public struct PreviewData {
    public let now: Date

    public init(now: Date = AppState.previewNow) { self.now = now }

    /// Stages of use for the popover's all-time totals (SPEC §3.8).
    public enum TotalsStage: String, CaseIterable, Sendable {
        /// One stretch, today: no example line yet.
        case firstBreak
        /// 5 stretches and a 6-min walk today (16 min), 7 eye rests; the walk just reached a new
        /// example, so it shows in mint.
        case firstDay
        /// Since Nov 16: 74 min, 26 stretches, 61 eye rests.
        case weekIn
        /// Since Oct 26: 5 h 20 min, 104 stretches, 268 eye rests.
        case monthIn
        /// Since Sep 14 of last year: 117 h, 2,915 stretches, 6,480 eye rests.
        case large
    }

    public func totals(_ stage: TotalsStage) -> HistoryTotals {
        let calendar = Calendar.current
        func daysAgo(_ days: Int, hour: Int = 10) -> Date {
            let day = calendar.date(byAdding: .day, value: -days, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        switch stage {
        case .firstBreak:
            return HistoryTotals(movingSeconds: 120, stretches: 1, eyeRests: 0, firstEntry: daysAgo(0, hour: 13),
                                 movingBeforeLatest: 0)
        case .firstDay:
            return HistoryTotals(movingSeconds: 16 * 60, stretches: 5, walks: 1, eyeRests: 7, firstEntry: daysAgo(0, hour: 9),
                                 movingBeforeLatest: 10 * 60)
        case .weekIn:
            return HistoryTotals(movingSeconds: 74 * 60, stretches: 26, walks: 3, eyeRests: 61, firstEntry: daysAgo(6),
                                 movingBeforeLatest: 72 * 60)
        case .monthIn:
            return HistoryTotals(movingSeconds: 320 * 60, stretches: 104, walks: 14, eyeRests: 268, firstEntry: daysAgo(27),
                                 movingBeforeLatest: 318 * 60)
        case .large:
            let first = calendar.date(from: DateComponents(year: calendar.component(.year, from: now) - 1, month: 9, day: 14,
                                                           hour: 10)) ?? now
            return HistoryTotals(movingSeconds: 7050 * 60, stretches: 2915, walks: 318, eyeRests: 6480, firstEntry: first,
                                 movingBeforeLatest: 7048 * 60)
        }
    }

    public var claudeWorking: AgentSession {
        AgentSession(key: SessionKey(source: .claudeCode, sessionID: "c1"), state: .working,
                     cwd: "/Users/dev/code/breakpoint", title: "fix the login redirect after OAuth callback",
                     createdAt: now.addingTimeInterval(-3600), lastEventAt: now.addingTimeInterval(-4),
                     runStartedAt: now.addingTimeInterval(-102))
    }

    public var claudeNeedsYou: AgentSession {
        var s = claudeWorking
        s.state = .waiting
        s.waitingSince = now.addingTimeInterval(-20)
        s.report = RunReport(edits: 3, commands: 4, request: AgentRequest(tool: .command, subject: "npm install --save-dev vitest"))
        return s
    }

    public var claudeIdle: AgentSession {
        var s = claudeWorking
        s.state = .idle
        s.runStartedAt = nil
        s.lastRunEnding = .finished(duration: 6 * 60)
        s.lastRunEndedAt = now.addingTimeInterval(-30)
        s.report = RunReport(edits: 7, commands: 12,
                             message: "Fixed the redirect: the callback now keeps the original URL, and all 214 tests pass.")
        return s
    }

    public var codexWorking: AgentSession {
        AgentSession(key: SessionKey(source: .codex, sessionID: "x1"), state: .working,
                     cwd: "/Users/dev/code/payments-service", title: "add retries to the webhook client",
                     createdAt: now.addingTimeInterval(-1800), lastEventAt: now.addingTimeInterval(-60),
                     runStartedAt: now.addingTimeInterval(-260))
    }

    public var codexIdle: AgentSession {
        var s = codexWorking
        s.state = .idle
        s.runStartedAt = nil
        s.lastRunEnding = .finished(duration: 3 * 60)
        s.report = RunReport(edits: 2, commands: 3, message: "Added exponential backoff to the webhook client, with a test.")
        return s
    }

    public var cursorIdle: AgentSession {
        AgentSession(key: SessionKey(source: .cursor, sessionID: "u1"), state: .idle,
                     cwd: "/Users/dev/code/site", title: "tighten the hero spacing",
                     createdAt: now.addingTimeInterval(-7000), lastEventAt: now.addingTimeInterval(-900),
                     lastRunEnding: .failed)
    }

    public var swiftTest: RunningCommand {
        RunningCommand(shellPID: "4242", command: "swift", cwd: "/Users/dev/code/breakpoint",
                       startedAt: now.addingTimeInterval(-48))
    }

    public var creditedDecision: AutoDecision {
        AutoDecision(kind: .creditedAway([.eyes, .move], duration: 6 * 60), madeAt: now.addingTimeInterval(-40),
                     sentence: Copy.creditedAway(duration: 6 * 60),
                     previous: TimerState(screenTime: 22 * 60, stillTime: 55 * 60))
    }

    public func settings(onboarded: Bool) -> Settings {
        var s = Settings()
        s.hasCompletedOnboarding = onboarded
        return s
    }

    public func integrations(connected: Bool) -> [IntegrationRowState] {
        IntegrationID.settingsRows.map { id in
            switch (id, connected) {
            case (.claudeCode, true): return IntegrationRowState(id: id, status: .connected(lastEvent: now.addingTimeInterval(-120)))
            case (.codex, true): return IntegrationRowState(id: id, status: .connected(lastEvent: nil),
                                                            notes: ["Open /hooks in Codex and trust the new entries."])
            case (.gemini, _): return IntegrationRowState(id: id, status: .notFound)
            default: return IntegrationRowState(id: id, status: .notInstalled)
            }
        }
    }

    public func nudge(kind: BreakKind) -> NudgeState {
        let opportunity = Opportunity(kind: .agentStarted, source: .claudeCode, sessionID: "c1", createdAt: now)
        let length = kind == .walk ? 6 * 60 : kind.defaultLength
        let offer = BreakOffer(kind: kind, length: length, opportunity: opportunity,
                               overdueBy: kind == .eyes ? 60 : 18 * 60, timerValue: 68 * 60,
                               expectedRunLength: kind == .walk ? 6 * 60 + 10 : 4 * 60)
        return NudgeState(offer: offer, title: Copy.nudgeTitle(kind: kind, length: length),
                          subtitle: Copy.nudgeSubtitle(for: offer), whyNow: Copy.whyNow(for: offer), shownAt: now)
    }

    public func activeBreak(kind: BreakKind, progress: Double) -> ActiveBreakState {
        let session = BreakSessionRules.makeSession(kind: kind, opportunity: nil, settings: .defaults,
                                                    expectedRun: 6 * 60 + 10, agentName: "Claude", copyRotation: 0,
                                                    now: now)
        let elapsed = session.totalLength * progress
        var stepState: RoutineStepState?
        var title = session.copy.title
        var instruction = session.copy.instruction
        if let routine = session.routine {
            let index = routine.stepIndex(at: elapsed)
            let step = routine.steps[index]
            let stepElapsed = elapsed - routine.stepOffsets[index]
            stepState = RoutineStepState(index: index, count: routine.steps.count, step: step,
                                         remaining: max(0, step.duration - stepElapsed))
            title = step.title
            instruction = step.instruction
        }
        return ActiveBreakState(
            kind: kind, title: title, instruction: instruction, step: stepState,
            detail: kind == .walk ? BreakCopyLibrary.walkIdeas[0] : nil, startedAt: now.addingTimeInterval(-elapsed), elapsed: elapsed, plannedLength: session.totalLength,
            canExtend: kind.allowsExtension,
            doneAvailable: kind != .walk && progress >= Timing.doneFraction,
            agentChip: .working(agent: "Claude", elapsed: 102 + elapsed))
    }

    /// The resume row for `session` as the coordinator would build it with snippets on; `outcome`
    /// overrides what happened.
    public func resumeItem(_ session: AgentSession, _ outcome: ResumeFacts.Outcome? = nil) -> ResumeItem {
        var facts = ResumeFacts.session(session, keepSnippets: true)
            ?? ResumeFacts(name: session.displayName, folder: session.projectName, outcome: .finished(duration: 0),
                           snippet: session.title)
        if let outcome { facts.outcome = outcome }
        return ResumeItem(id: session.key, facts: facts)
    }
}
