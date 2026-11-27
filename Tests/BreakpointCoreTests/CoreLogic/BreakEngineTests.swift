import Foundation
import Testing
@testable import BreakpointCore

/// One row of the engine table: a snapshot and an opportunity built at `now`, and the decision.
struct EngineCase: Sendable, CustomTestStringConvertible {
    let name: String
    let build: @Sendable (Date) -> (EngineSnapshot, Opportunity)
    let expected: @Sendable (Date) -> EngineDecision
    var testDescription: String { name }
}

/// Both kinds due (screen 25 min of 20, still 55 min of 50), quiet input, agent opportunity.
private func due(_ now: Date, _ mutate: (inout EngineSnapshot) -> Void = { _ in }) -> EngineSnapshot {
    var s = Make.snapshot(at: now, screen: 25 * 60, still: 55 * 60)
    mutate(&s)
    return s
}

private func agent(_ now: Date) -> Opportunity { Make.opportunity(.agentStarted, source: .claudeCode, session: "s1", at: now) }
private func typing(_ now: Date) -> Opportunity { Make.opportunity(.typingPause, at: now) }

private func moveOffer(_ now: Date, _ opportunity: Opportunity, kind: BreakKind = .move, length: TimeInterval = 120,
                       expected: TimeInterval? = nil) -> EngineDecision {
    .offer(BreakOffer(kind: kind, length: length, opportunity: opportunity, overdueBy: 5 * 60, timerValue: 55 * 60,
                      expectedRunLength: expected))
}

private let fixedOpportunityID = UUID()
private let manualUntil = Fixture.date(15)
private func fixedAgent(_ now: Date) -> Opportunity {
    Opportunity(id: fixedOpportunityID, kind: .agentStarted, source: .claudeCode, sessionID: "s1", createdAt: now)
}
private func fixedTyping(_ now: Date) -> Opportunity {
    Opportunity(id: fixedOpportunityID, kind: .typingPause, createdAt: now)
}
private func fixedShell(_ now: Date) -> Opportunity {
    Opportunity(id: fixedOpportunityID, kind: .longCommand, source: .shell, sessionID: "4242", commandName: "swift",
                createdAt: now)
}

@Suite("BreakEngine decision order (SPEC §2.5)")
struct BreakEngineTests {
    let now = Fixture.date(14)

