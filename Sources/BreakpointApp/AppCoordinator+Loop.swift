import AppKit
import BreakpointCore
import BreakpointKit

// The engine loop (SPEC §2.3–2.8, §3.1, §3.3). All decisions are delegated to Core: this file
// only sequences them and applies their results.
//
// Tests/BreakpointCoreTests/CoreLogic/DaySimulator.swift replays whole days through the same
// sequence on a fake clock; keep the two in step when changing the order of anything here.

extension AppCoordinator {
    // MARK: - Tick (1 Hz, 10 Hz while a nudge or countdown is visible)

    func tick() {
        let now = currentDate()
        let dt = min(max(now.timeIntervalSince(lastTick), 0), 5)
        lastTick = now
        windDown = WindDownPolicy.rolledOver(windDown, now: now, calendar: calendar)
        // The wind-down card was dismissed or pushed out of the stack: it may be offered again.
        if windDown.cardVisible, !cards.contains(where: { if case .windDown = $0.content { return true } else { return false } }) {
            windDown.cardVisible = false
        }
        if BreakpointDay.start(of: now, calendar: calendar) != todaySummary.dayStart {
            refreshToday()
        }

        // Input and presence (§2.3).
        let sample = monitor.sample()
        lastSample = sample
        let callSignals = monitor.callSignals
        let callActive = !callSignals.filtered(by: settings).isEmpty
        // This tick's dt has not accrued yet, so a retroactive away start removes that much less.
        handlePresenceChanges(presence.ingest(sample, callActive: callActive, settings: settings), now: now, unaccrued: dt)

        // Timers accrue while present (§2.3).
        timers = ActivityClock.advance(timers, sample: sample, presence: presence.status, dt: dt)

        // Pauses and cool-downs (§2.4).
        updatePause(callSignals: callSignals, now: now)

        // Sessions: interrupt fallback and expiry (§2.6).
        apply(tracker.expire(now: now), now: now)

        // The optional AirPods check asks for Motion access when it is switched on (§2.9).
        headphones.prepare(enabled: settings.airpodsMovementCheck)

        // Breaks in progress (§3.3, §3.4), and the closing moment of one just completed.
        if breakSession != nil { advanceBreak(sample: sample, now: now) }
        endCompletionIfDue(now: now)

        // Eye-rest auto-start ladder (§3.1).
        advanceAutoStart(sample: sample, now: now)

        // Non-event opportunities and held ones (§2.5).
        for opportunity in detector.evaluate(snapshot(now: now), now: now) {
            evaluate(opportunity, now: now)
        }
        if let held = heldOpportunity {
            evaluate(held, now: now)
        }

        expireCards(now: now)
        // The daily update check and its prompt, only at quiet moments (§2.11).
        considerUpdates(now: now)
        publish(now: now)
        scheduleTick(interval: (nudge != nil) ? 0.1 : 1)
    }

    // MARK: - Engine

    /// Everything the engine may look at (§7.1).
    func snapshot(now: Date) -> EngineSnapshot {
        EngineSnapshot(
            settings: settings,
            timers: timers,
            presence: presence.status,
            input: lastSample,
            pause: pause,
            // The tour's sample nudge and break do not hold real offers back: a real one ends the
            // rehearsal instead (SPEC §3.12).
            surfaceVisible: (nudge != nil && nudge?.isRehearsal != true) || (breakSession != nil && !isTourBreak(breakSession)),
            lastNudgeAt: lastNudgeAt,
            lastBreakEndedAt: lastBreakEndedAt,
            kindSpacedUntil: kindSpacedUntil,
            consecutiveMoveRefusals: consecutiveMoveRefusals,
            stretchHeldUntil: stretchHeldUntil,
            sessions: tracker.sessions,
            commands: tracker.commands,
            expectedRunLengths: tracker.estimator.expectedRunLengths,
            microphonePending: microphonePending(now: now))
    }

    /// A microphone is on (and counted for calls) but not yet a call: dictation (§2.4).
    func microphonePending(now: Date) -> Bool {
        microphoneGate.isPending(monitor.callSignals.filtered(by: settings), at: now)
    }

    /// Runs the engine on an opportunity and acts on the decision (§2.5).
    func evaluate(_ opportunity: Opportunity, now: Date) {
        if opportunity.isExpired(at: now) {
            if heldOpportunity?.id == opportunity.id { heldOpportunity = nil }
            return
        }
        if opportunity.kind == .manual { return }
        switch BreakEngine.decide(snapshot(now: now), opportunity: opportunity, now: now) {
        case .offer(let offer):
            heldOpportunity = nil
            interruptTour(.realBreak, now: now)
            showNudge(offer, isPreview: false, now: now)
        case .hold:
            heldOpportunity = opportunity
        case .suppress, .nothing:
            if heldOpportunity?.id == opportunity.id { heldOpportunity = nil }
        }
    }

