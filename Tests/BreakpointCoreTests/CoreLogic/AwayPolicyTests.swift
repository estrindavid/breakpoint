import Foundation
import Testing
@testable import BreakpointCore

@Suite("AwayPolicy: natural breaks and Undo (SPEC §2.3)")
struct AwayPolicyTests {
    let start = Fixture.date(12)
    let settings = Settings.defaults

    func period(_ seconds: TimeInterval, cause: AwayCause = .idle) -> AwayPeriod {
        AwayPeriod(start: start, end: start.plus(seconds: seconds), cause: cause)
    }

    func resolve(_ seconds: TimeInterval, screen: TimeInterval, still: TimeInterval, cause: AwayCause = .idle) -> AwayResolution {
        AwayPolicy.resolve(period(seconds, cause: cause), timers: TimerState(screenTime: screen, stillTime: still),
                           settings: settings, now: start.plus(seconds: seconds))
    }

    @Test func shortLockResetsOnlyTheEyeTimer() throws {
        // 40 s lock, eye rest due: credited, still time untouched.
        let r = resolve(40, screen: 21 * 60, still: 30 * 60, cause: .locked)
        #expect(r.timers == TimerState(screenTime: 0, stillTime: 30 * 60))
        #expect(r.creditedEntries.map(\.kind) == [.eyes])
        let entry = try #require(r.creditedEntries.first)
        #expect(entry.outcome == .credited && entry.start == start && entry.duration == 40)
        #expect(entry.opportunityKind == nil && entry.source == nil)
        let decision = try #require(r.decision)
        #expect(decision.kind == .creditedAway([.eyes], duration: 40))
        #expect(decision.previous == TimerState(screenTime: 21 * 60, stillTime: 30 * 60))
        #expect(decision.historyEntryIDs == [entry.id])
        #expect(decision.sentence == "Counted your 40 s away as a break")
        #expect(r.showsAwayNote)
    }

    @Test func shortLockBeforeTheEyeRestIsDueResetsSilently() throws {
        let r = resolve(40, screen: 12 * 60, still: 30 * 60, cause: .locked)
        #expect(r.timers == TimerState(screenTime: 0, stillTime: 30 * 60))
        #expect(r.creditedEntries.isEmpty)
        #expect(!r.showsAwayNote)
        let decision = try #require(r.decision)
        #expect(decision.kind == .timersReset(duration: 40))
        #expect(Copy.decisionLine(decision) == "Reset timers after 40 s away")
    }

    @Test func tooShortToCountChangesNothing() {
        let r = resolve(19.9, screen: 25 * 60, still: 55 * 60, cause: .locked)
        #expect(r == AwayResolution(timers: TimerState(screenTime: 25 * 60, stillTime: 55 * 60)))
    }

    @Test func boundariesAreTheBreakLengths() {
        #expect(resolve(20, screen: 60, still: 60).timers == TimerState(screenTime: 0, stillTime: 60))
        #expect(resolve(119.9, screen: 60, still: 60).timers == TimerState(screenTime: 0, stillTime: 60))
        #expect(resolve(120, screen: 60, still: 60).timers == .zero)
    }

    @Test func idleAwayWithBothDueCreditsBoth() throws {
        let r = resolve(6 * 60, screen: 22 * 60, still: 52 * 60)
        #expect(r.timers == .zero)
        #expect(r.creditedEntries.map(\.kind) == [.eyes, .move])
        #expect(r.creditedEntries.allSatisfy { $0.duration == 360 && $0.start == start })
        let decision = try #require(r.decision)
        #expect(decision.kind == .creditedAway([.eyes, .move], duration: 360))
        #expect(decision.sentence == "Counted your 6 min away as a break")
        #expect(decision.creditedKinds.max() == .move)
        #expect(Copy.decisionLine(decision) == "Counted 6 min away as a break")
    }

