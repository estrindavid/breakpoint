import Foundation
@testable import BreakpointCore

/// Replays a working day second by second through the real Core policies, sequenced exactly as
/// `Sources/BreakpointApp/AppCoordinator+Loop.swift` sequences them (tick order, event handling,
/// presence, pauses, nudge and break lifecycles). Keep the two in step: this is how the loop's
/// judgement is tested without AppKit.
///
/// The simulated user is an input model (typing, reading, away …) plus a responder that answers
/// each nudge. Everything runs on a fake clock; nothing sleeps and nothing touches the disk.
final class DaySimulator {
    // MARK: The simulated user

    enum Activity: Equatable {
        /// A key every second.
        case typing
        /// Type for `type` seconds, then read (pointer only, every 5 s) for `read` seconds; repeat.
        case bursts(type: Int, read: Int)
        /// Pointer movement every 5 s, no keys (reading agent output).
        case reading
        /// No input at all (away from the desk, or watching without touching anything).
        case idle
    }

    enum Response: Equatable {
        case accept
        case decline
        /// Let the nudge time out (or, for an eye-rest auto-start, let it start).
        case ignore
    }

    struct Offered {
        let at: Date
        let offer: BreakOffer
        let input: InputSample
        let pause: PauseState
        let presence: PresenceStatus
        let callSignals: CallSignals
    }

    struct Ended: Equatable {
        let kind: BreakKind
        let start: Date
        let end: Date
        let outcome: BreakOutcome
    }

    // MARK: Clock and settings

    private(set) var now: Date
    let calendar = Fixture.calendar
    var settings: Settings {
        didSet { tracker.storePromptSnippets = settings.storePromptSnippets }
    }

    // MARK: Coordinator state (same names as AppCoordinator)

    var tracker = SessionTracker()
    var presence = PresenceTracker()
    var timers = TimerState.zero
    var pause = PauseState.none
    var detector = OpportunityDetector()
    var heldOpportunity: Opportunity?
    var lastNudgeAt: Date?
    var lastBreakEndedAt: Date?
    var kindSpacedUntil: [BreakKind: Date] = [:]
    var consecutiveMoveRefusals = 0
    var consecutiveEyeRefusals = 0
    var stretchHeldUntil: Date?
    var currentDecision: AutoDecision?
    var windDown: WindDownState
    var resumeWhileAway: [SessionKey] = []
    var lastSample: InputSample

    struct Nudge {
        let offer: BreakOffer
        var shownAt: Date
        var autoStartDeadline: Date?
        let response: Response
    }

    var nudge: Nudge?
    var breakSession: BreakSession?

    // MARK: Input model

    var activity: Activity = .typing {
        didSet { activityStartedAt = now }
    }
    private var activityStartedAt: Date
    private(set) var lastKeyAt: Date
    private(set) var lastInputAt: Date
    var displaySleepPrevented = false
    var displayMirrored = false
    private(set) var callSignals: CallSignals = []
    var microphoneGate = MicrophoneCallGate()

    // MARK: Behaviour of the simulated user

    /// How the user answers each nudge.
    var respond: (BreakOffer) -> Response = { _ in .accept }
    /// Seconds before the user clicks Start or Not now.
    var respondAfter: TimeInterval = 3
    /// For walks: seconds after the start when the user is back and presses I'm back.
    var walkBackAfter: TimeInterval?
    /// For every break (a walk only without `walkBackAfter`): seconds after the start when the
    /// user presses Skip (or Esc twice), once the Skip guard allows it (3 s).
    var skipAfter: TimeInterval?

    // MARK: What happened

    private(set) var offers: [Offered] = []
    private(set) var history: [HistoryEntry] = []
    private(set) var ended: [Ended] = []
    private(set) var awayNotes: [(at: Date, text: String)] = []
    private(set) var decisions: [AutoDecision] = []
    private(set) var resumeCards: [(at: Date, keys: [SessionKey])] = []
    private(set) var windDownCards: [(at: Date, hold: TimeInterval)] = []
    private(set) var returns: [(at: Date, period: AwayPeriod)] = []
    private(set) var pauseEnds: [Date] = []
    private(set) var refusals: [(at: Date, kind: BreakKind)] = []

