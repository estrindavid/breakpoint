import Foundation
import Testing
@testable import BreakpointCore

/// Whole stretches of a working day replayed second by second through the tracker, presence
/// accounting, pauses and the engine, sequenced as the app's loop does (`DaySimulator`). Each test
/// asserts what was offered and when, and that no offer broke a timing rule.
@Suite("Day scenarios (SPEC §1, §2.3–2.8)")
struct DayScenarioTests {
    let nine = Fixture.date(9)

    func sim(at start: Date? = nil, screen: Double = 0, still: Double = 0, settings: Settings = .defaults) -> DaySimulator {
        let s = DaySimulator(start: start ?? nine, settings: settings)
        s.timers = TimerState(screenTime: screen * 60, stillTime: still * 60)
        return s
    }

    // MARK: The typing guard

    @Test func aPromptSubmittedWithReturnIsOfferedTwoSecondsLater() throws {
        let s = sim(screen: 25, still: 10)
        s.run(.typing, minutes: 0.5)
        let submitted = s.now
        s.submitPrompt()
        #expect(s.offers.isEmpty)             // held: the Return key was just pressed
        s.run(.reading, minutes: 0.5)
        let offer = try #require(s.offers.first)
        #expect(s.offers.count == 1)
        #expect(offer.at == submitted.plus(seconds: 2))
        #expect(offer.offer.kind == .eyes && offer.offer.opportunity.kind == .agentStarted)
        #expect(Copy.nudgeSubtitle(for: offer.offer) == "Claude is working")
        #expect(s.violations().isEmpty)
    }

    @Test func typingStraightThroughTheOpportunityLetsItExpire() {
        let s = sim(screen: 25, still: 10)
        s.run(.typing, minutes: 0.5)
        s.submitPrompt()
        s.run(.typing, minutes: 0.6)          // keeps typing past the 30 s lifetime
        s.run(.reading, minutes: 2)
        #expect(s.offers.isEmpty)
        #expect(s.heldOpportunity == nil)
    }

    @Test func typingInBurstsHoldsUntilAQuietMoment() throws {
        let s = sim(screen: 25, still: 10)
        s.activity = .bursts(type: 10, read: 20)
        s.run(5)
        let submitted = s.now
        s.submitPrompt()
        s.run(minutes: 1)
        let offer = try #require(s.offers.first)
        // The burst goes on for 4 more seconds; the offer waits for 2 quiet seconds after it.
        #expect(offer.at.timeIntervalSince(submitted) == 6)
        #expect(offer.input.secondsSinceKey >= Timing.typingGuardKey)
        #expect(s.violations().isEmpty)
    }

    @Test func aTypingPauseOfferNeedsEightQuietSecondsAndAWellOverdueTimer() throws {
        let s = sim(screen: 29, still: 10)
        s.run(.bursts(type: 20, read: 40), minutes: 0.9)
        #expect(s.offers.isEmpty)             // 29.9 min: not yet 1.5 × 20
        s.run(minutes: 2)
        let offer = try #require(s.offers.first)
        #expect(offer.offer.opportunity.kind == .typingPause && offer.offer.kind == .eyes)
        #expect(offer.input.secondsSinceKey == Timing.typingPauseQuiet)
        #expect(Copy.nudgeSubtitle(for: offer.offer) == "30 min at the screen")
    }

    // MARK: Calls

    @Test func neverOfferedDuringACallAndOnlyAMinuteAfter() throws {
        let s = sim(screen: 31, still: 55)
        s.run(.typing, minutes: 1)
        s.setCall(.microphone)
        #expect(!s.pause.isPaused)                         // not a call yet: offers are only held
        s.submitPrompt()
        s.run(.reading, minutes: 1)
        #expect(s.pause.callSignals == .microphone)        // a minute on: now it is a call
        s.run(.bursts(type: 15, read: 45), minutes: 20)   // typing pauses during the call too
        s.submitPrompt()
        s.run(.reading, minutes: 1)
        #expect(s.offers.isEmpty)
        s.setCall([])
        let callEnded = s.now
        #expect(s.pause.cooldownUntil == callEnded.plus(seconds: 60))
        s.run(30)
        s.submitPrompt()                       // 30 s after the call: still cooling down
        s.run(.reading, minutes: 0.5)
        #expect(s.offers.isEmpty)
        s.submitPrompt()                       // 60 s after the call: the cool-down is over
        s.run(.reading, minutes: 1)
        let offer = try #require(s.offers.first)
        #expect(offer.at == callEnded.plus(seconds: 62))   // after the Return key's 2 s
        #expect(offer.offer.kind == .move)
        #expect(s.violations().isEmpty)
    }