    @Test func idleAwayWithOnlyMoveDue() throws {
        let r = resolve(4 * 60, screen: 5 * 60, still: 50 * 60)
        #expect(r.timers == .zero)
        #expect(r.creditedEntries.map(\.kind) == [.move])
        #expect(try #require(r.decision).kind == .creditedAway([.move], duration: 240))
    }

    @Test func idleAwayWithNothingDueResetsAndSaysSo() throws {
        let r = resolve(4 * 60, screen: 5 * 60, still: 10 * 60)
        #expect(r.timers == .zero)
        #expect(r.creditedEntries.isEmpty)
        let decision = try #require(r.decision)
        #expect(decision.sentence == "Reset timers after 4 min away")
    }

    @Test func nothingToResetMeansNoDecision() {
        // Right after a break both timers are zero: an absence changes nothing.
        let r = resolve(30 * 60, screen: 0, still: 0)
        #expect(r.decision == nil && r.creditedEntries.isEmpty && r.timers == .zero)
    }

    @Test func undoRoundTrip() throws {
        let previous = TimerState(screenTime: 22 * 60, stillTime: 52 * 60)
        let r = resolve(6 * 60, screen: previous.screenTime, still: previous.stillTime)
        let decision = try #require(r.decision)
        // As if present: previous + D on both.
        #expect(AwayPolicy.undo(decision) == TimerState(screenTime: 28 * 60, stillTime: 58 * 60))
        // With time accrued since the decision kept.
        #expect(AwayPolicy.undo(decision, current: TimerState(screenTime: 120, stillTime: 120))
                == TimerState(screenTime: 30 * 60, stillTime: 60 * 60))
        #expect(decision.isUndoable(at: decision.madeAt.plus(minutes: 9.9)))
        #expect(!decision.isUndoable(at: decision.madeAt.plus(minutes: 10)))
    }

    @Test func undoOfAShortLockKeepsTheUntouchedCounterRunning() throws {
        let r = resolve(40, screen: 21 * 60, still: 30 * 60, cause: .locked)
        let decision = try #require(r.decision)
        // 2 min later: screen 120 (since reset), still 30 min + 2 min.
        let current = TimerState(screenTime: 120, stillTime: 32 * 60)
        #expect(AwayPolicy.undo(decision, current: current) == TimerState(screenTime: 21 * 60 + 120 + 40, stillTime: 32 * 60 + 40))
    }

    @Test func cadenceComesFromSettings() {
        var s = Settings()
        s.applyPreset(.gentle)
        let r = AwayPolicy.resolve(period(5 * 60), timers: TimerState(screenTime: 25 * 60, stillTime: 55 * 60), settings: s,
                                   now: start.plus(minutes: 5))
        #expect(r.creditedEntries.isEmpty)
        #expect(r.decision?.kind == .timersReset(duration: 300))
    }

    /// The SPEC §9 cases that are about presence rather than the policy: a call or a display-sleep
    /// assertion keeps an idle user present, so no period reaches `AwayPolicy` and nothing resets.
    @Test func callOrDisplaySleepAssertionMeansNoNaturalBreak() {
        for (call, assertion) in [(true, false), (false, true)] {
            var presence = PresenceTracker()
            var timers = TimerState(screenTime: 25 * 60, stillTime: 55 * 60)
            var now = start
            for _ in 0..<(20 * 60) {
                now = now.plus(seconds: 1)
                let sample = InputSample(takenAt: now, secondsSinceKey: now.timeIntervalSince(start),
                                         secondsSinceAnyInput: now.timeIntervalSince(start),
                                         displaySleepPrevented: assertion)
                #expect(presence.ingest(sample, callActive: call, settings: settings).isEmpty)
                timers = ActivityClock.advance(timers, sample: sample, presence: presence.status, dt: 1)
            }
            #expect(timers == TimerState(screenTime: 45 * 60, stillTime: 75 * 60))
        }
    }
}