    init(start: Date, settings: Settings = .defaults) {
        now = start
        self.settings = settings
        windDown = WindDownState(dayStart: BreakpointDay.start(of: start, calendar: Fixture.calendar))
        activityStartedAt = start
        lastKeyAt = start
        lastInputAt = start
        lastSample = InputSample(takenAt: start, secondsSinceKey: 0, secondsSinceAnyInput: 0)
    }

    // MARK: Driving the day

    /// Runs the clock for `seconds` with the current activity, one tick per second.
    func run(_ seconds: TimeInterval) {
        for _ in 0..<Int(seconds.rounded()) { tick() }
    }

    func run(minutes: Double) { run(minutes * 60) }

    /// Runs until the wall clock reads `date`.
    func run(until date: Date) {
        while now < date { tick() }
    }

    /// Runs with `activity` for `minutes`.
    func run(_ activity: Activity, minutes: Double) {
        self.activity = activity
        run(minutes: minutes)
    }

    /// The user presses Return on a prompt: a key press now, and the agent's `agentStarted`.
    func submitPrompt(_ source: AgentSource = .claudeCode, session: String = "s1", title: String = "do the thing") {
        lastKeyAt = now
        lastInputAt = now
        send(.agentStarted, source, session: session, title: title)
    }

    func send(_ kind: AgentEventKind, _ source: AgentSource = .claudeCode, session: String = "s1", title: String? = nil,
              detail: String? = nil, via: String? = nil) {
        handle(AgentEvent(kind: kind, source: source, sessionID: session, cwd: "/Users/dev/\(source.rawValue)",
                          title: title, detail: detail, via: via, timestamp: now))
    }

    /// A finished agent run of `minutes` while the user does `meanwhile`.
    func agentRun(_ minutes: Double, _ source: AgentSource = .claudeCode, session: String = "s1",
                  meanwhile: Activity = .reading) {
        submitPrompt(source, session: session)
        run(meanwhile, minutes: minutes)
        send(.agentFinished, source, session: session)
    }

    func setCall(_ signals: CallSignals) {
        callSignals = signals
        tick0(dt: 0)   // the monitor's change callback runs the loop at once
    }

    func presenceEvent(_ event: PresenceEvent) {
        handlePresenceEvent(event)
    }

    func resumeNow() {
        let before = pause
        pause = PausePolicy.resumeNow(pause, now: now)
        notePauseChange(before)
    }

    func undoLastDecision() {
        guard let decision = currentDecision, decision.isUndoable(at: now) else { return }
        timers = AwayPolicy.undo(decision, current: timers)
        let ids = Set(decision.historyEntryIDs)
        history.removeAll { ids.contains($0.id) }
        currentDecision = nil
    }

    func windDownExtend() { windDown = WindDownPolicy.extend(windDown, now: now) }

    func windDownWrapUp() -> [String] {
        windDown = WindDownPolicy.wrapUp(windDown, now: now)
        let before = pause
        pause = PausePolicy.wrapUp(pause, now: now, calendar: calendar)
        notePauseChange(before)
        withdrawNudge()
        return WindDownPolicy.wrapUpNote(sessions: tracker.sessionsByUrgency)
    }

    // MARK: Tick (AppCoordinator.tick)

    private func tick() {
        now = now.addingTimeInterval(1)
        applyInputModel()
        tick0()
    }