    @Test func aDictatedPromptStillGetsItsOfferAndLeavesNoPause() throws {
        let s = sim(screen: 10, still: 55)
        s.run(.typing, minutes: 0.5)
        s.setCall(.microphone)                // the dictation tool turns the microphone on
        s.run(.idle, minutes: 0.2)            // 12 s of speaking
        s.submitPrompt()                      // Return, with the microphone still on
        s.run(1)
        #expect(s.offers.isEmpty)             // held while the microphone is on
        let off = s.now
        s.setCall([])
        s.run(.reading, minutes: 0.5)
        let offer = try #require(s.offers.first)
        #expect(offer.offer.kind == .move && offer.offer.opportunity.kind == .agentStarted)
        #expect(offer.at == off.plus(seconds: 1))   // the Return key's 2 s are already over
        #expect(s.pauseEnds.isEmpty && s.pause.cooldownUntil == nil)
        #expect(s.violations().isEmpty)
    }

    @Test func aMicrophoneComingOnStopsAnEyeRestCountdown() {
        let s = sim(screen: 25)
        s.respond = { _ in .ignore }
        s.submitPrompt()
        s.run(.idle, minutes: 0.05)                     // offered, the countdown is running
        #expect(s.nudge?.autoStartDeadline != nil)
        s.setCall(.microphone)                          // dictation starts: not a call, yet no break
        s.run(.idle, minutes: 0.5)
        #expect(s.breakSession == nil && s.ended.isEmpty)
        #expect(s.history.last?.outcome == .ignored)
        #expect(!s.pause.isPaused)
    }

    @Test func aCallWithdrawsAVisibleNudgeWithoutRecordingIt() {
        let s = sim(screen: 25)
        s.respond = { _ in .ignore }
        var settings = Settings()
        settings.autoStartEyes = false
        s.settings = settings
        s.submitPrompt()
        s.run(.reading, minutes: 0.05)
        #expect(s.nudge != nil)
        s.setCall(.camera)
        #expect(s.nudge == nil)
        #expect(s.history.isEmpty)
    }

    @Test func resumeNowDuringACallAllowsOffersAfterTheCoolDown() throws {
        let s = sim(screen: 25)
        s.setCall(.microphone)
        s.run(.reading, minutes: 1)
        s.resumeNow()
        #expect(!s.pause.isPaused && s.pause.ignoringCurrentCall)
        s.run(minutes: 1.1)
        s.submitPrompt()
        s.run(minutes: 0.2)
        #expect(s.offers.count == 1)
        #expect(s.violations().isEmpty)
    }

    // MARK: Away

    @Test func returningFromLunchResetsTimersAndNoBreakArrivesRightAway() throws {
        let s = sim(screen: 18, still: 45)
        s.run(.typing, minutes: 1)
        let left = s.now
        s.run(.idle, minutes: 50)
        #expect(s.presence.status == .away(since: left, cause: .idle))
        #expect(s.timers == TimerState(screenTime: 19 * 60, stillTime: 46 * 60))   // the idle minutes were removed
        s.run(.typing, minutes: 0.2)
        let decision = try #require(s.decisions.last)
        #expect(decision.kind == .timersReset(duration: 50 * 60 + 1))
        #expect(s.awayNotes.isEmpty)           // nothing was due: silent apart from the popover line
        s.submitPrompt()
        s.run(.reading, minutes: 2)
        #expect(s.offers.isEmpty)
        #expect(s.timers.stillTime < 3 * 60)
    }

    @Test func lunchCountsAsTheDueBreaksAndUndoBringsThemBack() throws {
        let s = sim(screen: 25, still: 55)
        s.respond = { _ in .decline }
        s.run(.idle, minutes: 40)
        s.run(.typing, minutes: 0.1)
        #expect(s.awayNotes.map(\.text) == ["Counted your 40 min away as a break"])
        #expect(s.history.filter { $0.outcome == .credited }.map(\.kind) == [.eyes, .move])
        // An agent starts 20 s after the return: cool-down, and nothing is due anyway.
        s.submitPrompt()
        s.run(.reading, minutes: 1.5)
        #expect(s.offers.isEmpty)
        // "I was here": Undo restores the timers as if present and removes the credits.
        s.undoLastDecision()
        #expect(s.history.filter { $0.outcome == .credited }.isEmpty)
        #expect(s.timers.stillTime > 95 * 60)
        s.submitPrompt()
        s.run(.reading, minutes: 0.2)
        #expect(s.offers.first?.offer.kind == .move)
        #expect(s.violations().isEmpty)
    }

    @Test func aShortLockRestsOnlyTheEyes() {
        let s = sim(screen: 22, still: 30)
        s.run(.typing, minutes: 0.5)
        s.presenceEvent(.locked)
        s.run(.idle, minutes: 0.7)
        s.presenceEvent(.unlocked)
        #expect(s.timers.screenTime == 0)
        #expect(s.timers.stillTime == 30.5 * 60)
        #expect(s.awayNotes.map(\.text) == ["Counted your 42 s away as a break"])
        #expect(s.pause.cooldownUntil == s.now.plus(seconds: 60))
    }

    // MARK: Presenting and watching