    // MARK: - Nudge lifecycle (§3.1)

    func showNudge(_ offer: BreakOffer, isPreview: Bool, now: Date) {
        // Never by itself while presenting, watching or dictating (§2.4, §3.1).
        let autoStart = offer.kind == .eyes && settings.autoStartEyes && !isPreview
            && AutoStartRules.allows(lastSample, microphonePending: microphonePending(now: now))
        var title = Copy.nudgeTitle(kind: offer.kind, length: offer.length)
        if autoStart {
            title = Copy.autoStartTitle(kind: offer.kind, length: offer.length, remaining: Timing.autoStartCountdown)
        }
        nudge = NudgeState(offer: offer, phase: autoStart ? .autoStartCard : .offer, title: title,
                           subtitle: Copy.nudgeSubtitle(for: offer), whyNow: Copy.whyNow(for: offer),
                           autoStartRemaining: autoStart ? Timing.autoStartCountdown : nil,
                           hotkeysEnabled: settings.nudgeHotkeys, isPreview: isPreview, shownAt: now)
        autoStartDeadline = autoStart ? now.addingTimeInterval(Timing.autoStartCountdown) : nil
        autoStartBegan = autoStart ? now : nil
        if !isPreview { lastNudgeAt = now }
        // The first real nudge carries a hint (SPEC §3.12): an eye rest that starts by itself has its own.
        let lesson = HintPolicy.nudgeLesson(autoStart: autoStart)
        let hint = takeHint(lesson, isPreview: isPreview) ? HintCopy.nudge(lesson) : nil
        nudge?.hint = hint
        publish(now: now)
        scheduleTick(interval: 0.1)
    }

    /// Records the end of a nudge and clears it. `outcome` nil = withdrawn (nothing recorded).
    func endNudge(_ outcome: BreakOutcome?, now: Date) {
        guard let current = nudge else { return }
        nudge = nil
        autoStartDeadline = nil
        autoStartBegan = nil
        guard let outcome, !current.isPreview else { return }
        let offer = current.offer
        record(HistoryEntry(kind: offer.kind, outcome: outcome, opportunityKind: offer.opportunity.kind,
                            source: offer.opportunity.source, start: current.shownAt))
        if outcome == .declined || outcome == .ignored {
            // A refusal spaces its slot: ten minutes, or a whole cadence from the third in a row (§2.4).
            let inARow: Int
            if offer.kind == .eyes {
                consecutiveEyeRefusals += 1
                inARow = consecutiveEyeRefusals
            } else {
                consecutiveMoveRefusals += 1
                inARow = consecutiveMoveRefusals
            }
            kindSpacedUntil[offer.kind] = now.addingTimeInterval(
                BreakEngine.spacingAfterRefusal(offer.kind, refusalsInARow: inARow, cadence: settings.cadence))
        }
    }

    /// Withdraws a visible nudge without recording (needs-you, pause, away; §3.1).
    func withdrawNudge(now: Date) {
        guard nudge != nil else { return }
        // Whatever withdraws a real offer (a pause, wrap-up) ends the rehearsal around the sample one.
        if nudge?.isRehearsal == true { return interruptTour(.paused, now: now) }
        endNudge(nil, now: now)
    }

    private func advanceAutoStart(sample: InputSample, now: Date) {
        guard var current = nudge, let deadline = autoStartDeadline, let began = autoStartBegan else { return }
        let sinceBegan = now.timeIntervalSince(began)
        // A key press, click or scroll after the countdown began cancels it, and so does a display
        // becoming mirrored or kept awake, or a microphone coming on (§3.1, §2.4, decision 8).
        if AutoStartRules.cancels(sample, runningFor: sinceBegan, microphonePending: microphonePending(now: now)) {
            cancelAutoStart(now: now)
            return
        }
        let remaining = deadline.timeIntervalSince(now)
        if remaining <= 0 {
            startBreak(current.offer.kind, opportunity: current.offer.opportunity, length: current.offer.length,
                       isPreview: false, now: now)
            return
        }
        current.autoStartRemaining = remaining
        current.phase = remaining <= Timing.autoStartChipAt ? .countdownChip : .autoStartCard
        current.title = Copy.autoStartTitle(kind: current.kind, length: current.offer.length, remaining: remaining)
        nudge = current
    }

