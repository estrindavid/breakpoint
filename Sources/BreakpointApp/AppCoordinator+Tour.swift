import AppKit
import BreakpointCore
import BreakpointKit

// The one-minute tour (SPEC §3.12): a rehearsal of one whole cycle with sample data on the real
// surfaces. `TourPolicy` (Core) decides where the tour goes; this file shows and removes the
// sample surfaces (a nudge, a break, a resume card, the popover) and ends the tour cleanly when
// something real happens. Nothing the tour shows is recorded, and none of it changes the timers.

extension AppCoordinator {
    // MARK: Starting

    /// Settings → General → Take the tour (or `--tour`): from the mark, at once.
    func replayTour() {
        guard TourPolicy.canReplay(realBreakShowing: breakSession != nil && !isTourBreak(breakSession)) else { return }
        settingsWindow?.close()
        startTour(.replay)
    }

    func startTour(_ origin: TourOrigin) {
        let now = currentDate()
        if tour != nil { endTour(.skipped, now: now) }
        // A real offer on screen gives way quietly (nothing recorded); it comes again later.
        if nudge != nil { withdrawNudge(now: now) }
        let state = TourPolicy.start(origin, now: now)
        tour = state
        rememberTourStatus(TourPolicy.status(during: state))
        recordSurface("tour started (\(origin.rawValue))")
        enterTourStep(state, from: nil, now: now)
        publish(now: now)
    }

    // MARK: Moving on

    func handleTour(_ input: TourInput) {
        guard let current = tour else { return }
        let now = currentDate()
        switch TourPolicy.apply(input, to: current) {
        case .ignored:
            return
        case .moved(let next):
            tour = next
            if next.step != current.step {
                rememberTourStatus(TourPolicy.status(during: next))
                learnFromTour(leaving: current.step, for: next.step)
            }
            enterTourStep(next, from: current, now: now)
        case .ended(let ending):
            endTour(ending, now: now)
        }
        publish(now: now)
    }

    /// Shows what the new step needs and removes what the old one left.
    private func enterTourStep(_ state: TourState, from previous: TourState?, now: Date) {
        guard state.step != previous?.step else { return }
        switch previous?.step {
        case .nudge?:
            if nudge?.isRehearsal == true, state.step != .breakScreen { endNudge(nil, now: now) }
        case .resumeCard?:
            cards.removeAll(where: \.isRehearsal)
        default:
            break
        }
        switch state.step {
        case .offer, .mark, .declined:
            break
        case .nudge:
            showTourNudge(now: now)
        case .breakScreen:
            startTourBreak(now: now)
        case .resumeCard:
            let facts = TourPolicy.sampleResume(agent: tourAgent)
            let key = SessionKey(source: .claudeCode, sessionID: "tour-sample")
            cards.append(CardState(content: .resume(ResumeCardContent(items: [ResumeItem(id: key, facts: facts)])),
                                   createdAt: now, isRehearsal: true))
        case .popover:
            showPopover()
        case .farewell:
            // The last card hangs from the mark, where the popover was.
            closePopover()
        }
    }

    /// Ends the tour: every sample surface goes, nothing is recorded, the ending is remembered.
    func endTour(_ ending: TourEnding, now: Date) {
        guard let current = tour else { return }
        tour = nil
        if nudge?.isRehearsal == true { endNudge(nil, now: now) }
        if isTourBreak(breakSession) {
            // Not `endBreak`: a rehearsal records nothing and leaves the timers alone.
            breakSession = nil
        }
        tourBreakID = nil
        cards.removeAll(where: \.isRehearsal)
        rememberTourStatus(TourPolicy.status(after: ending))
        recordSurface("tour ended: \(Self.describe(ending))")
        if TourPolicy.opensPopoverAfter(ending, origin: current.origin) {
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
        }
        publish(now: now)
    }

    /// Something real happened (SPEC §3.12): the rehearsal steps aside at once.
    func interruptTour(_ reason: TourInterruption, now: Date) {
        guard tour != nil else { return }
        endTour(.interrupted(reason), now: now)
    }

    // MARK: Sample surfaces

    /// The agent the sample is about: the first connected tool's, else Claude.
    var tourAgent: String {
        let connected = IntegrationID.allCases.filter { integrationStates[$0]?.hasBreakpointEntries == true }.map(\.source)
        return TourPolicy.sampleAgent(connected: connected)
    }

    private var tourAgentSource: AgentSource {
        IntegrationID.allCases.first { integrationStates[$0]?.hasBreakpointEntries == true && $0.source != .shell }?.source
            ?? .claudeCode
    }

    /// A real nudge card in its real place, with sample data: a shortened eye rest offered while
    /// the sample agent works. Never auto-starts and never times out.
    private func showTourNudge(now: Date) {
        let opportunity = Opportunity(kind: .agentStarted, source: tourAgentSource, sessionID: "tour-sample", createdAt: now,
                                      expiresAt: .distantFuture)
        let offer = BreakOffer(kind: .eyes, length: Timing.tourBreakLength, opportunity: opportunity)
        nudge = NudgeState(offer: offer, phase: .offer, title: Copy.nudgeTitle(kind: .eyes, length: Timing.tourBreakLength),
                           subtitle: Copy.nudgeSubtitle(for: offer), whyNow: TourCopy.nudgeWhyNow,
                           hotkeysEnabled: settings.nudgeHotkeys, isPreview: true, isRehearsal: true, shownAt: now)
        autoStartDeadline = nil
        autoStartBegan = nil
        scheduleTick(interval: 0.1)
    }

    /// The sample break on the real break screen: the user pressed Start. Its Skip guard, Esc
    /// twice and timer are the real ones; its agent chip is the sample agent's.
    private func startTourBreak(now: Date) {
        guard breakSession == nil else { return }
        endNudge(nil, now: now)
        let session = BreakSession(kind: .eyes, startedAt: now, plannedLength: Timing.tourBreakLength,
                                   copy: BreakCopyLibrary.variant(for: .eyes, rotation: 0, agentName: tourAgent))
        breakSession = session
        tourBreakID = session.id
        heldOpportunity = nil
    }

    func isTourBreak(_ session: BreakSession?) -> Bool {
        guard let session, let id = tourBreakID else { return false }
        return session.id == id
    }

    /// The overlay's chip during the sample break: still working, then done.
    func tourChip(_ session: BreakSession, now: Date) -> AgentChipState {
        let elapsed = session.elapsed(at: now)
        return TourPolicy.sampleAgentWorking(breakElapsed: elapsed)
            ? .working(agent: tourAgent, elapsed: TourPolicy.sampleRunElapsed(breakElapsed: elapsed))
            : .done(agent: tourAgent)
    }

    /// The tour as the screens show it.
    func tourPresentation() -> TourPresentation? {
        guard let tour else { return nil }
        return TourPresentation(step: tour.step, popoverPart: tour.popoverPart,
                                coach: TourCopy.coach(tour.step, part: tour.popoverPart, agent: tourAgent,
                                                      hotkeys: settings.nudgeHotkeys),
                                agent: tourAgent, hotkeysEnabled: settings.nudgeHotkeys)
    }

    // MARK: Memory

    private func rememberTourStatus(_ status: TourStatus) {
        guard settings.tourStatus != status else { return }
        settings.tourStatus = status
        saveSettings()
    }

    static func describe(_ ending: TourEnding) -> String {
        switch ending {
        case .declined: return "declined"
        case .skipped: return "skipped"
        case .finished: return "finished"
        case .interrupted(let reason): return "interrupted (\(reason.rawValue))"
        }
    }
}
