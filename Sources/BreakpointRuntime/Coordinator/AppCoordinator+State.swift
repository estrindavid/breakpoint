import Foundation
import BreakpointCore

// Core state → `AppState` (SPEC §7.2). Every assignment goes through `set` so unchanged
// values do not re-render views.

extension AppCoordinator {
    func publish(now: Date? = nil) {
        let now = now ?? currentDate()
        set(\.now, now)
        set(\.settings, settings)
        set(\.sessions, tracker.sessionsByUrgency)
        set(\.commands, tracker.commands)
        // Before `status` changes: the cue compares the menu bar as it was with what it becomes.
        let menuBar = menuBarWithCue(menuBarState(now: now), now: now)
        set(\.status, statusState(now: now))
        set(\.menuBar, menuBar)
        set(\.lastDecision, currentDecision.flatMap { $0.isUndoable(at: now) ? $0 : nil })
        set(\.today, todaySummary)
        set(\.totals, totals)
        set(\.nudge, nudge)
        set(\.activeBreak, breakSession.map { activeBreakState($0, now: now) } ?? completionMoment?.state)
        set(\.cards, cards)
        set(\.integrations, integrationRows())
        set(\.update, updateState())
        set(\.tour, tourPresentation())
        set(\.popoverHint, popoverHint)
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, Value>, _ value: Value) {
        if state[keyPath: keyPath] != value { state[keyPath: keyPath] = value }
    }

    // MARK: - Status and menu bar

    private func statusState(now: Date) -> StatusState {
        let cadence = settings.cadence
        let eyesIn = eyesIn()
        let moveIn = moveIn(now: now)
        let reason = pause.primaryReason
        // Any drop in still time is a reset (a break or time away): from then on "since you
        // moved" is something Breakpoint measured.
        if timers.stillTime < lastPublishedStillTime { stillCountedSinceLaunch = false }
        lastPublishedStillTime = timers.stillTime
        return StatusState(
            nextBreakKind: moveIn <= eyesIn ? .move : .eyes,
            nextBreakIn: min(eyesIn, moveIn),
            timers: timers,
            cadence: cadence,
            pause: pause,
            pauseSentence: reason.map { Copy.pauseSentence($0, now: now) },
            pausedUntil: reason?.until,
            isAway: presence.status.isAway,
            whyNotNow: whyNotNow(now: now),
            stillCountedSinceLaunch: stillCountedSinceLaunch)
    }

    /// "Why not now?" (SPEC §3.7): the engine's answer for the held opportunity, or for an agent
    /// starting this moment.
    func whyNotNow(now: Date) -> WaitReason {
        WhyNotNow.explain(snapshot(now: now), held: heldOpportunity, onBreak: breakSession != nil, now: now)
    }

    /// Raises the mark's one-shot movement when this change of the menu bar earns one (SPEC §3.7).
    private func menuBarWithCue(_ next: MenuBarState, now: Date) -> MenuBarState {
        defer { runFinishedSincePublish = false }
        if let cue = MarkCuePolicy.cue(from: markFacts(state.menuBar, pause: state.status.pause),
                                       to: markFacts(next, pause: pause), runFinished: runFinishedSincePublish) {
            markCue = MarkCueEvent(cue: cue, id: (markCue?.id ?? 0) + 1, at: now)
        }
        var menuBar = next
        menuBar.cue = markCue
        return menuBar
    }

    private func markFacts(_ menuBar: MenuBarState, pause: PauseState) -> MarkFacts {
        let agent: MarkFacts.Agent
        switch menuBar.badge {
        case .none: agent = .none
        case .working: agent = .working
        case .needsYou: agent = .needsYou
        }
        let wrappedUp = pause.reasons.contains { if case .windDownWrappedUp = $0 { return true } else { return false } }
        return MarkFacts(paused: menuBar.mark == .paused, wrappedUp: wrappedUp, agent: agent)
    }

    private func menuBarState(now: Date) -> MenuBarState {
        let status = statusState(now: now)
        var mark: MenuBarMark
        if breakSession != nil {
            mark = .onBreak
        } else if pause.isPaused {
            mark = .paused
        } else if status.isDue {
            mark = .due
        } else {
            mark = .idle
        }
        let sessions = tracker.sessionsByUrgency
        let waiting = sessions.first { $0.state == .waiting }
        let working = sessions.first { $0.state == .working }
        var badge: MarkBadge = waiting != nil ? .needsYou : (working != nil ? .working : .none)
        // The tour's sample: a break is due while the sample agent works, then it finishes during
        // the sample break (SPEC §3.12).
        if let step = tour?.step, badge == .none {
            switch step {
            case .mark, .nudge, .declined: badge = .working
            case .breakScreen:
                if let session = breakSession, TourPolicy.sampleAgentWorking(breakElapsed: session.elapsed(at: now)) { badge = .working }
            default: break
            }
        }
        if let step = tour?.step, [.mark, .nudge, .declined].contains(step), mark == .idle { mark = .due }

        let text: String?
        if pause.isPaused {
            text = "Paused"
        } else {
            switch settings.menuBarText {
            case .nothing: text = nil
            case .timeToNextBreak: text = Copy.menuBarCountdown(status.nextBreakIn)
            case .agentState: text = working.map { Copy.menuBarAgent($0.displayName, elapsed: $0.runElapsed(at: now) ?? 0) }
            }
        }

        let tooltip: String
        if let sentence = status.pauseSentence {
            tooltip = sentence
        } else if let waiting {
            tooltip = Copy.needsYou(agent: waiting.displayName)
        } else if breakSession != nil {
            tooltip = "On a break"
        } else if status.isDue {
            tooltip = Copy.statusCaption(kind: status.nextBreakKind, isDue: true)
        } else {
            tooltip = "\(Copy.statusCaption(kind: status.nextBreakKind, isDue: false)) \(DurationFormat.minutes(status.nextBreakIn, rounding: .up))"
        }
        return MenuBarState(mark: mark, badge: badge, text: text, tooltip: tooltip)
    }

