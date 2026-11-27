import Foundation
import Testing
@testable import BreakpointCore

@Suite("Routines (SPEC §2.2) and break rules (SPEC §3.3)")
struct RoutineTests {
    let now = Fixture.date(14)

    @Test func builtInRoutines() {
        let first = BuiltInRoutines.neckAndShoulders
        #expect(first.totalDuration == Timing.routineLength)
        #expect(first.steps.map(\.duration) == [30, 36, 24, 30])
        #expect(first.steps[1].title == "Arms up the wall")
        #expect(first.steps[1].instruction == "Back to a wall, or stand tall and reach overhead.")
        #expect(BuiltInRoutines.bandRaises.totalDuration == Timing.routineLength)
        #expect(BuiltInRoutines.bandRaises.steps.count == 5)
        var s = Settings()
        #expect(BuiltInRoutines.routine(for: s).id == "neck-and-shoulders")
        #expect(BuiltInRoutines.allowed(for: s).allSatisfy { $0.equipment == .none })
        #expect(BuiltInRoutines.allowed(for: s).count >= 6)
        s.hasBand = true
        #expect(BuiltInRoutines.allowed(for: s).map(\.id).contains("band-raises"))
        #expect(BuiltInRoutines.allowed(for: s).map(\.id).contains("band-pull-aparts"))
    }