    @Test func whilePresentingOnlyAnAgentRunOffersAndNothingStartsByItself() throws {
        for mirrored in [true, false] {
            let s = sim(screen: 45, still: 10)          // well past 1.5 × the eye cadence
            s.respond = { _ in .ignore }
            if mirrored { s.displayMirrored = true } else { s.displaySleepPrevented = true }
            s.run(.bursts(type: 10, read: 50), minutes: 15)   // pauses in typing: nothing offered
            #expect(s.offers.isEmpty)
            s.submitPrompt()
            s.run(.idle, minutes: 0.5)
            let offer = try #require(s.offers.first)
            #expect(offer.offer.kind == .eyes && offer.offer.opportunity.kind == .agentStarted)
            #expect(s.breakSession == nil)               // a plain offer: it fades, nothing starts
            #expect(s.history.last?.outcome == .ignored)
            #expect(s.violations().isEmpty)
        }
    }

    @Test func theGuardComingOnStopsARunningCountdown() {
        let s = sim(screen: 25)
        s.respond = { _ in .ignore }
        s.submitPrompt()
        s.run(.idle, minutes: 0.05)                     // the countdown is running
        #expect(s.nudge?.autoStartDeadline != nil)
        s.displayMirrored = true                        // the laptop is plugged into a projector
        s.run(.idle, minutes: 0.5)
        #expect(s.breakSession == nil && s.ended.isEmpty)
        #expect(s.history.last?.outcome == .ignored)
    }

    @Test func watchingAVideoIsNotAway() {
        let s = sim(screen: 5, still: 5)
        s.displaySleepPrevented = true
        s.run(.idle, minutes: 20)
        #expect(!s.presence.status.isAway)
        #expect(s.timers.screenTime == 25 * 60)
        #expect(s.decisions.isEmpty)
    }

    // MARK: Agents and kinds

