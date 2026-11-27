import Foundation
import Testing
@testable import BreakpointCore

@Suite("ActivityClock (SPEC §2.3)")
struct ActivityClockTests {
    let present = PresenceStatus.present
    let sample = Make.quiet(at: Fixture.date(14))

    @Test func accruesBothCountersOnlyWhilePresent() {
        let t = TimerState(screenTime: 100, stillTime: 200)
        #expect(ActivityClock.advance(t, sample: sample, presence: present, dt: 1) == TimerState(screenTime: 101, stillTime: 201))
        let away = PresenceStatus.away(since: Fixture.date(13), cause: .idle)
        #expect(ActivityClock.advance(t, sample: sample, presence: away, dt: 1) == t)
        #expect(ActivityClock.advance(t, sample: sample, presence: present, dt: -3) == t)
        #expect(ActivityClock.advance(t, sample: sample, presence: present, dt: .nan) == t)
    }

    struct ResetCase: Sendable, CustomTestStringConvertible {
        let kind: BreakKind
        let outcome: BreakOutcome
        let expected: TimerState
        var testDescription: String { "\(kind) \(outcome)" }
    }

    static let base = TimerState(screenTime: 1500, stillTime: 3300)
    static let eyesReset = TimerState(screenTime: 0, stillTime: 3300)
    static let resetCases: [ResetCase] = [
        // A started break restarts its timer however briefly it ran: completed or ended early.
        ResetCase(kind: .move, outcome: .completed, expected: .zero),
        ResetCase(kind: .walk, outcome: .completed, expected: .zero),
        ResetCase(kind: .eyes, outcome: .completed, expected: eyesReset),
        ResetCase(kind: .move, outcome: .endedEarly, expected: .zero),
        ResetCase(kind: .walk, outcome: .endedEarly, expected: .zero),
        ResetCase(kind: .eyes, outcome: .endedEarly, expected: eyesReset),
        // A breather is done sitting down: it never restarts still time (the coordinator holds
        // the next stretch off instead).
        ResetCase(kind: .breathe, outcome: .completed, expected: base),
        ResetCase(kind: .breathe, outcome: .endedEarly, expected: base),
        // Offers never started change nothing; `skipped` only exists in older history.
        ResetCase(kind: .move, outcome: .declined, expected: base),
        ResetCase(kind: .eyes, outcome: .ignored, expected: base),
        ResetCase(kind: .move, outcome: .skipped, expected: base),
        ResetCase(kind: .move, outcome: .credited, expected: base),
    ]

    @Test(arguments: resetCases)
    func resetsAfterABreak(_ row: ResetCase) {
        #expect(ActivityClock.afterBreak(Self.base, kind: row.kind, outcome: row.outcome) == row.expected)
    }

    @Test func removingAccrualNeverGoesNegative() {
        let t = TimerState(screenTime: 100, stillTime: 500)
        #expect(ActivityClock.removingAccrual(t, seconds: 180) == TimerState(screenTime: 0, stillTime: 320))
    }
}

@Suite("PresenceTracker (SPEC §2.3, §2.4)")
struct PresenceTrackerTests {
    let t0 = Fixture.date(14)
    let settings = Settings.defaults

    func sample(_ at: Date, idle: TimeInterval, displaySleepPrevented: Bool = false) -> InputSample {
        InputSample(takenAt: at, secondsSinceKey: idle, secondsSinceAnyInput: idle, secondsSinceDrag: idle,
                    displaySleepPrevented: displaySleepPrevented)
    }

    @Test func idleAwayStartsRetroactivelyAtTheThreshold() {
        var p = PresenceTracker()
        #expect(p.ingest(sample(t0, idle: 179.9), callActive: false, settings: settings).isEmpty)
        #expect(p.status == .present)
        let changes = p.ingest(sample(t0.plus(seconds: 0.1), idle: 180), callActive: false, settings: settings)
        #expect(changes == [.becameAway(since: t0.plus(seconds: -179.9), cause: .idle, retroactiveSeconds: 180)])
        #expect(p.status == .away(since: t0.plus(seconds: -179.9), cause: .idle))
        // Still idle: nothing new.
        #expect(p.ingest(sample(t0.plus(seconds: 60), idle: 240), callActive: false, settings: settings).isEmpty)
    }

    @Test func awayThresholdFollowsTheSetting() {
        var s = Settings()
        s.awayThresholdMinutes = 5
        var p = PresenceTracker()
        #expect(p.ingest(sample(t0, idle: 299), callActive: false, settings: s).isEmpty)
        #expect(p.ingest(sample(t0, idle: 300), callActive: false, settings: s).count == 1)
    }

    @Test func aCallNeverTurnsIdleIntoAway() {
        var p = PresenceTracker()
        #expect(p.ingest(sample(t0, idle: 3600), callActive: true, settings: settings).isEmpty)
        #expect(p.status == .present)
    }

    @Test func aDisplaySleepAssertionNeverTurnsIdleIntoAway() {
        var p = PresenceTracker()
        #expect(p.ingest(sample(t0, idle: 3600, displaySleepPrevented: true), callActive: false, settings: settings).isEmpty)
        #expect(p.status == .present)
    }

    @Test func idleAwayEndsAtTheNextInput() {
        var p = PresenceTracker()
        _ = p.ingest(sample(t0, idle: 180), callActive: false, settings: settings)
        let since = t0.plus(seconds: -180)
        // Sampling jitter is not input.
        #expect(p.ingest(sample(t0.plus(seconds: 600), idle: 779.7), callActive: false, settings: settings).isEmpty)
        // Input 2 s before this sample.
        let back = t0.plus(minutes: 20)
        let changes = p.ingest(sample(back, idle: 2), callActive: false, settings: settings)
        #expect(changes == [.returned(AwayPeriod(start: since, end: back.plus(seconds: -2), cause: .idle))])
        #expect(p.status == .present)
    }