    /// Step 1 (card): revert to a normal offer that stays 10 s. Step 2 (chip): `ignored`.
    func cancelAutoStart(now: Date) {
        guard var current = nudge, autoStartDeadline != nil else { return }
        autoStartDeadline = nil
        autoStartBegan = nil
        if current.phase == .countdownChip {
            endNudge(.ignored, now: now)
        } else {
            current.phase = .offer
            current.autoStartRemaining = nil
            // "Press any key to keep working" was just done: the line goes with the countdown.
            current.hint = nil
            current.title = Copy.nudgeTitle(kind: current.kind, length: current.offer.length)
            nudge = current
        }
        publish(now: now)
    }

    // MARK: - Break lifecycle (§3.3)

    func startBreak(_ kind: BreakKind, opportunity: Opportunity?, length: TimeInterval?, isPreview: Bool, now: Date) {
        if breakSession != nil { return }
        completionMoment = nil
        endNudge(nil, now: now)
        let sourceSession = snapshot(now: now).session(opportunity?.sessionKey)
            ?? tracker.sessionsByUrgency.first { $0.state != .idle }
        let expectedRun = sourceSession.map { tracker.expectedRunLength(for: $0.source) }
        let pick = drawRotation(kind, isPreview: isPreview)
        var session = BreakSessionRules.makeSession(
            kind: kind, opportunity: opportunity, settings: settings, expectedRun: expectedRun,
            agentName: sourceSession?.displayName, copyRotation: pick.copy, now: now, isPreview: isPreview,
            routine: pick.routine)
        if let length, kind == .walk, !isPreview { session.plannedLength = length }
        if kind == .walk { session.detail = drawWalkIdea(isPreview: isPreview) }
        breakSession = session
        heldOpportunity = nil
        walkIdlePeak = 0
        breakHintID = takeHint(.breakScreen, isPreview: isPreview) ? session.id : nil
        if !isPreview, settings.airpodsMovementCheck, kind == .move || kind == .walk, headphones.isAvailable {
            headphones.begin()
            motionCheckRunning = true
        }
        publish(now: now)
    }

    private func advanceBreak(sample: InputSample, now: Date) {
        guard var session = breakSession else { return }
        let before = session
        session = BreakSessionRules.advanced(session, now: now)
        breakSession = session
        playStepTickIfDue(from: before, to: session)
        if session.isPreview, session.elapsed(at: now) >= Timing.previewLength {
            endBreak(nil, now: now)
            return
        }
        if BreakSessionRules.timerEnded(session, now: now) {
            endBreak(.timerEnded, now: now)
        } else if BreakSessionRules.hitCeiling(session, now: now) {
            endBreak(.ceiling, now: now)
        } else if session.kind == .walk {
            walkIdlePeak = max(walkIdlePeak, sample.secondsSinceAnyInput)
        }
    }

    /// Ends the break, records its outcome and applies the timer rules. `end` nil = a preview.
    func endBreak(_ end: BreakEnd?, now: Date) {
        guard let session = breakSession else { return }
        if isTourBreak(session) {
            // The tour's sample break: nothing recorded, timers untouched; the tour moves on.
            breakSession = nil
            tourBreakID = nil
            if !session.sessionsToResume.isEmpty { showResumeCard(for: session.sessionsToResume, now: now) }
            handleTour(.breakEnded)
            publish(now: now)
            return
        }
        breakSession = nil
        breakHintID = nil
        lastBreakEndedAt = session.isPreview ? lastBreakEndedAt : now
        var movement = false
        if motionCheckRunning {
            motionCheckRunning = false
            movement = headphones.end()
        }
        if let end, !session.isPreview {
            let outcome = BreakSessionRules.outcome(for: end, session: session, now: now)
            record(HistoryEntry(kind: session.kind, outcome: outcome, opportunityKind: session.opportunity?.kind ?? .manual,
                                source: session.opportunity?.source, start: session.startedAt,
                                duration: session.elapsed(at: now), movementDetected: movement))
            let before = timers
            timers = ActivityClock.afterBreak(timers, kind: session.kind, outcome: outcome)
            // A break that reset the timers makes Undo of an earlier away decision meaningless.
            if timers != before { currentDecision = nil }
            // A started break is never a refusal (§2.7). A stretch, walk or breather answers the
            // still-time slot: a breather restarts nothing, so it holds the slot for a cadence.
            switch session.kind {
            case .move, .walk:
                consecutiveMoveRefusals = 0
                stretchHeldUntil = nil
            case .breathe:
                consecutiveMoveRefusals = 0
                stretchHeldUntil = now.addingTimeInterval(settings.cadence.moveEvery)
            case .eyes:
                consecutiveEyeRefusals = 0
            }
            if settings.chimeBreakEnd, outcome == .completed, monitor.callSignals.isEmpty {
                sound.play(.breakEndChime, volume: settings.volume)
            }
            if outcome == .completed, end != .finish(.backToWork) { beginCompletion(session, now: now) }
        }
        if !session.sessionsToResume.isEmpty {
            showResumeCard(for: session.sessionsToResume, now: now)
        }
        publish(now: now)
    }