    @Test func libraryIdsAreUniqueAndStable() {
        let ids = BuiltInRoutines.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        // Settings and rotation.json refer to these; renaming one loses the user's choices.
        #expect(ids == ["neck-and-shoulders", "wrists-and-forearms", "upper-back", "chest-opener", "hips-and-calves",
                        "stand-and-reach", "seated-legs", "band-raises", "band-pull-aparts"])
        for routine in BuiltInRoutines.all {
            let stepIDs = routine.steps.map(\.id)
            #expect(Set(stepIDs).count == stepIDs.count, "\(routine.id) repeats a step id")
            #expect(BuiltInRoutines.routine(id: routine.id) == routine)
        }
    }

    @Test func exclusionsAndTheEmptyFallback() {
        var s = Settings()
        s.setRoutine("wrists-and-forearms", excluded: true)
        #expect(!BuiltInRoutines.allowed(for: s).map(\.id).contains("wrists-and-forearms"))
        // Excluding every routine (a hand-edited file) falls back to all of them.
        s.excludedRoutines = BuiltInRoutines.all.map(\.id)
        #expect(BuiltInRoutines.allowed(for: s) == BuiltInRoutines.available(for: s))
    }

    @Test func stepIndexByElapsedTime() {
        let r = BuiltInRoutines.neckAndShoulders
        #expect(r.stepIndex(at: 0) == 0)
        #expect(r.stepIndex(at: 29.9) == 0)
        #expect(r.stepIndex(at: 30) == 1)
        #expect(r.stepIndex(at: 100) == 3)
        #expect(r.stepIndex(at: 500) == 3)
        #expect(r.stepOffsets == [0, 30, 66, 90])
    }

    @Test func sessionRules() {
        var s = BreakSessionRules.makeSession(kind: .move, opportunity: nil, settings: .defaults, expectedRun: nil,
                                              agentName: nil, copyRotation: 0, now: now)
        #expect(s.plannedLength == 120)
        #expect(!BreakSessionRules.isSkipEnabled(s, now: now.addingTimeInterval(2.9)))
        #expect(BreakSessionRules.isSkipEnabled(s, now: now.addingTimeInterval(3)))
        #expect(!BreakSessionRules.isDoneAvailable(s, now: now.addingTimeInterval(95)))
        #expect(BreakSessionRules.isDoneAvailable(s, now: now.addingTimeInterval(96)))
        s = BreakSessionRules.extended(s)
        s = BreakSessionRules.extended(s)
        #expect(s.totalLength == 240)
        #expect(s.routine?.totalDuration == 240)
        #expect(!BreakSessionRules.canExtend(s))
        #expect(BreakSessionRules.extended(s) == s)
        #expect(BreakSessionRules.ceiling(s) == 300)

        let advanced = BreakSessionRules.advanced(s, now: now.addingTimeInterval(31))
        #expect(advanced.stepIndex == 1)
        #expect(advanced.stepStartedAt == now.addingTimeInterval(30))
        #expect(BreakSessionRules.stepped(advanced, by: -5, now: now).stepIndex == 0)

        #expect(BreakSessionRules.outcome(for: .skip, session: s, now: now) == .endedEarly)
        #expect(BreakSessionRules.outcome(for: .finish(.backToWork), session: s, now: now.addingTimeInterval(100)) == .endedEarly)
        #expect(BreakSessionRules.outcome(for: .finish(.backToWork), session: s, now: now.addingTimeInterval(192)) == .completed)
    }

    @Test func walkRules() {
        let s = BreakSessionRules.makeSession(kind: .walk, opportunity: nil, settings: .defaults, expectedRun: 400,
                                              agentName: "Claude", copyRotation: 0, now: now)
        #expect(s.plannedLength == 420)
        #expect(s.copy.instruction == "We'll chime when Claude needs you.")
        #expect(!BreakSessionRules.timerEnded(s, now: now.addingTimeInterval(1000)))
        #expect(!BreakSessionRules.isDoneAvailable(s, now: now.addingTimeInterval(1000)))
        #expect(BreakSessionRules.ceiling(s) == 1800)
        #expect(BreakSessionRules.outcome(for: .finish(.imBack), session: s, now: now.addingTimeInterval(300)) == .endedEarly)
        #expect(BreakSessionRules.outcome(for: .finish(.imBack), session: s, now: now.addingTimeInterval(336)) == .completed)
    }

    /// A started break is never a refusal: Skip (or Esc twice) is just less time, as with I'm
    /// back, whatever its kind and however soon (SPEC §2.7).
    @Test func skippingAnyBreakEndsItEarly() {
        func skipped(_ s: BreakSession, after seconds: TimeInterval) -> BreakOutcome {
            BreakSessionRules.outcome(for: .skip, session: s, now: now.addingTimeInterval(seconds))
        }
        func session(_ kind: BreakKind) -> BreakSession {
            BreakSessionRules.makeSession(kind: kind, opportunity: nil, settings: .defaults, expectedRun: nil,
                                          agentName: nil, copyRotation: 0, now: now)
        }

        let walk = session(.walk)
        #expect(walk.plannedLength == 300)
        #expect(skipped(walk, after: Timing.skipGuard) == .endedEarly)
        #expect(skipped(walk, after: 90) == .endedEarly)
        #expect(skipped(walk, after: 240) == .completed)      // 80% of the target, as I'm back

        var move = session(.move)
        #expect(skipped(move, after: Timing.skipGuard) == .endedEarly)
        #expect(skipped(move, after: 30) == .endedEarly)
        #expect(skipped(move, after: 96) == .completed)
        // Two extra minutes move Done to 192 s.
        move = BreakSessionRules.extended(BreakSessionRules.extended(move))
        #expect(skipped(move, after: 130) == .endedEarly)

        let eyes = session(.eyes)
        #expect(skipped(eyes, after: Timing.skipGuard) == .endedEarly)
        #expect(skipped(eyes, after: 12) == .endedEarly)
        #expect(skipped(eyes, after: 16) == .completed)       // 80% of 20 s
        let breathe = session(.breathe)
        #expect(skipped(breathe, after: Timing.skipGuard) == .endedEarly)
        #expect(skipped(BreakSessionRules.extended(BreakSessionRules.extended(breathe)), after: 100) == .endedEarly)
    }

    /// Every way of ending a started break, at the earliest moment each allows (Skip after the
    /// 3 s guard; I'm back and Back to work at once), for every kind: never `skipped`, and the
    /// timer restarts as for a completed break (a breather restarts nothing) (SPEC §2.3, §2.7).
    @Test(arguments: BreakKind.allCases)
    func aStartedBreakCountsHoweverSoonItEnds(_ kind: BreakKind) {
        let session = BreakSessionRules.makeSession(kind: kind, opportunity: nil, settings: .defaults, expectedRun: nil,
                                                    agentName: nil, copyRotation: 0, now: now)
        let timers = TimerState(screenTime: 1500, stillTime: 3300)
        let restarted: TimerState
        switch kind {
        case .move, .walk: restarted = .zero
        case .eyes: restarted = TimerState(screenTime: 0, stillTime: 3300)
        case .breathe: restarted = timers
        }
        #expect(BreakSessionRules.isSkipEnabled(session, now: now.addingTimeInterval(Timing.skipGuard)))
        #expect(!BreakSessionRules.isSkipEnabled(session, now: now.addingTimeInterval(Timing.skipGuard - 0.1)))
        let ends: [(BreakEnd, TimeInterval)] = [(.skip, Timing.skipGuard), (.finish(.imBack), 0), (.finish(.backToWork), 1)]
        for (end, at) in ends {
            let outcome = BreakSessionRules.outcome(for: end, session: session, now: now.addingTimeInterval(at))
            #expect(outcome == .endedEarly, "\(kind) \(end)")
            #expect(ActivityClock.afterBreak(timers, kind: kind, outcome: outcome) == restarted, "\(kind) \(end)")
        }
    }

    @Test func previewsAreShort() {
        let s = BreakSessionRules.makeSession(kind: .move, opportunity: nil, settings: .defaults, expectedRun: nil,
                                              agentName: nil, copyRotation: 0, now: now, isPreview: true)
        #expect(s.isPreview && s.plannedLength == 5)
    }
}