    @Test func theNextIdlePeriodNeverStartsBeforeTheReturn() {
        var p = PresenceTracker()
        // Locked at t0, unlocked 30 min later without touching anything since t0 - 10 s.
        _ = p.ingest(.locked, at: t0)
        _ = p.ingest(.unlocked, at: t0.plus(minutes: 30))
        let changes = p.ingest(sample(t0.plus(minutes: 33), idle: 33 * 60 + 10), callActive: false, settings: settings)
        #expect(changes == [.becameAway(since: t0.plus(minutes: 30), cause: .idle, retroactiveSeconds: 180)])
    }

    @Test func lockIsAwayFromTheLockMomentUntilUnlock() {
        var p = PresenceTracker()
        #expect(p.ingest(.locked, at: t0) == [.becameAway(since: t0, cause: .locked, retroactiveSeconds: 0)])
        // Typing the password at the lock screen is input, but not a return.
        #expect(p.ingest(sample(t0.plus(seconds: 38), idle: 1), callActive: false, settings: settings).isEmpty)
        #expect(p.status.isAway)
        #expect(p.ingest(.unlocked, at: t0.plus(seconds: 40)) == [.returned(AwayPeriod(start: t0, end: t0.plus(seconds: 40), cause: .locked))])
        #expect(p.status == .present)
    }

    @Test func displaySleepEndsAtWakeOrInput() {
        var p = PresenceTracker()
        _ = p.ingest(.displaysSlept, at: t0)
        #expect(p.ingest(.displaysWoke, at: t0.plus(minutes: 5)) == [.returned(AwayPeriod(start: t0, end: t0.plus(minutes: 5), cause: .displaysAsleep))])

        var q = PresenceTracker()
        _ = q.ingest(.displaysSlept, at: t0)
        // No wake notification, but a key press after the sleep wakes the displays.
        let changes = q.ingest(sample(t0.plus(minutes: 6), idle: 1), callActive: false, settings: settings)
        #expect(changes == [.returned(AwayPeriod(start: t0, end: t0.plus(minutes: 6).plus(seconds: -1), cause: .displaysAsleep))])
    }

    @Test func sleepWithALockNeedsTheUnlock() {
        var p = PresenceTracker()
        _ = p.ingest(.screensaverStarted, at: t0)
        _ = p.ingest(.locked, at: t0.plus(seconds: 5))
        _ = p.ingest(.displaysSlept, at: t0.plus(minutes: 10))
        _ = p.ingest(.systemWillSleep, at: t0.plus(minutes: 30))
        #expect(p.ingest(.systemDidWake, at: t0.plus(minutes: 90)).isEmpty)
        #expect(p.ingest(.displaysWoke, at: t0.plus(minutes: 90)).isEmpty)
        #expect(p.ingest(sample(t0.plus(minutes: 90.5), idle: 0.5), callActive: false, settings: settings).isEmpty)
        #expect(p.status.isAway)
        let back = p.ingest(.unlocked, at: t0.plus(minutes: 91))
        #expect(back == [.returned(AwayPeriod(start: t0, end: t0.plus(minutes: 91), cause: .screensaver))])
    }

    @Test func systemSleepAndScreensaverAndSessionSwitch() {
        for (start, end, cause) in [(PresenceEvent.systemWillSleep, PresenceEvent.systemDidWake, AwayCause.systemAsleep),
                                    (.screensaverStarted, .screensaverStopped, .screensaver),
                                    (.sessionResigned, .sessionActivated, .sessionSwitched)] {
            var p = PresenceTracker()
            #expect(p.ingest(start, at: t0) == [.becameAway(since: t0, cause: cause, retroactiveSeconds: 0)])
            #expect(p.ingest(end, at: t0.plus(minutes: 7)) == [.returned(AwayPeriod(start: t0, end: t0.plus(minutes: 7), cause: cause))])
        }
    }

    @Test func idleThenLockedIsOnePeriodFromTheLastInput() {
        var p = PresenceTracker()
        _ = p.ingest(sample(t0, idle: 200), callActive: false, settings: settings)
        let since = t0.plus(seconds: -200)
        #expect(p.ingest(.locked, at: t0.plus(minutes: 1)).isEmpty)
        #expect(p.ingest(.unlocked, at: t0.plus(minutes: 45)) == [.returned(AwayPeriod(start: since, end: t0.plus(minutes: 45), cause: .idle))])
    }

    @Test func aStrayEndEventDoesNotEndIdleAway() {
        var p = PresenceTracker()
        _ = p.ingest(sample(t0, idle: 200), callActive: false, settings: settings)
        #expect(p.ingest(.unlocked, at: t0.plus(minutes: 1)).isEmpty)
        #expect(p.ingest(.displaysWoke, at: t0.plus(minutes: 1)).isEmpty)
        #expect(p.status.isAway)
    }

    @Test func returningToTheSessionAlsoEndsItsLock() {
        var p = PresenceTracker()
        _ = p.ingest(.locked, at: t0)
        _ = p.ingest(.sessionResigned, at: t0.plus(seconds: 1))
        #expect(p.ingest(.sessionActivated, at: t0.plus(minutes: 3)).count == 1)
        #expect(p.status == .present)
    }
}