    // MARK: - Agent events (§2.6)

    func handle(_ event: AgentEvent) {
        let now = currentDate()
        // A tool connected or removed with `breakpoint install` while the app runs: re-read the
        // install states now and then, so status pills and the relayed-Cursor rule stay right.
        if integrationsRefreshedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            refreshIntegrations()
        }
        if event.source == .cursor, event.via == AgentEvent.viaClaudeCodeHooks, !tracker.nativeCursorInstalled {
            // About to be accepted as Cursor's only signal: confirm on the spot (one small read of
            // ~/.cursor/hooks.json) that Breakpoint's own Cursor hooks were not installed meanwhile,
            // e.g. with `breakpoint install cursor`, or every Cursor run would count twice.
            tracker.nativeCursorInstalled = CursorIntegration(environment: integrationEnvironment).status().hasBreakpointEntries
        }
        if event.kind == .test {
            // The hook command run after Install reached the app: the install is verified (§5.6).
            // Otherwise a test event (`breakpoint emit test`) changes nothing.
            for id in installChecks.keys where id.source == event.source {
                passInstallCheck(id)
            }
            publish(now: now)
            return
        }
        // The tool runs its hooks: a failed install check no longer applies. The last event is
        // shown as information, never as a condition for being connected.
        lastEventBySource[event.source] = now
        for id in IntegrationID.allCases where id.source == event.source {
            installCheckProblems[id] = nil
        }
        // A fresh sample: the Return key that submitted the prompt must hold the opportunity (§2.4),
        // and the last tick's sample can be up to a second old.
        lastSample = monitor.sample()
        let update = tracker.apply(event, now: now)
        apply(update, now: now)
        if let opportunity = update.opportunity {
            evaluate(opportunity, now: now)
        }
        publish(now: now)
    }

    /// Reacts to session transitions: needs-you, finished runs, wind-down.
    func apply(_ update: TrackerUpdate, now: Date) {
        for transition in update.transitions {
            switch transition {
            case .needsUser(let key):
                dropHeldOpportunity(for: key)
                interruptTour(.needsYou, now: now)
                withdrawNudge(now: now)
                if var session = breakSession {
                    if !session.needsYou, settings.chimeNeedsYou, monitor.callSignals.isEmpty {
                        sound.play(.needsYouChime, volume: settings.volume)
                    }
                    session.needsYou = true
                    if !session.sessionsToResume.contains(key) { session.sessionsToResume.append(key) }
                    breakSession = session
                } else if presence.status.isAway, !resumeWhileAway.contains(key) {
                    resumeWhileAway.append(key)
                }
            case .resumedWorking(let key):
                withdrawNeedsYou(key)
            case .runEnded(let key, let ending):
                // An offer saying "Claude is working" would be wrong now.
                dropHeldOpportunity(for: key)
                if case .finished = ending { runFinishedSincePublish = true }
                // Whoever answered the agent is back: its needs-you row is stale (SPEC §3.5).
                withdrawNeedsYou(key)
                if ending != .cancelled {
                    queueForResumeCard(key)
                    if WindDownPolicy.shouldOfferCard(windDown, settings: settings, now: now, calendar: calendar) {
                        showWindDownCard(now: now)
                    }
                }
                saveEstimator()
            case .sessionEnded(let key):
                dropHeldOpportunity(for: key)
                withdrawNeedsYou(key)
            case .commandFinished(let command, let result):
                if heldOpportunity?.kind == .longCommand, heldOpportunity?.sessionID == command.shellPID {
                    heldOpportunity = nil
                }
                // A long command that ended during a break or while away goes on the resume card.
                if let result, ResumeFacts.commandIsWorthShowing(result), breakSession != nil || presence.status.isAway {
                    let key = SessionKey(source: .shell, sessionID: command.shellPID)
                    finishedCommands[key] = ResumeFacts.command(command, result: result)
                    queueForResumeCard(key)
                }
            case .sessionStarted, .runStarted, .commandStarted:
                break
            }
        }
    }

    /// Keeps `key` for the resume card that follows the current break or away period.
    private func queueForResumeCard(_ key: SessionKey) {
        if var session = breakSession {
            if !session.sessionsToResume.contains(key) { session.sessionsToResume.append(key) }
            breakSession = session
        } else if presence.status.isAway, !resumeWhileAway.contains(key) {
            resumeWhileAway.append(key)
        }
    }

    /// Removes `key`'s needs-you row from the resume card on screen once the session is no longer
    /// waiting (resumed working, run ended, session ended); a card left with no rows goes away.
    func withdrawNeedsYou(_ key: SessionKey) {
        guard let index = cards.firstIndex(where: { if case .resume = $0.content { return true } else { return false } }),
              case .resume(var content) = cards[index].content,
              content.items.contains(where: { $0.id == key && $0.facts.needsYou }) else { return }
        content.items.removeAll { $0.id == key && $0.facts.needsYou }
        if content.items.isEmpty {
            cards.remove(at: index)
        } else {
            cards[index].content = .resume(content)
        }
    }

    private func dropHeldOpportunity(for key: SessionKey) {
        if heldOpportunity?.sessionKey == key { heldOpportunity = nil }
    }

    // MARK: - Presence (§2.3)

    func handlePresenceEvent(_ event: PresenceEvent) {
        let now = currentDate()
        handlePresenceChanges(presence.ingest(event, at: now), now: now)
        if event == .unlocked || event == .systemDidWake || event == .displaysWoke {
            pause = PausePolicy.startCooldown(pause, now: now)
        }
        publish(now: now)
    }

    private func handlePresenceChanges(_ changes: [PresenceChange], now: Date, unaccrued: TimeInterval = 0) {
        for change in changes {
            switch change {
            case .becameAway(_, _, let retroactive):
                timers = ActivityClock.removingAccrual(timers, seconds: max(0, retroactive - unaccrued))
                interruptTour(.away, now: now)
                withdrawNudge(now: now)
                heldOpportunity = nil
            case .returned(var period):
                // Time away during a break is the break itself (a walk leaves the keyboard idle for
                // minutes): it is never credited a second time as a natural break.
                if breakSession == nil {
                    if let ended = lastBreakEndedAt, ended > period.start { period.start = min(ended, period.end) }
                    resolveAway(period, now: now)
                }
                pause = PausePolicy.startCooldown(pause, now: now)
                if !resumeWhileAway.isEmpty {
                    showResumeCard(for: resumeWhileAway, now: now)
                    resumeWhileAway.removeAll()
                }
            }
        }
    }

    /// Natural breaks (§2.3): reset timers, record credits, say so once, keep Undo.
    private func resolveAway(_ period: AwayPeriod, now: Date) {
        let resolution = AwayPolicy.resolve(period, timers: timers, settings: settings, now: now)
        // Away time that resets a timer is a break of that kind: the refusals before it no longer count.
        if resolution.timers.stillTime < timers.stillTime { consecutiveMoveRefusals = 0 }
        if resolution.timers.screenTime < timers.screenTime { consecutiveEyeRefusals = 0 }
        timers = resolution.timers
        for entry in resolution.creditedEntries { record(entry) }
        guard let decision = resolution.decision else { return }
        currentDecision = decision
        // Only the latest decision can be undone, so only its note is shown.
        cards.removeAll { if case .awayNote = $0.content { return true } else { return false } }
        if resolution.showsAwayNote, let kind = decision.creditedKinds.max() {
            cards.append(CardState(content: .awayNote(AwayNoteContent(
                decisionID: decision.id, kind: kind, text: decision.sentence)), createdAt: now))
        }
    }

    // MARK: - Pauses (§2.4)

    func updatePause(callSignals raw: CallSignals, now: Date) {
        // A microphone counts as a call only once it has been on for a minute (§2.4).
        microphoneGate.observe(raw, at: now)
        let callSignals = microphoneGate.counted(raw, at: now)
        let before = pause
        pause = PausePolicy.update(pause, callSignals: callSignals, settings: settings, now: now)
        let callStarted = pause.callSignals != nil && before.callSignals == nil
        if callStarted { interruptTour(.call, now: now) }
        if pause.isPaused && !before.isPaused || callStarted {
            let nudgeWasVisible = nudge != nil
            withdrawNudge(now: now)
            // The call-pause toast only when a due break or a visible nudge was affected (§3.5, decision 17),
            // and once more to carry the first call pause's hint (§3.12).
            if callStarted, let signals = pause.callSignals {
                let hintShows = HintPolicy.shows(.callPause, settings: settings, context: HintPolicy.Context(
                    tourRunning: tour != nil, onboardingOpen: onboarding?.isVisible == true, hintOnScreen: hintOnScreen))
                if HintPolicy.showsCallPauseToast(nudgeWasVisible: nudgeWasVisible, breakDue: nextBreakIn() <= 0,
                                                  hintShows: hintShows) {
                    let hint = takeHint(.callPause) ? HintCopy.callPause : nil
                    cards.append(CardState(content: .toast(ToastContent(text: Copy.callPauseToast(signals),
                                                                        action: .resumeFromCall, hint: hint)), createdAt: now))
                }
            }
        }
        lastCallSignals = callSignals
    }

    // MARK: - Cards

    func showResumeCard(for newKeys: [SessionKey], now: Date) {
        // The new card replaces the old one, so carry over the sessions on it that still need the
        // user: a needs-you card stays until dismissed, and a later "finished" must not drop it.
        var keys: [SessionKey] = []
        for card in cards {
            guard case .resume(let content) = card.content else { continue }
            for item in content.items where tracker.sessions.first(where: { $0.key == item.id })?.state == .waiting {
                if !keys.contains(item.id) { keys.append(item.id) }
            }
        }
        for key in newKeys where !keys.contains(key) { keys.append(key) }
        let rows: [ResumeItem] = keys.compactMap { key in
            if key.source == .shell, let facts = finishedCommands.removeValue(forKey: key) {
                return ResumeItem(id: key, facts: facts)
            }
            // A session working again has nothing to report (SPEC §3.5).
            guard let session = tracker.sessions.first(where: { $0.key == key }),
                  let facts = ResumeFacts.session(session, keepSnippets: settings.storePromptSnippets) else { return nil }
            return ResumeItem(id: key, facts: facts)
        }
        // Needs you first, then failures, then the rest, each in the order they happened.
        let items = rows.enumerated().sorted { ($0.element.facts.sortRank, $0.offset) < ($1.element.facts.sortRank, $1.offset) }.map(\.element)
        guard !items.isEmpty else { return }
        cards.removeAll { if case .resume = $0.content { return true } else { return false } }
        var content = ResumeCardContent(items: items)
        // The first real resume card carries a hint (SPEC §3.12); one that waits for you has its own.
        let lesson = HintPolicy.resumeLesson(needsYou: content.needsYou)
        if takeHint(lesson) {
            content.hint = lesson == .resumeNeedsYou
                ? HintCopy.resumeNeedsYou(dismissKey: settings.nudgeHotkeys ? HotKeyCombo.nudgeDismiss.display : nil)
                : HintCopy.resumeCard
        }
        cards.append(CardState(content: .resume(content), createdAt: now))
    }

    func showWindDownCard(now: Date) {
        guard !cards.contains(where: { if case .windDown = $0.content { return true } else { return false } }) else { return }
        windDown.cardVisible = true
        cards.append(CardState(content: .windDown(WindDownCardContent(
            now: now, stopTime: settings.stopTime, holdDuration: WindDownPolicy.holdDuration(windDown, settings: settings))),
            createdAt: now))
    }

    /// Ends the Undo window of the current decision. Cards are not timed here: each card's surface
    /// owns its lifetime (auto-hide, paused while hovered, restarted at half time; §3.0) and calls
    /// `dismissCard` when it is done, so a card someone is reading never disappears under them.
    private func expireCards(now: Date) {
        if let decision = currentDecision, !decision.isUndoable(at: now) {
            currentDecision = nil
        }
    }

    /// Seconds until the next break is due (≤ 0 = due).
    func nextBreakIn() -> TimeInterval {
        min(eyesIn(), moveIn(now: currentDate()))
    }

    func eyesIn() -> TimeInterval { settings.cadence.eyesEvery - timers.screenTime }

    /// Seconds until the stretch is due: still time against the cadence, or the end of the hold
    /// after a breather, whichever is later (§2.3).
    func moveIn(now: Date) -> TimeInterval {
        let byTimer = settings.cadence.moveEvery - timers.stillTime
        guard let held = stretchHeldUntil, now < held else { return byTimer }
        return max(byTimer, held.timeIntervalSince(now))
    }
}