    @Test func aLongAgentRunIsOfferedAsAWalkAndTheWalkIsNotCountedTwice() throws {
        let s = sim(still: 55)
        for _ in 0..<3 { s.tracker.estimator.record(9 * 60, for: .codex) }
        s.walkBackAfter = 9.5 * 60
        s.submitPrompt(.codex)
        s.run(.reading, minutes: 15)
        let offer = try #require(s.offers.first)
        #expect(offer.offer.kind == .walk && offer.offer.length == 9 * 60)
        #expect(Copy.nudgeTitle(kind: offer.offer.kind, length: offer.offer.length) == "9-min walk?")
        #expect(Copy.whyNow(for: offer.offer) == "5 min overdue · Codex usually takes 9 min")
        #expect(s.ended == [DaySimulator.Ended(kind: .walk, start: offer.at.plus(seconds: 3), end: offer.at.plus(seconds: 3 + 570),
                                                outcome: .completed)])
        // The walk made the user idle for over 3 minutes; it still counts once.
        #expect(s.history.map(\.outcome) == [.completed])
        #expect(s.awayNotes.isEmpty)
        #expect(s.timers.stillTime < 6 * 60)
    }

    /// A reported case: a walk ended after a minute and a half left "since you moved" where it
    /// was, so the next offer came back minutes later. Still time now counts from the walk's end.
    @Test func aWalkEndedAfterNinetySecondsRestartsStillTime() throws {
        let s = sim(still: 55)
        for _ in 0..<3 { s.tracker.estimator.record(9 * 60, for: .codex) }
        s.walkBackAfter = 90
        s.submitPrompt(.codex)
        s.run(.reading, minutes: 1)
        let offer = try #require(s.offers.first)
        #expect(offer.offer.kind == .walk && offer.offer.length == 9 * 60)
        s.run(.reading, minutes: 3)
        let walk = try #require(s.ended.first)
        #expect(walk.outcome == .endedEarly && walk.end.timeIntervalSince(walk.start) == 90)
        #expect(s.timers.stillTime == s.now.timeIntervalSince(walk.end))
        // The next prompt ten minutes later is not met with another walk or stretch.
        s.send(.agentFinished, .codex)
        s.run(.reading, minutes: 10)
        s.submitPrompt(.codex)
        s.run(.reading, minutes: 5)
        #expect(s.offers.filter { $0.offer.kind != .eyes }.count == 1)
        #expect(s.violations().isEmpty)
    }

    @Test func breatheAfterTwoDeclinedStretches() throws {
        let s = sim(still: 55)
        s.respond = { $0.kind == .move ? .decline : .accept }
        var log: [BreakKind] = []
        for _ in 0..<3 {
            s.submitPrompt()
            s.run(.reading, minutes: 11)
            log = s.offers.map(\.offer.kind)
        }
        #expect(log == [.move, .move, .breathe])
        #expect(s.ended.last?.kind == .breathe && s.ended.last?.outcome == .completed)
        #expect(s.consecutiveMoveRefusals == 0)
        // breathe resets nothing: the stretch is still due, after the hold.
        #expect(s.timers.stillTime > 80 * 60)
        #expect(s.stretchHeldUntil == s.ended.last?.end.plus(minutes: 50))
        #expect(s.violations().isEmpty)
    }

    /// Not now on a stretch spaces the still slot for ten minutes from the click; nudge spacing
    /// ends ten minutes after the nudge appeared. Only in the seconds between the two may the
    /// other due kind come; after that the stretch is back.
    @Test func aDeclinedKindWaitsTenMinutesButAnotherDueKindMayCome() throws {
        let s = sim(screen: 25, still: 55)
        s.respond = { $0.kind == .move ? .decline : .accept }
        s.submitPrompt()                       // offered 2 s later, declined 3 s after that
        s.run(.reading, minutes: 5)
        let first = try #require(s.offers.first)
        s.submitPrompt()                       // 5 min later: nudge spacing (was enough before)
        s.run(.reading, minutes: 5)
        #expect(s.offers.count == 1)
        s.run(2)
        s.submitPrompt()                       // exactly 10 min after the first nudge
        s.run(.reading, minutes: 1)
        #expect(s.offers.map(\.offer.kind) == [.move, .eyes])
        #expect(s.offers[1].at.timeIntervalSince(first.at) >= Timing.nudgeSpacing)
        #expect(s.violations().isEmpty)
    }

    @Test func noTwoOffersWithinTenMinutes() throws {
        let s = sim(screen: 25, still: 55)
        s.respond = { _ in .decline }
        s.activity = .bursts(type: 10, read: 30)   // typing pauses, and a prompt every minute
        for _ in 0..<60 {
            s.submitPrompt()
            s.run(minutes: 1)
        }
        let gaps = zip(s.offers.dropFirst(), s.offers).map { $0.at.timeIntervalSince($1.at) }
        #expect(s.offers.count >= 5)
        #expect(gaps.allSatisfy { $0 >= Timing.nudgeSpacing }, "\(s.offerLog(since: self.nine))")
        #expect(s.violations().isEmpty, "\(s.violations())")
    }

    // MARK: A break the person started counts, however it ends (SPEC §2.3, §2.7)

    @Test func anEyeRestSkippedAtTwelveSecondsRestartsScreenTimeAndIsNotARefusal() throws {
        let s = sim(screen: 25, still: 10)
        s.skipAfter = 12
        s.submitPrompt()
        s.run(.reading, minutes: 1)
        let eyes = try #require(s.ended.first)
        #expect(eyes.kind == .eyes && eyes.outcome == .endedEarly)
        #expect(eyes.end.timeIntervalSince(eyes.start) == 12)
        #expect(s.timers.screenTime == s.now.timeIntervalSince(eyes.end))
        #expect(s.refusals.isEmpty && s.kindSpacedUntil.isEmpty)
        // Eleven minutes on, the eye rest is not due again (screen time counts from its end).
        s.run(.reading, minutes: 10)
        s.submitPrompt()
        s.run(.reading, minutes: 1)
        #expect(s.offers.count == 1)
        #expect(s.violations().isEmpty)
    }

    @Test func anEyeRestSkippedAsSoonAsSkipWorksStillCounts() throws {
        let s = sim(screen: 25, still: 10)
        s.skipAfter = Timing.skipGuard
        s.submitPrompt()
        s.run(.reading, minutes: 1)
        let eyes = try #require(s.ended.first)
        #expect(eyes.outcome == .endedEarly && eyes.end.timeIntervalSince(eyes.start) == Timing.skipGuard)
        #expect(s.timers.screenTime < 60)
        #expect(s.refusals.isEmpty)
        #expect(HistoryTotals.counting(s.history).eyeRests == 1)
        #expect(s.violations().isEmpty)
    }

    @Test func aStretchStoppedAtThirtySecondsRestartsBothTimers() throws {
        let s = sim(screen: 15, still: 55)
        s.consecutiveMoveRefusals = 1
        s.skipAfter = 30
        s.submitPrompt()
        s.run(.reading, minutes: 1)
        let stretch = try #require(s.ended.first)
        #expect(stretch.kind == .move && stretch.outcome == .endedEarly)
        #expect(s.timers == TimerState(screenTime: s.now.timeIntervalSince(stretch.end),
                                       stillTime: s.now.timeIntervalSince(stretch.end)))
        #expect(s.consecutiveMoveRefusals == 0 && s.refusals.isEmpty)
        let totals = HistoryTotals.counting(s.history)
        #expect(totals.stretches == 1 && totals.movingSeconds == 30)
        #expect(s.violations().isEmpty)
    }

    /// A day of someone who starts every break and leaves it as soon as Skip works: nothing is
    /// recorded as a refusal, the timers restart each time, and the rules hold.
    @Test func aDayOfShortBreaksNeverCountsAsRefusing() throws {
        let s = sim()
        s.skipAfter = Timing.skipGuard
        while s.now < Fixture.date(13) {
            s.run(.bursts(type: 20, read: 25), minutes: 3)
            s.agentRun(4)
        }
        #expect(s.ended.count >= 8, "\(s.offerLog(since: self.nine))")
        #expect(s.ended.allSatisfy { $0.outcome == .endedEarly })
        #expect(s.refusals.isEmpty)
        #expect(s.violations().isEmpty, "\(s.violations())")
    }

    /// A breather restarts nothing (it is done sitting down), but it is an answer: the stretch
    /// slot is held for one move cadence from its end, while eye rests still come when due
    /// (SPEC §2.3).
    @Test func afterABreatherNoStretchForAWholeCadence() throws {
        let s = sim(screen: 25, still: 55)
        s.respond = { $0.kind == .move ? .decline : .accept }
        for _ in 0..<3 {
            s.submitPrompt()
            s.run(.reading, minutes: 11)
        }
        #expect(s.offers.map(\.offer.kind) == [.move, .move, .breathe])
        let breather = try #require(s.ended.last)
        #expect(breather.kind == .breathe && breather.outcome == .completed)
        #expect(s.timers.stillTime > 80 * 60)                       // "since you moved" stays true
        let heldUntil = breather.end.plus(minutes: 50)
        #expect(s.stretchHeldUntil == heldUntil)
        for _ in 0..<60 {
            s.submitPrompt()
            s.run(.reading, minutes: 1)
            if s.now > breather.end.plus(minutes: 25), s.now < breather.end.plus(minutes: 29), s.nudge == nil,
               s.breakSession == nil {
                // Nothing else due: "Why not now?" names the hold and its end.
                let why = WhyNotNow.explain(s.snapshot(), held: nil, onBreak: false, now: s.now)
                if case .waiting = why {} else { #expect(why == .afterBreather(until: heldUntil)) }
            }
        }
        let after = s.offers.dropFirst(3)
        let held = after.filter { $0.at < heldUntil }
        #expect(!held.isEmpty && held.allSatisfy { $0.offer.kind == .eyes }, "\(s.offerLog(since: self.nine))")
        let next = try #require(after.first { $0.offer.kind != .eyes })
        #expect(next.offer.kind == .move)
        #expect(next.at >= heldUntil && next.at < heldUntil.plus(minutes: 1))
        #expect(s.violations().isEmpty, "\(s.violations())")
    }

    /// Someone who turns down every stretch and takes every breather: before the hold, an offer
    /// for the still-time slot came every ten minutes; now each breather buys a whole cadence.
    @Test func decliningStretchesForeverNoLongerMeansAnOfferEveryTenMinutes() throws {
        let s = sim(screen: 5, still: 55)
        s.respond = { $0.kind == .move ? .decline : .accept }
        for _ in 0..<(3 * 60) {
            s.submitPrompt()
            s.run(.reading, minutes: 1)
        }
        let slot = s.offers.filter { $0.offer.kind != .eyes }
        let breathers = slot.filter { $0.offer.kind == .breathe }
        #expect(breathers.count >= 2, "\(s.offerLog(since: self.nine))")
        // Three still-slot offers (stretch, stretch, breather) per cadence plus twenty minutes.
        #expect(slot.count <= 9, "\(s.offerLog(since: self.nine))")
        #expect(s.offers.count < 18, "\(s.offerLog(since: self.nine))")
        #expect(s.violations().isEmpty, "\(s.violations())")
    }

    // MARK: Saying no again and again (SPEC §2.4)

    /// Offers of one slot (`eyes`, or the still-time slot) in the order they came.
    func slotOffers(_ s: DaySimulator, eyes: Bool) -> [DaySimulator.Offered] {
        s.offers.filter { ($0.offer.kind == .eyes) == eyes }
    }

    /// An agent-heavy day (a prompt every minute, reading in between) from 09:00 for `hours`.
    func busyDay(_ s: DaySimulator, hours: Int) {
        for _ in 0..<(hours * 60) {
            s.submitPrompt()
            s.run(.reading, minutes: 1)
        }
    }

    /// Someone who says Not now to every offer all day: before, an offer came every ten minutes
    /// from morning to evening (47 in eight hours). From the third no in a row, each kind is asked
    /// about once per its cadence.
    @Test(arguments: [DaySimulator.Response.decline, .ignore])
    func sayingNoToEverythingIsAskedOncePerCadence(_ answer: DaySimulator.Response) throws {
        let s = sim(screen: 5, still: 30)
        s.respond = { _ in answer }
        busyDay(s, hours: 8)
        let cadence = Settings.defaults.cadence
        for (eyes, every) in [(true, cadence.eyesEvery), (false, cadence.moveEvery)] {
            let offers = slotOffers(s, eyes: eyes)
            let first = Timing.refusalsBeforeCadenceSpacing
            #expect(offers.count > first)
            let gaps = zip(offers.dropFirst(), offers).map { $0.at.timeIntervalSince($1.at) }
            // The first refusals wait ten minutes; every gap after the third waits a cadence.
            #expect(gaps.dropFirst(first - 1).allSatisfy { $0 >= every }, "\(s.offerLog(since: self.nine))")
        }
        #expect(slotOffers(s, eyes: false).count <= 12, "\(s.offerLog(since: self.nine))")
        #expect(s.offers.count <= 32, "\(s.offerLog(since: self.nine))")
        // Two ignored stretches lead to the breather as two declined ones do.
        #expect(slotOffers(s, eyes: false).prefix(3).map(\.offer.kind) == [.move, .move, .breathe])
        #expect(s.violations().isEmpty, "\(s.violations())")
    }

    /// Taking one break of a kind ends the longer spacing: the next no waits ten minutes again.
    @Test func takingABreakEndsTheLongerSpacing() throws {
        let s = sim(screen: 5, still: 10)
        s.respond = { $0.kind == .eyes ? .decline : .accept }
        busyDay(s, hours: 2)
        let before = slotOffers(s, eyes: true)
        #expect(before.count >= Timing.refusalsBeforeCadenceSpacing + 1)
        #expect(s.consecutiveEyeRefusals >= Timing.refusalsBeforeCadenceSpacing)
        // The next eye rest is taken; after it, a refusal spaces eye rests ten minutes only.
        s.respond = { _ in .accept }
        while s.ended.last?.kind != .eyes { s.submitPrompt(); s.run(.reading, minutes: 1) }
        #expect(s.consecutiveEyeRefusals == 0)
        s.respond = { $0.kind == .eyes ? .decline : .accept }
        let taken = try #require(s.ended.last)
        busyDay(s, hours: 1)
        let after = slotOffers(s, eyes: true).filter { $0.at > taken.end }
        #expect(after.count >= 2, "\(s.offerLog(since: self.nine))")
        #expect(after[1].at.timeIntervalSince(after[0].at) < Settings.defaults.cadence.eyesEvery)
        #expect(s.violations().isEmpty, "\(s.violations())")
    }

    /// The same for the still-time slot: after three noes, the stretch-slot break that is taken
    /// (whatever routine the rotation picks) clears the count, so the next no waits ten minutes.
    @Test func takingAStretchSlotBreakEndsTheLongerSpacing() throws {
        let s = sim(screen: 5, still: 30)
        var noes = 0
        s.respond = { offer in
            guard offer.kind != .eyes else { return .accept }
            noes += 1
            return noes <= Timing.refusalsBeforeCadenceSpacing ? .decline : .accept
        }
        busyDay(s, hours: 3)
        let taken = try #require(s.ended.last { $0.kind != .eyes })
        #expect(s.consecutiveMoveRefusals == 0)
        s.respond = { $0.kind == .eyes ? .accept : .decline }
        busyDay(s, hours: 2)
        let after = slotOffers(s, eyes: false).filter { $0.at > taken.end }
        #expect(after.count >= 2, "\(s.offerLog(since: self.nine))")
        #expect(after.prefix(2).map(\.offer.kind) == [.move, .move])    // not the breather
        #expect(after[1].at.timeIntervalSince(after[0].at) < Settings.defaults.cadence.moveEvery,
                "\(s.offerLog(since: self.nine))")
        #expect(s.violations().isEmpty, "\(s.violations())")
    }

    /// Lunch resets both timers, so the refusals of the morning no longer count: the first stretch
    /// of the afternoon is a stretch (not the breather), and a no waits ten minutes.
    @Test func timeAwayClearsTheRefusals() throws {
        let s = sim(screen: 5, still: 30)
        s.respond = { _ in .decline }
        busyDay(s, hours: 2)
        #expect(s.consecutiveMoveRefusals >= Timing.refusalsBeforeCadenceSpacing)
        s.run(.idle, minutes: 40)
        s.run(.typing, minutes: 0.1)
        #expect(s.consecutiveMoveRefusals == 0 && s.consecutiveEyeRefusals == 0)
        let back = s.now
        busyDay(s, hours: 1)
        let afternoon = s.offers.filter { $0.at > back && $0.offer.kind != .eyes }
        #expect(afternoon.first?.offer.kind == .move, "\(s.offerLog(since: self.nine))")
        #expect(s.violations().isEmpty, "\(s.violations())")
    }

    /// The presenting guard makes Breakpoint quieter, not deaf to refusals: someone whose
    /// keep-awake tool holds the display awake all day and lets every agent nudge go is asked about
    /// each kind once per its cadence too, never by a pause in typing.
    @Test func underAKeepAwakeToolIgnoredNudgesStillSpaceOffersByCadence() throws {
        let s = sim(screen: 5, still: 30)
        s.displaySleepPrevented = true
        s.respond = { _ in .ignore }
        busyDay(s, hours: 8)
        #expect(s.offers.allSatisfy { $0.offer.opportunity.kind != .typingPause })
        #expect(s.breakSession == nil && s.ended.isEmpty)        // no eye rest started by itself
        let cadence = Settings.defaults.cadence
        for (eyes, every) in [(true, cadence.eyesEvery), (false, cadence.moveEvery)] {
            let offers = slotOffers(s, eyes: eyes)
            let gaps = zip(offers.dropFirst(), offers).map { $0.at.timeIntervalSince($1.at) }
            #expect(offers.count > Timing.refusalsBeforeCadenceSpacing)
            #expect(gaps.dropFirst(Timing.refusalsBeforeCadenceSpacing - 1).allSatisfy { $0 >= every },
                    "\(s.offerLog(since: self.nine))")
        }
        #expect(s.offers.count <= 32, "\(s.offerLog(since: self.nine))")
        #expect(s.violations().isEmpty, "\(s.violations())")
    }

    /// An offer held while a microphone is on (dictation) was never shown, so it is never a
    /// refusal: nothing is recorded, the count of noes stays where it was, and the stretch comes as
    /// soon as the microphone goes off.
    @Test func anOfferHeldForTheMicrophoneIsNotANo() throws {
        let s = sim(screen: 5, still: 55)
        s.respond = { $0.kind == .move ? .decline : .accept }
        s.agentRun(11)
        #expect(s.consecutiveMoveRefusals == 1)
        s.setCall(.microphone)
        s.run(.idle, minutes: 0.2)
        s.submitPrompt()
        s.run(.idle, minutes: 0.3)                          // held, and still not a call
        #expect(s.heldOpportunity != nil && s.nudge == nil)
        #expect(s.refusals.count == 1 && s.consecutiveMoveRefusals == 1)
        let off = s.now
        s.setCall([])
        s.run(.reading, minutes: 0.5)
        let offer = try #require(s.offers.last)
        #expect(offer.at == off && offer.offer.kind == .move)  // at once, a second stretch (not the breather)
        #expect(s.consecutiveMoveRefusals == 2)
        #expect(s.violations().isEmpty, "\(s.violations())")
    }

    @Test func strictModeOnlyUsesAgentRunsAndLongCommands() throws {
        var strict = Settings()
        strict.strictAgentOnly = true
        let s = sim(screen: 35, still: 80, settings: strict)
        s.run(.bursts(type: 10, read: 50), minutes: 10)
        #expect(s.offers.isEmpty)
        s.send(.commandStarted, .shell, session: "4242", title: "swift")
        s.run(.reading, minutes: 1)
        let offer = try #require(s.offers.first)
        #expect(offer.offer.opportunity.kind == .longCommand)
        #expect(Copy.nudgeSubtitle(for: offer.offer) == "swift is running")
        #expect(offer.at.timeIntervalSince(s.now.plus(minutes: -1)) == 20)
    }

    @Test func eyeRestAutoStartIsCancelledByAKeyPress() throws {
        let s = sim(screen: 25)
        s.respond = { _ in .ignore }
        s.submitPrompt()
        s.run(.reading, minutes: 5 / 60)
        #expect(s.nudge?.autoStartDeadline != nil)
        s.run(.typing, minutes: 2 / 60)       // types 3 s into the countdown: reverts to an offer
        #expect(s.nudge != nil && s.nudge?.autoStartDeadline == nil)
        s.run(.reading, minutes: 0.5)
        #expect(s.breakSession == nil && s.ended.isEmpty)
        #expect(s.history.map(\.outcome) == [.ignored])
    }

    @Test func eyeRestAutoStartsWhenLeftAlone() throws {
        let s = sim(screen: 25)
        s.respond = { _ in .ignore }
        s.submitPrompt()
        s.run(.reading, minutes: 1)
        let offer = try #require(s.offers.first)
        #expect(s.ended == [DaySimulator.Ended(kind: .eyes, start: offer.at.plus(seconds: 10), end: offer.at.plus(seconds: 30),
                                                outcome: .completed)])
        #expect(s.timers.screenTime < 60)
    }

    @Test func needsYouWithdrawsTheNudgeAndAHeldOpportunityForAFinishedRunIsDropped() {
        let s = sim(screen: 25)
        s.respond = { _ in .ignore }
        s.submitPrompt()
        s.run(.reading, minutes: 3 / 60)
        #expect(s.nudge != nil)
        s.send(.agentNeedsUser, detail: "permission_prompt")
        #expect(s.nudge == nil && s.history.isEmpty)

        // A quick run finishes while the user is still typing: its opportunity is dropped.
        let t = sim(screen: 25)
        t.submitPrompt()
        t.run(.typing, minutes: 0.2)
        t.send(.agentFinished)
        t.run(.reading, minutes: 1)
        #expect(t.offers.isEmpty)
    }

    // MARK: Wind-down

    @Test func lateEveningWindDown() throws {
        var settings = Settings()
        settings.windDownEnabled = true
        let s = sim(at: Fixture.date(22, 45), screen: 5, still: 5, settings: settings)
        s.agentRun(5)                                         // ends 22:50
        #expect(s.windDownCards.isEmpty)
        s.run(until: Fixture.date(23, 5))
        s.agentRun(5)                                         // ends 23:10
        #expect(s.windDownCards.map(\.at) == [Fixture.date(23, 10)])
        #expect(s.windDownCards.last?.hold == 3)
        s.run(minutes: 2)
        s.windDownExtend()                                    // 23:12, snoozed until 23:27
        s.agentRun(8)                                         // ends 23:20: still snoozed
        #expect(s.windDownCards.count == 1)
        s.run(until: Fixture.date(23, 25))
        s.agentRun(5)                                         // ends 23:30
        #expect(s.windDownCards.count == 2 && s.windDownCards.last?.hold == 6)
        let note = s.windDownWrapUp()
        #expect(note == ["claude-code — do the thing"])
        #expect(s.pause.primaryReason == .windDownWrappedUp(until: Fixture.date(5, day: 23)))
        // Wrapped up: no more offers or cards tonight, even with breaks long overdue.
        let offersBefore = s.offers.count
        s.timers = TimerState(screenTime: 90 * 60, stillTime: 90 * 60)
        s.agentRun(3)
        s.run(.bursts(type: 10, read: 30), minutes: 20)
        #expect(s.offers.count == offersBefore && s.windDownCards.count == 2)
        // 05:00: a new day, the pause is over.
        s.run(.idle, minutes: 1)
        s.run(until: Fixture.date(5, 1, day: 23))
        #expect(!s.pause.isPaused)
    }

    // MARK: A whole day

    @Test func aRealisticWorkingDay() throws {
        let s = sim()
        var answers = 0
        // Accept most offers, decline every third, let eye rests start by themselves.
        s.respond = { offer in
            answers += 1
            if offer.kind == .eyes { return .ignore }
            return answers % 3 == 0 ? .decline : .accept
        }
        s.walkBackAfter = 7 * 60
        let runs: [Double] = [2, 4, 1, 6, 3, 9, 2, 5]
        var cycle = 0
        func workCycle() {
            s.run(.bursts(type: 20, read: 25), minutes: 3)    // composing the next prompt
            s.agentRun(runs[cycle % runs.count], cycle % 4 == 3 ? .codex : .claudeCode)
            cycle += 1
        }

        // Morning.
        while s.now < Fixture.date(10, 30) { workCycle() }
        let morningOffers = s.offers.count

        // A call: microphone and camera on, typing notes now and then.
        let callStarted = s.now
        s.setCall([.microphone, .camera])
        s.run(.bursts(type: 15, read: 60), minutes: 25)
        s.submitPrompt()                                     // an agent kicked off during the call
        s.run(.reading, minutes: 20)
        s.send(.agentFinished)
        s.setCall([])
        let callEnded = s.now
        #expect(s.offers.count == morningOffers)

        while s.now < Fixture.date(12, 30) { workCycle() }

        // Lunch away from the desk.
        let lunch = s.now
        s.run(.idle, minutes: 45)
        let back = s.now
        s.run(.typing, minutes: 0.1)
        #expect(s.returns.last?.period.start == lunch)
        #expect(s.timers.screenTime < 60 && s.timers.stillTime < 60)

        // Afternoon, with a long test run in the shell.
        while s.now < Fixture.date(15) { workCycle() }
        s.send(.commandStarted, .shell, session: "777", title: "swift")
        s.run(.reading, minutes: 4)
        s.send(.commandFinished, .shell, session: "777")
        while s.now < Fixture.date(17, 30) { workCycle() }

        // A short lock to grab a coffee, then on until early evening.
        s.presenceEvent(.locked)
        s.run(.idle, minutes: 4)
        s.presenceEvent(.unlocked)
        while s.now < Fixture.date(19) { workCycle() }

        let log = s.offerLog(since: Fixture.date(0))
        // Every rule held all day.
        #expect(s.violations().isEmpty, "\(s.violations())\n\(log.joined(separator: "\n"))")
        // Nothing during the call, its minute of cool-down, lunch, or the minute after lunch.
        for offer in s.offers {
            #expect(!(offer.at >= callStarted && offer.at < callEnded.plus(seconds: 60)), "\(log)")
            #expect(!(offer.at >= lunch && offer.at < back.plus(seconds: 60)), "\(log)")
        }
        // After the call, the overdue stretch comes at the first typing pause after the cool-down.
        let afterCall = try #require(s.offers.first { $0.at > callEnded })
        #expect(afterCall.offer.kind == .move)
        #expect(afterCall.at.timeIntervalSince(callEnded) >= Timing.resumeCooldown)
        #expect(afterCall.at.timeIntervalSince(callEnded) < 3 * 60)
        // Breaks happened through the day, and the timers never ran far past their cadence.
        let kinds = Set(s.offers.map(\.offer.kind))
        #expect(kinds.isSuperset(of: [.eyes, .move]), "\(log)")
        #expect(s.ended.filter { $0.outcome == .completed }.count >= 8, "\(log)")
        #expect(s.offers.contains { $0.offer.opportunity.kind == .longCommand } || s.timers.stillTime < 50 * 60, "\(log)")
        let taken = DaySummary.summarize(s.history, dayStart: Fixture.date(5), calendar: Fixture.calendar)
        #expect(taken.breaksTaken == s.ended.count + s.history.filter { $0.outcome == .credited }.count)
        // Agent opportunities dominate: a day of agent work rarely needs a typing-pause nudge.
        let agentDriven = s.offers.filter { $0.offer.opportunity.kind != .typingPause }.count
        #expect(agentDriven * 2 >= s.offers.count, "\(log)")
    }
}
