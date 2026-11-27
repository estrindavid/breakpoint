import Foundation
import Testing
@testable import BreakpointCore

@Suite("OpportunityDetector (SPEC §2.5)")
struct OpportunityDetectorTests {
    let t0 = Fixture.date(14)

    func snapshot(at now: Date, commands: [RunningCommand] = [], keyIdle: TimeInterval = 30, screen: TimeInterval = 0,
                  still: TimeInterval = 0, settings: Settings = .defaults, presence: PresenceStatus = .present,
                  surfaceVisible: Bool = false) -> EngineSnapshot {
        var s = Make.snapshot(at: now, screen: screen, still: still, settings: settings,
                              input: InputSample(takenAt: now, secondsSinceKey: keyIdle, secondsSinceAnyInput: min(keyIdle, 1)))
        s.commands = commands
        s.presence = presence
        s.surfaceVisible = surfaceVisible
        return s
    }

    // MARK: longCommand

    @Test func longCommandAfterTwentySecondsOnce() throws {
        var d = OpportunityDetector()
        let swift = RunningCommand(shellPID: "4242", command: "swift", cwd: "/Users/dev/breakpoint", startedAt: t0)
        #expect(d.evaluate(snapshot(at: t0.plus(seconds: 19.9), commands: [swift]), now: t0.plus(seconds: 19.9)).isEmpty)
        let found = d.evaluate(snapshot(at: t0.plus(seconds: 20), commands: [swift]), now: t0.plus(seconds: 20))
        let opportunity = try #require(found.first)
        #expect(found.count == 1)
        #expect(opportunity.kind == .longCommand && opportunity.source == .shell)
        #expect(opportunity.sessionID == "4242" && opportunity.commandName == "swift")
        #expect(opportunity.createdAt == t0.plus(seconds: 20) && opportunity.expiresAt == t0.plus(seconds: 50))
        #expect(opportunity.sessionKey == nil)
        #expect(d.evaluate(snapshot(at: t0.plus(seconds: 21), commands: [swift]), now: t0.plus(seconds: 21)).isEmpty)
        #expect(d.evaluate(snapshot(at: t0.plus(minutes: 5), commands: [swift]), now: t0.plus(minutes: 5)).isEmpty)
    }

    @Test func interactiveProgramsNeverCount() {
        var d = OpportunityDetector()
        let commands = ["vim", "/usr/bin/ssh", "claude", "python3", "tail", "fzf"].enumerated().map {
            RunningCommand(shellPID: "\($0.offset)", command: $0.element, startedAt: t0)
        }
        #expect(d.evaluate(snapshot(at: t0.plus(minutes: 2), commands: commands), now: t0.plus(minutes: 2)).isEmpty)
        #expect(CommandDenylist.contains("/opt/homebrew/bin/nvim"))
        #expect(!CommandDenylist.contains("cargo"))
    }

    @Test func eachCommandRunCountsOnce() {
        var d = OpportunityDetector()
        let first = RunningCommand(shellPID: "1", command: "make", startedAt: t0)
        let other = RunningCommand(shellPID: "2", command: "cargo", startedAt: t0.plus(seconds: 5))
        let found = d.evaluate(snapshot(at: t0.plus(seconds: 30), commands: [other, first]), now: t0.plus(seconds: 30))
        #expect(found.map(\.commandName) == ["make", "cargo"])
        // The same shell runs make again later: a new run, a new opportunity.
        let again = RunningCommand(shellPID: "1", command: "make", startedAt: t0.plus(minutes: 2))
        #expect(d.evaluate(snapshot(at: t0.plus(minutes: 2, seconds: 25), commands: [again]), now: t0.plus(minutes: 2, seconds: 25)).count == 1)
        #expect(d.raisedCommands.count == 1)
    }

    // MARK: typingPause

    let overdue = (screen: 30.0 * 60, still: 10.0 * 60)

    @Test func typingPauseAfterEightQuietSecondsWhenWellOverdue() throws {
        var d = OpportunityDetector()
        #expect(d.evaluate(snapshot(at: t0, keyIdle: 7.9, screen: overdue.screen), now: t0).isEmpty)
        let found = d.evaluate(snapshot(at: t0.plus(seconds: 0.1), keyIdle: 8, screen: overdue.screen), now: t0.plus(seconds: 0.1))
        let opportunity = try #require(found.first)
        #expect(opportunity.kind == .typingPause && opportunity.source == nil)
        #expect(d.typingPauseRaised)
    }

    @Test func atMostOnePerTypingPause() {
        var d = OpportunityDetector()
        var count = 0
        // A 2-minute pause, sampled every second, key pressed at t0.
        for second in stride(from: 8.0, through: 120, by: 1) {
            count += d.evaluate(snapshot(at: t0.plus(seconds: second), keyIdle: second, screen: overdue.screen),
                                now: t0.plus(seconds: second)).count
        }
        #expect(count == 1)
        // Typing again re-arms it.
        _ = d.evaluate(snapshot(at: t0.plus(seconds: 121), keyIdle: 0.5, screen: overdue.screen), now: t0.plus(seconds: 121))
        #expect(!d.typingPauseRaised)
        #expect(d.evaluate(snapshot(at: t0.plus(seconds: 130), keyIdle: 9, screen: overdue.screen), now: t0.plus(seconds: 130)).count == 1)
    }

    @Test func aKeyPressBetweenTwoLooksReArms() {
        var d = OpportunityDetector()
        #expect(d.evaluate(snapshot(at: t0, keyIdle: 10, screen: overdue.screen), now: t0).count == 1)
        // 20 s later (e.g. the Mac was busy): a key was pressed 9 s ago, so this is a new pause.
        #expect(d.evaluate(snapshot(at: t0.plus(seconds: 20), keyIdle: 9, screen: overdue.screen), now: t0.plus(seconds: 20)).count == 1)
    }

    @Test func typingPauseNeedsOnePointFiveTimesACadence() {
        var d = OpportunityDetector()
        #expect(d.evaluate(snapshot(at: t0, keyIdle: 20, screen: 29.9 * 60, still: 74.9 * 60), now: t0).isEmpty)
        var e = OpportunityDetector()
        #expect(e.evaluate(snapshot(at: t0, keyIdle: 20, still: 75 * 60), now: t0).count == 1)
    }

    @Test func noTypingPauseInStrictModeAwayOrDuringABreak() {
        var strict = Settings()
        strict.strictAgentOnly = true
        var a = OpportunityDetector()
        #expect(a.evaluate(snapshot(at: t0, keyIdle: 20, screen: overdue.screen, settings: strict), now: t0).isEmpty)
        var b = OpportunityDetector()
        #expect(b.evaluate(snapshot(at: t0, keyIdle: 20, screen: overdue.screen,
                                    presence: .away(since: t0, cause: .locked)), now: t0).isEmpty)
        var c = OpportunityDetector()
        #expect(c.evaluate(snapshot(at: t0, keyIdle: 20, screen: overdue.screen, surfaceVisible: true), now: t0).isEmpty)
        // Not consumed: once the surface is gone, the same pause can still produce one.
        #expect(c.evaluate(snapshot(at: t0.plus(seconds: 1), keyIdle: 21, screen: overdue.screen), now: t0.plus(seconds: 1)).count == 1)
    }
}

extension Date {
    func plus(minutes: Double, seconds: Double) -> Date { addingTimeInterval(minutes * 60 + seconds) }
}