    /// Every suppress, hold and offer branch, in the order of SPEC §2.5, including boundaries.
    static let cases: [EngineCase] = [
        // 1. A surface is showing — wins over everything below.
        EngineCase(name: "1 surface visible beats pause, away and typing", build: { now in
            (due(now) {
                $0.surfaceVisible = true
                $0.pause = PauseState(reasons: [.manual(until: manualUntil)])
                $0.presence = .away(since: now, cause: .locked)
                $0.input.secondsSinceKey = 0
            }, agent(now))
        }, expected: { _ in .suppress(.surfaceVisible) }),

        // 2. Paused — names the primary reason; wins over away and cool-downs.
        EngineCase(name: "2 manual pause", build: { now in
            (due(now) { $0.pause = PauseState(reasons: [.manual(until: manualUntil)]) }, agent(now))
        }, expected: { _ in .suppress(.paused(.manual(until: manualUntil))) }),
        EngineCase(name: "2 call named over manual, before away", build: { now in
            (due(now) {
                $0.pause = PauseState(reasons: [.manual(until: manualUntil), .call(.microphone)])
                $0.presence = .away(since: now, cause: .idle)
            }, agent(now))
        }, expected: { _ in .suppress(.paused(.call(.microphone))) }),
        EngineCase(name: "2 wrap-up pause", build: { now in
            (due(now) { $0.pause = PauseState(reasons: [.windDownWrappedUp(until: manualUntil)]) }, typing(now))
        }, expected: { _ in .suppress(.paused(.windDownWrappedUp(until: manualUntil))) }),

        // 3. Away — wins over cool-downs.
        EngineCase(name: "3 away beats cool-down", build: { now in
            (due(now) {
                $0.presence = .away(since: now.plus(minutes: -5), cause: .idle)
                $0.pause.cooldownUntil = now.plus(seconds: 30)
            }, agent(now))
        }, expected: { _ in .suppress(.away) }),

        // 4. Resume cool-down, then nudge spacing.
        EngineCase(name: "4 resume cool-down", build: { now in
            (due(now) { $0.pause.cooldownUntil = now.plus(seconds: 59) }, agent(now))
        }, expected: { now in .suppress(.cooldown(until: now.plus(seconds: 59))) }),
        EngineCase(name: "4 cool-down over at its end", build: { now in
            (due(now) { $0.pause.cooldownUntil = now }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),
        EngineCase(name: "4 cool-down beats spacing", build: { now in
            (due(now) {
                $0.pause.cooldownUntil = now.plus(seconds: 10)
                $0.lastNudgeAt = now.plus(minutes: -1)
            }, agent(now))
        }, expected: { now in .suppress(.cooldown(until: now.plus(seconds: 10))) }),
        EngineCase(name: "4 spacing after the previous nudge", build: { now in
            (due(now) { $0.lastNudgeAt = now.plus(minutes: -9) }, agent(now))
        }, expected: { now in .suppress(.spacing(until: now.plus(minutes: 1))) }),
        EngineCase(name: "4 spacing still on 5 min after the previous nudge", build: { now in
            (due(now) { $0.lastNudgeAt = now.plus(minutes: -5) }, agent(now))
        }, expected: { now in .suppress(.spacing(until: now.plus(minutes: 5))) }),
        EngineCase(name: "4 spacing after the end of a break, the later anchor wins", build: { now in
            (due(now) {
                $0.lastNudgeAt = now.plus(minutes: -14)
                $0.lastBreakEndedAt = now.plus(minutes: -7)
            }, agent(now))
        }, expected: { now in .suppress(.spacing(until: now.plus(minutes: 3))) }),
        EngineCase(name: "4 spacing over at exactly 10 min", build: { now in
            (due(now) { $0.lastNudgeAt = now.plus(minutes: -10) }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),
        EngineCase(name: "4 spacing on 1 s before 10 min", build: { now in
            (due(now) { $0.lastNudgeAt = now.plus(seconds: -599) }, agent(now))
        }, expected: { now in .suppress(.spacing(until: now.plus(seconds: 1))) }),

        // 5. Strict mode drops typing pauses only.
        EngineCase(name: "5 strict mode drops typingPause", build: { now in
            (due(now) { $0.settings.strictAgentOnly = true }, typing(now))
        }, expected: { _ in .suppress(.strictMode) }),
        EngineCase(name: "5 strict mode before the typing guard", build: { now in
            (due(now) {
                $0.settings.strictAgentOnly = true
                $0.input.secondsSinceKey = 0.5
            }, typing(now))
        }, expected: { _ in .suppress(.strictMode) }),
        EngineCase(name: "5 strict mode keeps agent opportunities", build: { now in
            (due(now) { $0.settings.strictAgentOnly = true }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),

        // 5. The presenting guard drops typing pauses only, after strict mode.
        EngineCase(name: "5 mirrored display drops typingPause", build: { now in
            (due(now) {
                $0.timers.stillTime = 80 * 60
                $0.input.displayMirrored = true
            }, typing(now))
        }, expected: { _ in .suppress(.presenting(.displayMirrored)) }),
        EngineCase(name: "5 kept-awake display drops typingPause", build: { now in
            (due(now) {
                $0.timers.stillTime = 80 * 60
                $0.input.displaySleepPrevented = true
            }, typing(now))
        }, expected: { _ in .suppress(.presenting(.displayKeptAwake)) }),
        EngineCase(name: "5 strict mode is named before the presenting guard", build: { now in
            (due(now) {
                $0.settings.strictAgentOnly = true
                $0.input.displayMirrored = true
            }, typing(now))
        }, expected: { _ in .suppress(.strictMode) }),
        EngineCase(name: "5 presenting keeps agent opportunities", build: { now in
            (due(now) {
                $0.input.displayMirrored = true
                $0.input.displaySleepPrevented = true
            }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),

        // 6. Typing and pointer guard: hold, not drop.
        EngineCase(name: "6 key 1.9 s ago holds", build: { now in
            (due(now) { $0.input.secondsSinceKey = 1.9 }, agent(now))
        }, expected: { _ in .hold(.typing) }),
        EngineCase(name: "6 key exactly 2 s ago is quiet", build: { now in
            (due(now) { $0.input.secondsSinceKey = 2 }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),
        EngineCase(name: "6 mouse button down holds", build: { now in
            (due(now) { $0.input.mouseButtonDown = true }, agent(now))
        }, expected: { _ in .hold(.pointer) }),
        EngineCase(name: "6 drag 0.9 s ago holds", build: { now in
            (due(now) { $0.input.secondsSinceDrag = 0.9 }, agent(now))
        }, expected: { _ in .hold(.pointer) }),
        EngineCase(name: "6 drag exactly 1 s ago is quiet", build: { now in
            (due(now) { $0.input.secondsSinceDrag = 1 }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),
        EngineCase(name: "6 typing named before pointer", build: { now in
            (due(now) {
                $0.input.secondsSinceKey = 0
                $0.input.mouseButtonDown = true
            }, agent(now))
        }, expected: { _ in .hold(.typing) }),
        EngineCase(name: "6 microphone on but not yet a call holds", build: { now in
            (due(now) { $0.microphonePending = true }, agent(now))
        }, expected: { _ in .hold(.microphone) }),
        EngineCase(name: "6 typing named before the microphone", build: { now in
            (due(now) {
                $0.microphonePending = true
                $0.input.secondsSinceKey = 0.5
            }, agent(now))
        }, expected: { _ in .hold(.typing) }),
        EngineCase(name: "6 hold even when nothing is due", build: { now in
            (Make.snapshot(at: now, input: InputSample(takenAt: now, secondsSinceKey: 0)), agent(now))
        }, expected: { _ in .hold(.typing) }),

        // 7. The still-time slot: move, walk or breathe.
        EngineCase(name: "7 move", build: { now in (due(now), fixedAgent(now)) },
                   expected: { now in moveOffer(now, fixedAgent(now)) }),
        EngineCase(name: "7 move at exactly its cadence", build: { now in
            (Make.snapshot(at: now, still: 50 * 60), fixedAgent(now))
        }, expected: { now in
            .offer(BreakOffer(kind: .move, length: 120, opportunity: fixedAgent(now), overdueBy: 0, timerValue: 50 * 60))
        }),
        EngineCase(name: "7 breathe after two refusals", build: { now in
            (due(now) { $0.consecutiveMoveRefusals = 2 }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now), kind: .breathe, length: 60) }),
        EngineCase(name: "7 one refusal is still move", build: { now in
            (due(now) { $0.consecutiveMoveRefusals = 1 }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),
        EngineCase(name: "7 breathe beats walk", build: { now in
            (due(now) {
                $0.consecutiveMoveRefusals = 3
                $0.expectedRunLengths = [.claudeCode: 9 * 60]
            }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now), kind: .breathe, length: 60, expected: 9 * 60) }),
        EngineCase(name: "7 walk when the agent usually runs 9 min", build: { now in
            (due(now) { $0.expectedRunLengths = [.claudeCode: 9 * 60] }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now), kind: .walk, length: 9 * 60, expected: 9 * 60) }),
        EngineCase(name: "7 walk at exactly the threshold", build: { now in
            (due(now) { $0.expectedRunLengths = [.claudeCode: 8 * 60] }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now), kind: .walk, length: 8 * 60, expected: 8 * 60) }),
        EngineCase(name: "7 move just under the threshold", build: { now in
            (due(now) { $0.expectedRunLengths = [.claudeCode: 8 * 60 - 1] }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now), expected: 8 * 60 - 1) }),
        EngineCase(name: "7 walk target clamps to 10 min", build: { now in
            (due(now) { $0.expectedRunLengths = [.claudeCode: 25 * 60] }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now), kind: .walk, length: 10 * 60, expected: 25 * 60) }),
        EngineCase(name: "7 walk target rounds to the minute", build: { now in
            (due(now) {
                $0.settings.walkThresholdMinutes = 5
                $0.expectedRunLengths = [.claudeCode: 6 * 60 + 40]
            }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now), kind: .walk, length: 7 * 60, expected: 6 * 60 + 40) }),
        EngineCase(name: "7 another agent's long runs do not make a walk", build: { now in
            (due(now) { $0.expectedRunLengths = [.codex: 20 * 60] }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),
        EngineCase(name: "7 a long command is a stretch, not a walk", build: { now in
            (due(now) { $0.expectedRunLengths = [.shell: 20 * 60] }, fixedShell(now))
        }, expected: { now in moveOffer(now, fixedShell(now)) }),
        EngineCase(name: "7 typing pause needs 1.5 × the move cadence", build: { now in
            (Make.snapshot(at: now, still: 74 * 60), typing(now))
        }, expected: { _ in .nothing }),
        EngineCase(name: "7 typing pause at exactly 1.5 × the move cadence", build: { now in
            (Make.snapshot(at: now, still: 75 * 60), fixedTyping(now))
        }, expected: { now in
            .offer(BreakOffer(kind: .move, length: 120, opportunity: fixedTyping(now), overdueBy: 25 * 60, timerValue: 75 * 60))
        }),

        // Kind spacing: the still-time slot is spaced as one; eyes on its own.
        EngineCase(name: "7→8 move spaced, eyes offered instead", build: { now in
            (due(now) { $0.kindSpacedUntil = [.move: now.plus(minutes: 3)] }, fixedAgent(now))
        }, expected: { now in
            .offer(BreakOffer(kind: .eyes, length: 20, opportunity: fixedAgent(now), overdueBy: 5 * 60, timerValue: 25 * 60))
        }),
        EngineCase(name: "7→8 a declined walk spaces the stretch too", build: { now in
            (due(now) { $0.kindSpacedUntil = [.walk: now.plus(minutes: 3)] }, fixedAgent(now))
        }, expected: { now in
            .offer(BreakOffer(kind: .eyes, length: 20, opportunity: fixedAgent(now), overdueBy: 5 * 60, timerValue: 25 * 60))
        }),
        EngineCase(name: "7 kind spacing over at its end", build: { now in
            (due(now) { $0.kindSpacedUntil = [.move: now, .eyes: now.plus(minutes: 1)] }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),
        // After a breather the still-time slot is held for a cadence; eyes are not.
        EngineCase(name: "7→8 held after a breather, eyes offered instead", build: { now in
            (due(now) { $0.stretchHeldUntil = now.plus(minutes: 40) }, fixedAgent(now))
        }, expected: { now in
            .offer(BreakOffer(kind: .eyes, length: 20, opportunity: fixedAgent(now), overdueBy: 5 * 60, timerValue: 25 * 60))
        }),
        EngineCase(name: "9 held after a breather, no eye rest due", build: { now in
            ({ var s = Make.snapshot(at: now, screen: 5 * 60, still: 90 * 60)
               s.stretchHeldUntil = now.plus(seconds: 1)
               return s }(), agent(now))
        }, expected: { _ in .nothing }),
        EngineCase(name: "7 hold over at its end", build: { now in
            (due(now) { $0.stretchHeldUntil = now }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),
        EngineCase(name: "7 eyes spacing does not block move", build: { now in
            (due(now) { $0.kindSpacedUntil = [.eyes: now.plus(minutes: 9)] }, fixedAgent(now))
        }, expected: { now in moveOffer(now, fixedAgent(now)) }),

        // 8. Eyes.
        EngineCase(name: "8 eyes", build: { now in (Make.snapshot(at: now, screen: 21 * 60, still: 10 * 60), fixedAgent(now)) },
                   expected: { now in
            .offer(BreakOffer(kind: .eyes, length: 20, opportunity: fixedAgent(now), overdueBy: 60, timerValue: 21 * 60))
        }),
        EngineCase(name: "8 eyes with a typing pause at 1.5 ×", build: { now in
            (Make.snapshot(at: now, screen: 30 * 60), fixedTyping(now))
        }, expected: { now in
            .offer(BreakOffer(kind: .eyes, length: 20, opportunity: fixedTyping(now), overdueBy: 10 * 60, timerValue: 30 * 60))
        }),
        EngineCase(name: "8 frequent preset: eyes due at 15 min", build: { now in
            var settings = Settings()
            settings.applyPreset(.frequent)
            return (Make.snapshot(at: now, screen: 15 * 60, settings: settings), fixedAgent(now))
        }, expected: { now in
            .offer(BreakOffer(kind: .eyes, length: 20, opportunity: fixedAgent(now), overdueBy: 0, timerValue: 15 * 60))
        }),

        // 9. Nothing.
        EngineCase(name: "9 nothing due", build: { now in (Make.snapshot(at: now, screen: 19 * 60, still: 49 * 60), agent(now)) },
                   expected: { _ in .nothing }),
        EngineCase(name: "9 everything due is spaced", build: { now in
            (due(now) { $0.kindSpacedUntil = [.eyes: now.plus(minutes: 2), .breathe: now.plus(minutes: 2)] }, agent(now))
        }, expected: { _ in .nothing }),
        EngineCase(name: "9 typing pause with eyes only 1.4 × due", build: { now in
            (Make.snapshot(at: now, screen: 28 * 60), typing(now))
        }, expected: { _ in .nothing }),
    ]

    @Test(arguments: cases)
    func decision(_ row: EngineCase) {
        let (snapshot, opportunity) = row.build(now)
        #expect(BreakEngine.decide(snapshot, opportunity: opportunity, now: now) == row.expected(now))
    }

    @Test func offerCarriesTheWhyNowFacts() throws {
        var s = due(now)
        s.expectedRunLengths = [.claudeCode: 4 * 60]
        let offer = try #require(BreakEngine.decide(s, opportunity: agent(now), now: now).offer)
        #expect(offer.kind == .move)
        #expect(offer.overdueBy == 5 * 60)
        #expect(offer.timerValue == 55 * 60)
        #expect(offer.expectedRunLength == TimeInterval(4 * 60))
        #expect(Copy.whyNow(for: offer) == "5 min overdue · Claude usually takes 4 min")
        #expect(Copy.nudgeSubtitle(for: offer) == "Claude is working")
    }

    @Test func noRecordedRunsMeansNoUsualRunClaim() throws {
        let offer = try #require(BreakEngine.decide(due(now), opportunity: agent(now), now: now).offer)
        #expect(offer.expectedRunLength == nil)
        #expect(Copy.whyNow(for: offer) == "5 min overdue")
    }

    @Test func isPureAndDeterministic() {
        let snapshot = due(now)
        let opportunity = fixedAgent(now)
        let first = BreakEngine.decide(snapshot, opportunity: opportunity, now: now)
        for _ in 0..<5 {
            #expect(BreakEngine.decide(snapshot, opportunity: opportunity, now: now) == first)
        }
    }

    @Test func everyOfferHasKindAndLengthInItsTitle() throws {
        for (expected, kind) in [(9.0 * 60, BreakKind.walk), (0, .move)] {
            var s = due(now)
            if expected > 0 { s.expectedRunLengths = [.claudeCode: expected] }
            let offer = try #require(BreakEngine.decide(s, opportunity: agent(now), now: now).offer)
            #expect(offer.kind == kind)
            let title = Copy.nudgeTitle(kind: offer.kind, length: offer.length)
            #expect(title.split(separator: " ").count <= 7)
            #expect(title.hasSuffix("?"))
        }
        let breathe = try #require(BreakEngine.decide(due(now) { $0.consecutiveMoveRefusals = 2 },
                                                      opportunity: agent(now), now: now).offer)
        #expect(Copy.nudgeTitle(kind: breathe.kind, length: breathe.length) == "1-min breather?")
    }

    /// SPEC §2.4: ten minutes for the first refusals in a row, then one whole cadence of that slot.
    @Test func aRefusalSpacesItsSlotTenMinutesThenAWholeCadence() {
        let balanced = Settings.defaults.cadence
        let first = Timing.refusalsBeforeCadenceSpacing
        for kind in BreakKind.allCases {
            for inARow in 1..<first {
                #expect(BreakEngine.spacingAfterRefusal(kind, refusalsInARow: inARow, cadence: balanced) == Timing.kindSpacing)
            }
            for inARow in [first, first + 1, first + 10] {
                #expect(BreakEngine.spacingAfterRefusal(kind, refusalsInARow: inARow, cadence: balanced)
                        == balanced.interval(for: kind))
            }
        }
        #expect(BreakEngine.spacingAfterRefusal(.move, refusalsInARow: first, cadence: balanced) == 50 * 60)
        #expect(BreakEngine.spacingAfterRefusal(.eyes, refusalsInARow: first, cadence: balanced) == 20 * 60)
        // A cadence shorter than kind spacing never shortens it.
        let tiny = Cadence(eyesEveryMinutes: 5, moveEveryMinutes: 5)
        #expect(BreakEngine.spacingAfterRefusal(.eyes, refusalsInARow: first, cadence: tiny) == Timing.kindSpacing)
    }
}