    // MARK: - Overlay

    func activeBreakState(_ session: BreakSession, now: Date) -> ActiveBreakState {
        let elapsed = session.elapsed(at: now)
        var title = session.copy.title
        var instruction = session.copy.instruction
        var stepState: RoutineStepState?
        if let routine = session.routine, let step = session.currentStep {
            title = step.title
            instruction = step.instruction
            stepState = RoutineStepState(index: session.stepIndex, count: routine.steps.count, step: step,
                                         remaining: BreakSessionRules.stepRemaining(session, now: now))
        }
        let chip = isTourBreak(session) ? tourChip(session, now: now) : agentChip(for: session, now: now)
        if session.kind == .walk, session.needsYou, case .needsYou(let agent) = chip {
            // "We'll chime when Claude needs you" has come true: say what to do now.
            instruction = Copy.walkNeedsYouInstruction(agent: agent)
        }
        let idle = lastSample.secondsSinceAnyInput
        return ActiveBreakState(
            id: session.id, kind: session.kind, title: title, instruction: instruction, step: stepState,
            detail: session.detail, startedAt: session.startedAt, elapsed: elapsed, plannedLength: session.totalLength,
            extensionsUsed: session.extensionsUsed, canExtend: BreakSessionRules.canExtend(session),
            skipEnabledAt: Timing.skipGuard, doneAvailable: BreakSessionRules.isDoneAvailable(session, now: now),
            agentChip: chip, needsYou: session.needsYou,
            ambient: session.kind == .walk && !session.needsYou && idle >= Timing.walkAmbientAfter,
            welcomeBack: session.kind == .walk && walkIdlePeak >= Timing.walkWelcomeBackAfter && idle < 1,
            fullOnAllDisplays: settings.fullBreakOnAllDisplays, isPreview: session.isPreview,
            isRehearsal: isTourBreak(session),
            hint: breakHintID == session.id ? breakHint(chip) : nil)
    }

    /// Most urgent first: needs you > working > done; "2 agents working"; else the time (§3.3).
    private func agentChip(for session: BreakSession, now: Date) -> AgentChipState {
        let sessions = tracker.sessionsByUrgency
        if session.needsYou {
            return .needsYou(agent: sessions.first { $0.state == .waiting }?.displayName ?? "Your agent")
        }
        let working = sessions.filter { $0.state == .working }
        if working.count > 1 { return .severalWorking(working.count) }
        if let one = working.first { return .working(agent: one.displayName, elapsed: one.runElapsed(at: now) ?? 0) }
        if let finished = session.sessionsToResume.reversed().lazy.compactMap({ key in sessions.first { $0.key == key } }).first {
            return .done(agent: finished.displayName)
        }
        return .clock(now)
    }

    // MARK: - Integrations

    private func integrationRows() -> [IntegrationRowState] {
        // Every integration, including legacy Codex notify (shown under the Codex row's Options…).
        IntegrationID.allCases.map { id in
            let installState = integrationStates[id] ?? .notInstalled
            return IntegrationRowState(
                id: id,
                status: IntegrationStatus(installState: installState, lastEvent: lastEventBySource[id.source],
                                          checkProblem: installDiskProblems[id] ?? installCheckProblems[id]),
                notes: integrationNotes[id] ?? [],
                errorMessage: integrationErrors[id],
                isBusy: integrationBusy.contains(id),
                connectedAt: integrationConnectedAt[id],
                installState: installState)
        }
    }

    // MARK: - Wire status (`breakpoint status`)

    func statusReport() -> StatusReport {
        let now = currentDate()
        let eyesIn = eyesIn()
        let moveIn = moveIn(now: now)
        let onScreen = breakSession.flatMap { $0.isPreview ? nil : $0 }
        let offered = nudge.flatMap { $0.isPreview ? nil : $0 }
        return StatusReport(
            generatedAt: now,
            sessions: tracker.sessions.map {
                StatusReport.Session(source: $0.source, sessionID: $0.key.sessionID, state: $0.state, cwd: $0.cwd,
                                     lastEventAt: $0.lastEventAt, runStartedAt: $0.runStartedAt)
            },
            commands: tracker.commands,
            timers: timers,
            cadence: settings.cadence,
            paused: pause.primaryReason.map { Copy.pauseSentence($0, now: now) },
            away: presence.status.isAway,
            lastEventBySource: lastEventBySource,
            nextBreak: StatusReport.NextBreak(kind: moveIn <= eyesIn ? .move : .eyes, seconds: min(eyesIn, moveIn)),
            activeBreak: onScreen.map { StatusReport.ActiveBreak(kind: $0.kind, startedAt: $0.startedAt, length: $0.totalLength) },
            nudge: offered.map { StatusReport.Nudge(kind: $0.kind, title: Copy.nudgeTitle(kind: $0.kind, length: $0.offer.length)) })
    }

    /// The first-break hint: what the chip is for, or, with no agent, that skipping is fine (§3.12).
    private func breakHint(_ chip: AgentChipState) -> String {
        switch chip {
        case .clock: return HintCopy.breakNoAgent
        case .severalWorking: return HintCopy.breakChip(agent: nil)
        case .working(let agent, _), .done(let agent), .needsYou(let agent): return HintCopy.breakChip(agent: agent)
        }
    }
}