    /// The loop body at the current time.
    private func tick0(dt: TimeInterval = 1) {
        windDown = WindDownPolicy.rolledOver(windDown, now: now, calendar: calendar)

        let sample = currentSample()
        lastSample = sample
        let callActive = !callSignals.filtered(by: settings).isEmpty
        // This tick's dt has not accrued yet, so a retroactive away start removes that much less.
        handlePresenceChanges(presence.ingest(sample, callActive: callActive, settings: settings), unaccrued: dt)

        timers = ActivityClock.advance(timers, sample: sample, presence: presence.status, dt: dt)

        updatePause()
        apply(tracker.expire(now: now))
        if breakSession != nil { advanceBreak() }
        advanceNudge(sample)

        for opportunity in detector.evaluate(snapshot(), now: now) { evaluate(opportunity) }
        if let held = heldOpportunity { evaluate(held) }

        if let decision = currentDecision, !decision.isUndoable(at: now) { currentDecision = nil }
    }

    /// What the activity monitor would read now.
    private func currentSample() -> InputSample {
        InputSample(takenAt: now, secondsSinceKey: now.timeIntervalSince(lastKeyAt),
                    secondsSinceAnyInput: now.timeIntervalSince(lastInputAt),
                    secondsSinceDrag: 600, mouseButtonDown: false,
                    displaySleepPrevented: displaySleepPrevented, displayMirrored: displayMirrored)
    }

    private func applyInputModel() {
        guard breakSession == nil else { return }   // on a break, away from the keyboard
        let elapsed = Int(now.timeIntervalSince(activityStartedAt))
        switch activity {
        case .typing:
            lastKeyAt = now
            lastInputAt = now
        case .bursts(let type, let read):
            if elapsed % (type + read) < type {
                lastKeyAt = now
                lastInputAt = now
            } else if elapsed % 5 == 0 {
                lastInputAt = now
            }
        case .reading:
            if elapsed % 5 == 0 { lastInputAt = now }
        case .idle:
            break
        }
    }

    // MARK: Engine (AppCoordinator.snapshot / evaluate)

    func snapshot() -> EngineSnapshot {
        EngineSnapshot(settings: settings, timers: timers, presence: presence.status, input: lastSample, pause: pause,
                       surfaceVisible: nudge != nil || breakSession != nil, lastNudgeAt: lastNudgeAt,
                       lastBreakEndedAt: lastBreakEndedAt, kindSpacedUntil: kindSpacedUntil,
                       consecutiveMoveRefusals: consecutiveMoveRefusals, stretchHeldUntil: stretchHeldUntil,
                       sessions: tracker.sessions,
                       commands: tracker.commands, expectedRunLengths: tracker.estimator.expectedRunLengths,
                       microphonePending: microphoneGate.isPending(callSignals.filtered(by: settings), at: now))
    }

    private func evaluate(_ opportunity: Opportunity) {
        if opportunity.isExpired(at: now) {
            if heldOpportunity?.id == opportunity.id { heldOpportunity = nil }
            return
        }
        switch BreakEngine.decide(snapshot(), opportunity: opportunity, now: now) {
        case .offer(let offer):
            heldOpportunity = nil
            showNudge(offer)
        case .hold:
            heldOpportunity = opportunity
        case .suppress, .nothing:
            if heldOpportunity?.id == opportunity.id { heldOpportunity = nil }
        }
    }

    // MARK: Nudge lifecycle

    private func showNudge(_ offer: BreakOffer) {
        let autoStart = offer.kind == .eyes && settings.autoStartEyes
            && AutoStartRules.allows(lastSample, microphonePending: snapshot().microphonePending)
        nudge = Nudge(offer: offer, shownAt: now,
                      autoStartDeadline: autoStart ? now.addingTimeInterval(Timing.autoStartCountdown) : nil,
                      response: respond(offer))
        lastNudgeAt = now
        offers.append(Offered(at: now, offer: offer, input: lastSample, pause: pause, presence: presence.status,
                              callSignals: callSignals))
    }

