import Foundation
import Testing
@testable import BreakpointCore

/// "Why not now?" (SPEC §3.7, §3.8): the line follows the engine's own decision order and says
/// it in the app's words.
@Suite("Why not now")
struct WhyNotNowTests {
    let now = Fixture.date(14)

    func line(_ reason: WaitReason) -> String {
        Copy.whyNotNow(reason, now: now, locale: Fixture.posix, timeZone: Fixture.utc)
    }

    func session(_ source: AgentSource, _ state: AgentState, id: String = "s1") -> AgentSession {
        AgentSession(key: SessionKey(source: source, sessionID: id), state: state, createdAt: now.plus(minutes: -10),
                     lastEventAt: now.plus(minutes: -1))
    }

    func typingInput(_ secondsSinceKey: TimeInterval) -> InputSample {
        InputSample(takenAt: now, secondsSinceKey: secondsSinceKey, secondsSinceAnyInput: min(1, secondsSinceKey),
                    secondsSinceDrag: 30)
    }

    @Test func nothingDueNamesTheNextBreak() {
        let snapshot = Make.snapshot(at: now, screen: 8 * 60, still: 10 * 60)
        let reason = WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)
        #expect(reason == .nothingDue(next: .eyes, in: 12 * 60))
        #expect(line(reason) == "Nothing due: eye rest in 12 min")
        #expect(!reason.explainsADueBreak)
        let stretch = WhyNotNow.explain(Make.snapshot(at: now, screen: 2 * 60, still: 47 * 60 + 10), held: nil, onBreak: false, now: now)
        #expect(line(stretch) == "Nothing due: stretch in 3 min")
    }

    @Test func surfacesPausesAndAwayComeFirst() {
        var snapshot = Make.snapshot(at: now, screen: 25 * 60, still: 55 * 60)
        #expect(WhyNotNow.explain(snapshot, held: nil, onBreak: true, now: now) == .onBreak)
        snapshot.surfaceVisible = true
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Offering a break now")
        snapshot.surfaceVisible = false
        snapshot.pause = PauseState(reasons: [.call(.microphone)])
        let paused = WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)
        #expect(line(paused) == "Paused: microphone is on")
        #expect(!paused.explainsADueBreak)
        snapshot.pause = .none
        snapshot.presence = .away(since: now.plus(minutes: -5), cause: .idle)
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Waiting for you to come back")
    }

    @Test func coolDownsAndSpacingGiveTheirEnd() {
        var snapshot = Make.snapshot(at: now, screen: 25 * 60, still: 55 * 60)
        snapshot.pause.cooldownUntil = now.plus(seconds: 40)
        let cooling = WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)
        #expect(cooling == .easingBackIn(until: now.plus(seconds: 40)))
        #expect(line(cooling) == "Easing back in after a pause: next nudge from 14:00")
        #expect(cooling.explainsADueBreak)

        snapshot.pause.cooldownUntil = nil
        snapshot.lastNudgeAt = now.plus(minutes: -7)
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Spacing out nudges: next one from 14:03")

        snapshot.lastNudgeAt = now.plus(minutes: -11)
        snapshot.kindSpacedUntil = [.move: now.plus(minutes: 4), .eyes: now.plus(minutes: 8)]
        let spaced = WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)
        #expect(spaced == .spacingKind(.move, until: now.plus(minutes: 4)))
        #expect(line(spaced) == "Spacing out stretches: next one from 14:04")

        // Only the stretch is spaced: the eye rest is what the next opportunity offers.
        snapshot.kindSpacedUntil = [.walk: now.plus(minutes: 4)]
        let waiting = WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)
        guard case .waiting(let facts) = waiting else { Issue.record("\(waiting)"); return }
        #expect(facts.due == .eyes)
    }

    @Test func afterABreatherItNamesTheHoldAndItsEnd() {
        var snapshot = Make.snapshot(at: now, screen: 5 * 60, still: 70 * 60)
        snapshot.stretchHeldUntil = now.plus(minutes: 40)
        let held = WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)
        #expect(held == .afterBreather(until: now.plus(minutes: 40)))
        #expect(line(held) == "You took a breather: next stretch from 14:40")
        #expect(held.explainsADueBreak)
        // A later kind spacing on the slot is the one that decides.
        snapshot.kindSpacedUntil = [.move: now.plus(minutes: 45)]
        #expect(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now) == .spacingKind(.move, until: now.plus(minutes: 45)))
        // An eye rest that is due is still offered during the hold.
        snapshot.kindSpacedUntil = [:]
        snapshot.timers.screenTime = 25 * 60
        guard case .waiting(let facts) = WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now) else {
            Issue.record("expected waiting"); return
        }
        #expect(facts.due == .eyes)
        // Over: the stretch is waiting for an opportunity again.
        snapshot.stretchHeldUntil = now
        guard case .waiting(let after) = WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now) else {
            Issue.record("expected waiting"); return
        }
        #expect(after.due == .move)
    }

    @Test func aHeldOpportunityIsHoldingTheNudge() {
        var snapshot = Make.snapshot(at: now, screen: 25 * 60, still: 55 * 60, input: typingInput(1))
        let held = Make.opportunity(.agentStarted, source: .claudeCode, session: "s1", at: now.plus(seconds: -1))
        let holding = WhyNotNow.explain(snapshot, held: held, onBreak: false, now: now)
        #expect(holding == .holding(.typing))
        #expect(line(holding) == "Holding the nudge: you are typing")
        snapshot.input = InputSample(takenAt: now, secondsSinceKey: 30, secondsSinceAnyInput: 0, secondsSinceDrag: 0.2)
        #expect(line(WhyNotNow.explain(snapshot, held: held, onBreak: false, now: now)) == "Holding the nudge: you are clicking or dragging")
        // Quiet again: the next tick offers it.
        snapshot.input = Make.quiet(at: now)
        #expect(WhyNotNow.explain(snapshot, held: held, onBreak: false, now: now) == .offering)
        // An expired hold is no longer what the engine decides on.
        let old = Make.opportunity(.agentStarted, at: now.plus(seconds: -40))
        snapshot.input = typingInput(1)
        guard case .waiting = WhyNotNow.explain(snapshot, held: old, onBreak: false, now: now) else {
            Issue.record("expired hold still explained as holding"); return
        }
    }

    @Test func aMicrophoneOnHoldsTheNudge() {
        var snapshot = Make.snapshot(at: now, screen: 25 * 60, still: 55 * 60)
        snapshot.microphonePending = true
        let held = Make.opportunity(.agentStarted, source: .claudeCode, session: "s1", at: now.plus(seconds: -3))
        let holding = WhyNotNow.explain(snapshot, held: held, onBreak: false, now: now)
        #expect(holding == .holding(.microphone))
        #expect(line(holding) == "Holding the nudge: a microphone is on")
        #expect(holding.explainsADueBreak)
    }

    /// Holds and the presenting guard come before the timers in the engine, but when every due
    /// kind is spaced (here a whole cadence after the third no in a row) the spacing is the answer:
    /// nothing would be offered once the microphone goes off or the person stops typing.
    @Test func spacingOutlastsAHoldThatHasNothingToHold() {
        let until = now.plus(minutes: 50)
        var snapshot = Make.snapshot(at: now, screen: 5 * 60, still: 55 * 60)
        snapshot.kindSpacedUntil = [.breathe: until]
        snapshot.microphonePending = true
        let held = Make.opportunity(.agentStarted, source: .claudeCode, session: "s1", at: now.plus(seconds: -3))
        for opportunity in [held, nil] {
            #expect(WhyNotNow.explain(snapshot, held: opportunity, onBreak: false, now: now) == .spacingKind(.move, until: until))
        }
        snapshot.microphonePending = false
        snapshot.input = typingInput(1)
        #expect(line(WhyNotNow.explain(snapshot, held: held, onBreak: false, now: now)) == "Spacing out stretches: next one from 14:50")
        // A held typing pause the presenting guard now drops, with stretches spaced: the same.
        snapshot.input = Make.quiet(at: now)
        snapshot.input.displayMirrored = true
        snapshot.timers.stillTime = 80 * 60
        let pause = Make.opportunity(.typingPause, at: now.plus(seconds: -2))
        #expect(WhyNotNow.explain(snapshot, held: pause, onBreak: false, now: now) == .spacingKind(.move, until: until))
        // An eye rest that is due and not spaced: the hold is named again.
        snapshot.input = Make.quiet(at: now)
        snapshot.microphonePending = true
        snapshot.timers.screenTime = 25 * 60
        #expect(WhyNotNow.explain(snapshot, held: held, onBreak: false, now: now) == .holding(.microphone))
    }

    @Test func presentingNamesTheGuardOnlyWhenItChangesTheAnswer() {
        // Well overdue: a pause in typing would offer it, but the display is kept awake.
        var snapshot = Make.snapshot(at: now, screen: 5 * 60, still: 80 * 60, input: typingInput(20))
        snapshot.input.displaySleepPrevented = true
        snapshot.sessions = [session(.claudeCode, .idle)]
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now))
                == "Waiting for an agent run: Claude is idle and the display is kept awake")
        snapshot.input.displayMirrored = true
        snapshot.sessions = [session(.claudeCode, .working)]
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now))
                == "Waiting for your next prompt: Claude is working and a display is mirrored")
        snapshot.sessions = []
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now))
                == "Waiting for an agent run: a display is mirrored")
        // A held typing pause that the guard now drops reads the same.
        let pause = Make.opportunity(.typingPause, at: now.plus(seconds: -2))
        #expect(line(WhyNotNow.explain(snapshot, held: pause, onBreak: false, now: now))
                == "Waiting for an agent run: a display is mirrored")
        // Below 1.5 × the cadence only an agent run offers it anyway: the guard is not mentioned.
        snapshot.timers.stillTime = 55 * 60
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Waiting for an agent run")
        // Strict mode already says only agent runs.
        snapshot.timers.stillTime = 80 * 60
        snapshot.settings.strictAgentOnly = true
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now))
                == "Waiting for an agent run (only during agent runs)")
    }

    @Test func waitingSaysWhichOpportunityAndTheFacts() {
        // Due, below 1.5 × cadence, no agents: only an agent run (or long command) offers it.
        var snapshot = Make.snapshot(at: now, screen: 5 * 60, still: 55 * 60)
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Waiting for an agent run")
        snapshot.sessions = [session(.claudeCode, .idle)]
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Waiting for an agent run: Claude is idle")
        snapshot.sessions = [session(.claudeCode, .working)]
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Waiting for your next prompt: Claude is working")
        snapshot.sessions = [session(.claudeCode, .working), session(.codex, .working, id: "c1"), session(.cursor, .idle, id: "u1")]
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Waiting for your next prompt: 2 agents are working")

        // Well overdue: a pause in typing offers it.
        snapshot = Make.snapshot(at: now, screen: 5 * 60, still: 80 * 60, input: typingInput(3))
        snapshot.sessions = [session(.claudeCode, .idle)]
        let typing = WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)
        #expect(line(typing) == "Waiting for a pause: Claude is idle and you are typing")
        #expect(typing.explainsADueBreak)
        // Typing right now (< 2 s): an agent starting would be held, so it is still a wait.
        snapshot.input = typingInput(0.5)
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Waiting for a pause: Claude is idle and you are typing")
        // Quiet past 8 s and still nothing: this pause already had its chance.
        snapshot.input = typingInput(20)
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Waiting for your next pause in typing: Claude is idle")

        // Strict mode: only agent runs.
        snapshot.settings.strictAgentOnly = true
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Waiting for an agent run: Claude is idle (only during agent runs)")
    }

    @Test func needsYouIsTheAgentFactThatMatters() {
        var snapshot = Make.snapshot(at: now, screen: 5 * 60, still: 55 * 60)
        snapshot.sessions = [session(.codex, .working, id: "c1"), session(.claudeCode, .waiting)]
        #expect(line(WhyNotNow.explain(snapshot, held: nil, onBreak: false, now: now)) == "Waiting for an agent run: Claude needs you")
    }

    /// Whatever the state, the line obeys the wording rules.
    @Test func everyLineFollowsTheWordingRules() {
        let reasons: [WaitReason] = [
            .onBreak, .offering, .paused(.call([.microphone, .camera])), .paused(.manual(until: now.plus(minutes: 30))),
            .paused(.windDownWrappedUp(until: Fixture.date(5, day: 23))), .away, .nothingDue(next: .move, in: 600),
            .easingBackIn(until: now), .spacingNudges(until: now), .spacingKind(.eyes, until: now),
            .holding(.typing), .holding(.pointer),
            .waiting(.init(due: .move, next: .typingPause, typing: true, agent: .init(name: "Claude", state: .waiting, count: 2))),
            .waiting(.init(due: .eyes, next: .agentRunOnly, typing: false, agent: .init(name: "Codex", state: .idle, count: 3))),
        ]
        for reason in reasons {
            let text = line(reason)
            #expect(!text.contains("!"), "\(text)")
            #expect(!text.lowercased().split { !$0.isLetter }.contains("should"), "\(text)")
            #expect(!text.lowercased().contains("look away"), "\(text)")
            #expect(text.count <= 80, "\(text) is too long for the popover's two lines")
        }
    }
}