    private func endNudge(_ outcome: BreakOutcome?) {
        guard let current = nudge else { return }
        nudge = nil
        guard let outcome else { return }
        let offer = current.offer
        history.append(HistoryEntry(kind: offer.kind, outcome: outcome, opportunityKind: offer.opportunity.kind,
                                    source: offer.opportunity.source, start: current.shownAt))
        if outcome == .declined || outcome == .ignored {
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
            refusals.append((now, offer.kind))
        }
    }

    private func withdrawNudge() { endNudge(nil) }

    /// The nudge controller's timers and the user's clicks (the break screens in the app).
    private func advanceNudge(_ sample: InputSample) {
        guard var current = nudge else { return }
        let shownFor = now.timeIntervalSince(current.shownAt)
        if let deadline = current.autoStartDeadline {
            // A key press, click or scroll after the countdown began cancels it, and so do the
            // presenting guard and a microphone coming on (§3.1).
            if AutoStartRules.cancels(sample, runningFor: shownFor, microphonePending: snapshot().microphonePending) {
                if deadline.timeIntervalSince(now) <= Timing.autoStartChipAt {
                    endNudge(.ignored)
                } else {
                    current.autoStartDeadline = nil
                    current.shownAt = now   // reverts to an offer that stays 10 s
                    nudge = current
                }
                return
            }
            if current.response == .decline, shownFor >= respondAfter { endNudge(.declined); return }
            if current.response == .accept, shownFor >= respondAfter {
                startBreak(current.offer.kind, opportunity: current.offer.opportunity, length: current.offer.length)
                return
            }
            if now >= deadline {
                startBreak(current.offer.kind, opportunity: current.offer.opportunity, length: current.offer.length)
            }
            return
        }
        switch current.response {
        case .accept where shownFor >= respondAfter:
            startBreak(current.offer.kind, opportunity: current.offer.opportunity, length: current.offer.length)
        case .decline where shownFor >= respondAfter:
            endNudge(.declined)
        default:
            if shownFor >= Timing.nudgeIgnoreAfter { endNudge(.ignored) }
        }
    }

    // MARK: Break lifecycle

    private func startBreak(_ kind: BreakKind, opportunity: Opportunity?, length: TimeInterval?) {
        guard breakSession == nil else { return }
        endNudge(nil)
        let source = opportunity?.sessionKey.flatMap { key in tracker.sessions.first { $0.key == key } }
        var session = BreakSessionRules.makeSession(kind: kind, opportunity: opportunity, settings: settings,
                                                    expectedRun: source.map { tracker.expectedRunLength(for: $0.source) },
                                                    agentName: source?.displayName, copyRotation: 0, now: now)
        if let length, kind == .walk { session.plannedLength = length }
        breakSession = session
        heldOpportunity = nil
    }

    private func advanceBreak() {
        guard var session = breakSession else { return }
        session = BreakSessionRules.advanced(session, now: now)
        breakSession = session
        if session.kind == .walk, let back = walkBackAfter, session.elapsed(at: now) >= back {
            lastInputAt = now
            lastKeyAt = now
            endBreak(.finish(.imBack))
        } else if let skip = skipAfter, session.elapsed(at: now) >= skip, BreakSessionRules.isSkipEnabled(session, now: now) {
            endBreak(.skip)
        } else if BreakSessionRules.timerEnded(session, now: now) {
            endBreak(.timerEnded)
        } else if BreakSessionRules.hitCeiling(session, now: now) {
            endBreak(.ceiling)
        }
    }

    private func endBreak(_ end: BreakEnd) {
        guard let session = breakSession else { return }
        breakSession = nil
        lastBreakEndedAt = now
        let outcome = BreakSessionRules.outcome(for: end, session: session, now: now)
        history.append(HistoryEntry(kind: session.kind, outcome: outcome, opportunityKind: session.opportunity?.kind ?? .manual,
                                    source: session.opportunity?.source, start: session.startedAt,
                                    duration: session.elapsed(at: now)))
        ended.append(Ended(kind: session.kind, start: session.startedAt, end: now, outcome: outcome))
        let before = timers
        timers = ActivityClock.afterBreak(timers, kind: session.kind, outcome: outcome)
        if timers != before { currentDecision = nil }
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
        // Back from the break: the user returns to the keyboard.
        lastInputAt = now
    }

    // MARK: Agent events (AppCoordinator.handle / apply)

    private func handle(_ event: AgentEvent) {
        // A fresh sample: the Return key that submitted the prompt must hold the opportunity.
        lastSample = currentSample()
        let update = tracker.apply(event, now: now)
        apply(update)
        if let opportunity = update.opportunity { evaluate(opportunity) }
    }

    private func apply(_ update: TrackerUpdate) {
        for transition in update.transitions {
            switch transition {
            case .needsUser(let key):
                dropHeld(for: key)
                withdrawNudge()
                if breakSession != nil {
                    breakSession?.needsYou = true
                    if breakSession?.sessionsToResume.contains(key) == false { breakSession?.sessionsToResume.append(key) }
                } else if presence.status.isAway, !resumeWhileAway.contains(key) {
                    resumeWhileAway.append(key)
                }
            case .runEnded(let key, let ending):
                dropHeld(for: key)
                if ending != .cancelled {
                    if breakSession != nil {
                        if breakSession?.sessionsToResume.contains(key) == false { breakSession?.sessionsToResume.append(key) }
                    } else if presence.status.isAway, !resumeWhileAway.contains(key) {
                        resumeWhileAway.append(key)
                    }
                    if WindDownPolicy.shouldOfferCard(windDown, settings: settings, now: now, calendar: calendar) {
                        windDown.cardVisible = true
                        windDownCards.append((now, WindDownPolicy.holdDuration(windDown, settings: settings)))
                    }
                }
            case .sessionEnded(let key):
                dropHeld(for: key)
            case .commandFinished(let command, _):
                if heldOpportunity?.kind == .longCommand, heldOpportunity?.sessionID == command.shellPID { heldOpportunity = nil }
            case .sessionStarted, .runStarted, .resumedWorking, .commandStarted:
                break
            }
        }
    }

    private func dropHeld(for key: SessionKey) {
        if heldOpportunity?.sessionKey == key { heldOpportunity = nil }
    }

    // MARK: Presence (AppCoordinator.handlePresenceEvent / handlePresenceChanges)

    private func handlePresenceEvent(_ event: PresenceEvent) {
        handlePresenceChanges(presence.ingest(event, at: now))
        if event == .unlocked || event == .systemDidWake || event == .displaysWoke {
            pause = PausePolicy.startCooldown(pause, now: now)
        }
    }

    private func handlePresenceChanges(_ changes: [PresenceChange], unaccrued: TimeInterval = 0) {
        for change in changes {
            switch change {
            case .becameAway(_, _, let retroactive):
                timers = ActivityClock.removingAccrual(timers, seconds: max(0, retroactive - unaccrued))
                withdrawNudge()
                heldOpportunity = nil
            case .returned(var period):
                returns.append((now, period))
                if breakSession == nil {
                    if let ended = lastBreakEndedAt, ended > period.start { period.start = min(ended, period.end) }
                    let resolution = AwayPolicy.resolve(period, timers: timers, settings: settings, now: now)
                    if resolution.timers.stillTime < timers.stillTime { consecutiveMoveRefusals = 0 }
                    if resolution.timers.screenTime < timers.screenTime { consecutiveEyeRefusals = 0 }
                    timers = resolution.timers
                    history.append(contentsOf: resolution.creditedEntries)
                    if let decision = resolution.decision {
                        currentDecision = decision
                        decisions.append(decision)
                        if resolution.showsAwayNote { awayNotes.append((now, decision.sentence)) }
                    }
                }
                pause = PausePolicy.startCooldown(pause, now: now)
                if !resumeWhileAway.isEmpty {
                    resumeCards.append((now, resumeWhileAway))
                    resumeWhileAway.removeAll()
                }
            }
        }
    }

    // MARK: Pauses

    private func updatePause() {
        let before = pause
        microphoneGate.observe(callSignals, at: now)
        pause = PausePolicy.update(pause, callSignals: microphoneGate.counted(callSignals, at: now),
                                   settings: settings, now: now)
        notePauseChange(before)
        if pause.isPaused && !before.isPaused || (pause.callSignals != nil && before.callSignals == nil) {
            withdrawNudge()
        }
    }

    private func notePauseChange(_ before: PauseState) {
        if before.isPaused, !pause.isPaused { pauseEnds.append(now) }
    }

    // MARK: Invariants (SPEC §1 principle 1, §2.4, §11 item 1)

    /// Every offer of the day obeyed the timing rules. Returns a description of each violation.
    func violations() -> [String] {
        var problems: [String] = []
        var previous: Date?
        for o in offers {
            let t = o.at
            func fail(_ message: String) { problems.append("\(t): \(message)") }
            if o.input.isTyping { fail("offered while typing") }
            if o.input.isPointerBusy { fail("offered while dragging") }
            if o.pause.isPaused { fail("offered while paused") }
            if !o.callSignals.filtered(by: settings).isEmpty, !o.pause.ignoringCurrentCall { fail("offered during a call") }
            if o.presence.isAway { fail("offered while away") }
            if let back = returns.last(where: { $0.at <= t }), t.timeIntervalSince(back.at) < Timing.resumeCooldown {
                fail("offered \(t.timeIntervalSince(back.at)) s after returning")
            }
            if let end = pauseEnds.last(where: { $0 <= t }), t.timeIntervalSince(end) < Timing.resumeCooldown {
                fail("offered \(t.timeIntervalSince(end)) s after a pause ended")
            }
            if let previous, t.timeIntervalSince(previous) < Timing.nudgeSpacing {
                fail("offered \(t.timeIntervalSince(previous)) s after the previous nudge")
            }
            if let lastEnd = ended.last(where: { $0.end <= t }), t.timeIntervalSince(lastEnd.end) < Timing.nudgeSpacing {
                fail("offered \(t.timeIntervalSince(lastEnd.end)) s after a break ended")
            }
            let slot = BreakEngine.spacingSlot(o.offer.kind)
            if let refusal = refusals.last(where: { $0.at <= t && slot.contains($0.kind) }),
               t.timeIntervalSince(refusal.at) < Timing.kindSpacing {
                fail("\(o.offer.kind) offered \(t.timeIntervalSince(refusal.at)) s after its slot was refused")
            }
            if o.offer.opportunity.isExpired(at: t) { fail("offered on an expired opportunity") }
            previous = t
        }
        // A break the person started counts, however briefly it ran: never a refusal.
        for e in ended where e.outcome != .completed && e.outcome != .endedEarly {
            problems.append("\(e.end): a started \(e.kind) was recorded as \(e.outcome)")
        }
        // After a breather, no stretch, walk or breather for a whole move cadence (SPEC §2.3).
        for o in offers where o.offer.kind != .eyes {
            if let breather = ended.last(where: { $0.kind == .breathe && $0.end <= o.at }),
               !ended.contains(where: { ($0.kind == .move || $0.kind == .walk) && $0.end > breather.end && $0.end <= o.at }),
               o.at.timeIntervalSince(breather.end) < settings.cadence.moveEvery {
                problems.append("\(o.at): \(o.offer.kind) offered \(o.at.timeIntervalSince(breather.end)) s after a breather")
            }
        }
        return problems
    }

    /// Offers as (minutes since `start`, kind), for compact assertions.
    func offerLog(since start: Date) -> [String] {
        offers.map { "\(Self.clock($0.at.timeIntervalSince(start))) \($0.offer.kind.rawValue) \($0.offer.opportunity.kind.rawValue)" }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
