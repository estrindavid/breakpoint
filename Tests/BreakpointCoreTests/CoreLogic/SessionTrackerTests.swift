import Foundation
import Testing
@testable import BreakpointCore

@Suite("SessionTracker state machine (SPEC §2.6)")
struct SessionTrackerTests {
    let t0 = Fixture.date(10)
    let key = SessionKey(source: .claudeCode, sessionID: "s1")

    func ev(_ kind: AgentEventKind, _ source: AgentSource = .claudeCode, session: String? = "s1", title: String? = nil,
            detail: String? = nil, via: String? = nil, cwd: String? = "/Users/dev/breakpoint", at: Date) -> AgentEvent {
        Make.event(kind, source, session: session, cwd: cwd, title: title, detail: detail, via: via, at: at)
    }

    func session(_ tracker: SessionTracker, _ key: SessionKey? = nil) -> AgentSession? {
        tracker.sessions.first { $0.key == (key ?? self.key) }
    }

    // MARK: Transitions

    @Test func sessionStartedCreatesAnIdleSession() throws {
        var t = SessionTracker()
        let u = t.apply(ev(.sessionStarted, at: t0), now: t0)
        #expect(u.transitions == [.sessionStarted(key)] && u.opportunity == nil && !u.dropped)
        let s = try #require(session(t))
        #expect(s.state == .idle && s.cwd == "/Users/dev/breakpoint" && s.createdAt == t0 && s.projectName == "breakpoint")
        // Again (Claude Code sends it after compaction, even mid-run): refresh only.
        _ = t.apply(ev(.agentStarted, at: t0.plus(seconds: 5)), now: t0.plus(seconds: 5))
        let again = t.apply(ev(.sessionStarted, at: t0.plus(seconds: 50)), now: t0.plus(seconds: 50))
        #expect(again.transitions.isEmpty)
        #expect(session(t)?.state == .working && session(t)?.lastEventAt == t0.plus(seconds: 50))
    }

    @Test func agentStartedStartsARunAndRaisesAnOpportunity() throws {
        var t = SessionTracker()
        let u = t.apply(ev(.agentStarted, title: "fix the login redirect", at: t0), now: t0)
        #expect(u.transitions == [.sessionStarted(key), .runStarted(key)])
        let opportunity = try #require(u.opportunity)
        #expect(opportunity.kind == .agentStarted && opportunity.source == .claudeCode && opportunity.sessionID == "s1")
        #expect(opportunity.sessionKey == key && opportunity.createdAt == t0 && opportunity.expiresAt == t0.plus(seconds: 30))
        let s = try #require(session(t))
        #expect(s.state == .working && s.runStartedAt == t0 && s.title == "fix the login redirect")
    }

    @Test func aNewPromptWhileWorkingCancelsThePreviousRun() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        let u = t.apply(ev(.agentStarted, title: "actually, do this", at: t0.plus(minutes: 3)), now: t0.plus(minutes: 3))
        #expect(u.transitions == [.runEnded(key, .cancelled), .runStarted(key)])
        #expect(u.opportunity != nil)
        #expect(t.estimator.runs.isEmpty)
        #expect(session(t)?.runStartedAt == t0.plus(minutes: 3))
    }

    @Test func activityRefreshesAndApprovalResumesWork() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        #expect(t.apply(ev(.agentActivity, at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1)).transitions.isEmpty)
        #expect(session(t)?.lastEventAt == t0.plus(minutes: 1))
        #expect(t.apply(ev(.agentNeedsUser, detail: "permission_prompt", at: t0.plus(minutes: 2)), now: t0.plus(minutes: 2)).transitions
                == [.needsUser(key)])
        #expect(session(t)?.state == .waiting && session(t)?.waitingSince == t0.plus(minutes: 2))
        // A second prompt while already waiting is not news.
        #expect(t.apply(ev(.agentNeedsUser, detail: "permission_prompt", at: t0.plus(minutes: 3)), now: t0.plus(minutes: 3)).transitions.isEmpty)
        #expect(t.apply(ev(.agentActivity, at: t0.plus(minutes: 6)), now: t0.plus(minutes: 6)).transitions == [.resumedWorking(key)])
        #expect(session(t)?.state == .working && session(t)?.waitingSince == nil)
    }

    @Test func idlePromptOnlyMattersWhileWorking() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        _ = t.apply(ev(.agentFinished, at: t0.plus(minutes: 2)), now: t0.plus(minutes: 2))
        // Claude Code sends idle_prompt a minute after a normal stop: ignored.
        let ignored = t.apply(ev(.agentNeedsUser, detail: "idle_prompt", at: t0.plus(minutes: 3)), now: t0.plus(minutes: 3))
        #expect(ignored.transitions.isEmpty && session(t)?.state == .idle)
        // While working it is a likely interrupt: the session needs the user.
        _ = t.apply(ev(.agentStarted, at: t0.plus(minutes: 5)), now: t0.plus(minutes: 5))
        let interrupted = t.apply(ev(.agentNeedsUser, detail: "idle_prompt", at: t0.plus(minutes: 6)), now: t0.plus(minutes: 6))
        #expect(interrupted.transitions == [.needsUser(key)] && session(t)?.state == .waiting)
        // On an unknown session: dropped.
        var fresh = SessionTracker()
        #expect(fresh.apply(ev(.agentNeedsUser, detail: "idle_prompt", at: t0), now: t0).dropped)
        #expect(fresh.sessions.isEmpty)
    }

    @Test func finishedRunsAreRecordedAndEndTheRun() throws {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        let u = t.apply(ev(.agentFinished, at: t0.plus(minutes: 6)), now: t0.plus(minutes: 6))
        #expect(u.transitions == [.runEnded(key, .finished(duration: 360))])
        let s = try #require(session(t))
        #expect(s.state == .idle && s.runStartedAt == nil && s.lastRunEnding == .finished(duration: 360))
        #expect(s.lastRunEndedAt == t0.plus(minutes: 6))
        #expect(t.estimator.runs[.claudeCode] == [360])
        #expect(t.expectedRunLength(for: .claudeCode) == 360)
        #expect(Copy.resumeTitle(agent: s.displayName, ending: s.lastRunEnding!) == "Claude finished · ran 6 min")
    }

    struct EndingCase: Sendable, CustomTestStringConvertible {
        let detail: String?
        let ending: RunEnding
        let recorded: Bool
        var testDescription: String { detail ?? "nil" }
    }

    static let endings: [EndingCase] = [
        EndingCase(detail: nil, ending: .finished(duration: 120), recorded: true),
        EndingCase(detail: "completed", ending: .finished(duration: 120), recorded: true),
        EndingCase(detail: "aborted", ending: .cancelled, recorded: false),
        EndingCase(detail: "interrupted", ending: .cancelled, recorded: false),
        EndingCase(detail: "error", ending: .failed, recorded: false),
        EndingCase(detail: "Error", ending: .failed, recorded: false),
    ]

    @Test(arguments: endings)
    func agentFinishedDetails(_ row: EndingCase) {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, .cursor, at: t0), now: t0)
        let u = t.apply(ev(.agentFinished, .cursor, detail: row.detail, at: t0.plus(minutes: 2)), now: t0.plus(minutes: 2))
        let cursorKey = SessionKey(source: .cursor, sessionID: "s1")
        #expect(u.transitions == [.runEnded(cursorKey, row.ending)])
        #expect((t.estimator.runs[.cursor] != nil) == row.recorded)
    }

    @Test func timeWaitingForTheUserIsNotRunTime() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        _ = t.apply(ev(.agentNeedsUser, detail: "permission_prompt", at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1))
        _ = t.apply(ev(.agentActivity, at: t0.plus(minutes: 11)), now: t0.plus(minutes: 11))
        let u = t.apply(ev(.agentFinished, at: t0.plus(minutes: 13)), now: t0.plus(minutes: 13))
        // The card says how long it ran on the clock; the estimator learns the 3 working minutes.
        #expect(u.transitions == [.runEnded(key, .finished(duration: 13 * 60))])
        #expect(t.estimator.runs[.claudeCode] == [180])
    }

    @Test func finishingWhileWaitingEndsTheWait() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        _ = t.apply(ev(.agentNeedsUser, detail: "permission_prompt", at: t0.plus(minutes: 2)), now: t0.plus(minutes: 2))
        let u = t.apply(ev(.agentFinished, at: t0.plus(minutes: 5)), now: t0.plus(minutes: 5))
        #expect(u.transitions == [.runEnded(key, .finished(duration: 300))])
        #expect(t.estimator.runs[.claudeCode] == [120])
        #expect(session(t)?.waitingSince == nil)
    }

    @Test func subagentFinishedOnlyRefreshes() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        let u = t.apply(ev(.subagentFinished, at: t0.plus(minutes: 9)), now: t0.plus(minutes: 9))
        #expect(u.transitions.isEmpty && session(t)?.state == .working && session(t)?.lastEventAt == t0.plus(minutes: 9))
        var fresh = SessionTracker()
        #expect(fresh.apply(ev(.subagentFinished, at: t0), now: t0).dropped)
    }

    @Test func sessionEndedRemoves() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        #expect(t.apply(ev(.sessionEnded, at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1)).transitions == [.sessionEnded(key)])
        #expect(t.sessions.isEmpty)
        #expect(t.apply(ev(.sessionEnded, at: t0.plus(minutes: 2)), now: t0.plus(minutes: 2)).dropped)
    }

    @Test func testEventsAreDropped() {
        var t = SessionTracker()
        #expect(t.apply(ev(.test, at: t0), now: t0).dropped)
        #expect(t.sessions.isEmpty)
    }

    @Test func eventsForAnUnknownSessionMidRunCreateIt() {
        // The app started (or relaunched) while an agent was already running.
        var t = SessionTracker()
        let u = t.apply(ev(.agentActivity, at: t0), now: t0)
        #expect(u.transitions == [.sessionStarted(key), .resumedWorking(key)] && u.opportunity == nil)
        #expect(session(t)?.state == .working)
        _ = t.apply(ev(.agentFinished, at: t0.plus(minutes: 4)), now: t0.plus(minutes: 4))
        // Its start was never seen, so its length is unknown: not recorded.
        #expect(t.estimator.runs.isEmpty)
        #expect(session(t)?.lastRunEnding == .finished(duration: 240))

        var w = SessionTracker()
        #expect(w.apply(ev(.agentNeedsUser, detail: "permission_prompt", at: t0), now: t0).transitions
                == [.sessionStarted(key), .needsUser(key)])
        var f = SessionTracker()
        #expect(f.apply(ev(.agentFinished, at: t0), now: t0).transitions == [.sessionStarted(key)])
        #expect(f.sessions.first?.state == .idle)
    }

    @Test func aLateHookAfterFinishingDoesNotRestartTheRun() {
        // Async hooks can arrive out of order: a PostToolUse after the Stop.
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        _ = t.apply(ev(.agentFinished, at: t0.plus(minutes: 2)), now: t0.plus(minutes: 2))
        #expect(t.apply(ev(.agentActivity, at: t0.plus(minutes: 2, seconds: 1)), now: t0.plus(minutes: 2, seconds: 1)).transitions.isEmpty)
        #expect(session(t)?.state == .idle)
        // A duplicate Stop: nothing.
        #expect(t.apply(ev(.agentFinished, at: t0.plus(minutes: 3)), now: t0.plus(minutes: 3)).transitions.isEmpty)
        #expect(t.estimator.runs[.claudeCode]?.count == 1)
    }

    @Test func promptSnippetsFollowThePrivacySetting() {
        var t = SessionTracker(storePromptSnippets: false)
        _ = t.apply(ev(.agentStarted, title: "secret plan", at: t0), now: t0)
        #expect(session(t)?.title == nil)
        t.storePromptSnippets = true
        _ = t.apply(ev(.agentStarted, title: "first line\nsecond line", at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1))
        #expect(session(t)?.title == "first line")
        t.storePromptSnippets = false
        #expect(session(t)?.title == nil)
    }

    @Test func folderComesFromTheLatestEventThatHasOne() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, cwd: "/Users/dev/one", at: t0), now: t0)
        _ = t.apply(ev(.agentActivity, cwd: nil, at: t0.plus(seconds: 5)), now: t0.plus(seconds: 5))
        #expect(session(t)?.cwd == "/Users/dev/one")
        _ = t.apply(ev(.agentActivity, cwd: "/Users/dev/two", at: t0.plus(seconds: 9)), now: t0.plus(seconds: 9))
        #expect(session(t)?.projectName == "two")
    }

    @Test func sessionsWithoutAnIDShareOnePerFolder() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, "my-tool", session: nil, cwd: "/Users/dev/x", at: t0), now: t0)
        _ = t.apply(ev(.agentFinished, "my-tool", session: nil, cwd: "/Users/dev/x", at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1))
        #expect(t.sessions.count == 1)
        #expect(t.sessions[0].displayName == "my-tool")
        #expect(t.estimator.runs[AgentSource("my-tool")] == [60])
    }

    // MARK: Relayed duplicates (SPEC §5.4)

    @Test func relayedCursorEventsAreDroppedOnlyWhenNativeHooksAreInstalled() {
        let relayed = ev(.agentStarted, .cursor, via: AgentEvent.viaClaudeCodeHooks, at: t0)
        var native = SessionTracker(nativeCursorInstalled: true)
        let dropped = native.apply(relayed, now: t0)
        #expect(dropped.dropped && dropped.opportunity == nil && native.sessions.isEmpty)
        // The native event itself is accepted.
        #expect(!native.apply(ev(.agentStarted, .cursor, at: t0), now: t0).dropped)

        var relayOnly = SessionTracker(nativeCursorInstalled: false)
        let accepted = relayOnly.apply(relayed, now: t0)
        #expect(!accepted.dropped && accepted.opportunity != nil)
        #expect(relayOnly.sessions.first?.via == AgentEvent.viaClaudeCodeHooks)
        // Claude Code's own events with via set are never dropped.
        #expect(!native.apply(ev(.agentStarted, .claudeCode, via: AgentEvent.viaClaudeCodeHooks, at: t0), now: t0).dropped)
    }

    // MARK: Interrupt fallback and expiry

    @Test func claudeCodeSessionsGoIdleAfterTenSilentMinutes() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        _ = t.apply(ev(.agentActivity, at: t0.plus(minutes: 2)), now: t0.plus(minutes: 2))
        #expect(t.expire(now: t0.plus(minutes: 11.9)) == .none)
        let u = t.expire(now: t0.plus(minutes: 12))
        #expect(u.transitions == [.runEnded(key, .cancelled)])
        #expect(session(t)?.state == .idle && t.estimator.runs.isEmpty)
        #expect(t.expire(now: t0.plus(minutes: 13)) == .none)
    }

    @Test func otherSourcesGetAnHour() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, .codex, at: t0), now: t0)
        #expect(t.expire(now: t0.plus(minutes: 59.9)) == .none)
        #expect(t.expire(now: t0.plus(minutes: 60)).transitions == [.runEnded(SessionKey(source: .codex, sessionID: "s1"), .cancelled)])
    }

    @Test func waitingSessionsDoNotTimeOutAsInterrupted() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        _ = t.apply(ev(.agentNeedsUser, detail: "permission_prompt", at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1))
        #expect(t.expire(now: t0.plus(minutes: 30)) == .none)
        #expect(session(t)?.state == .waiting)
    }

    @Test func aLateFinishAfterTheFallbackIsStillHandled() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        _ = t.expire(now: t0.plus(minutes: 10))
        // A 14-minute tool call finally ends and the run stops normally.
        let u = t.apply(ev(.agentFinished, at: t0.plus(minutes: 14)), now: t0.plus(minutes: 14))
        #expect(u.transitions == [.runEnded(key, .finished(duration: 14 * 60))])
        // Discarded by the fallback: not trusted for the estimator.
        #expect(t.estimator.runs.isEmpty)
    }

    @Test func activityAfterTheFallbackRevivesTheRun() {
        var t = SessionTracker()
        _ = t.apply(ev(.agentStarted, at: t0), now: t0)
        _ = t.expire(now: t0.plus(minutes: 10))
        let u = t.apply(ev(.agentActivity, at: t0.plus(minutes: 12)), now: t0.plus(minutes: 12))
        #expect(u.transitions == [.resumedWorking(key)])
        #expect(session(t)?.state == .working && session(t)?.runStartedAt == t0)
        _ = t.apply(ev(.agentFinished, at: t0.plus(minutes: 15)), now: t0.plus(minutes: 15))
        #expect(session(t)?.lastRunEnding == .finished(duration: 15 * 60))
        #expect(t.estimator.runs.isEmpty)
    }

    @Test func silentSessionsAreRemovedAfterTwoHours() {
        var t = SessionTracker()
        _ = t.apply(ev(.sessionStarted, at: t0), now: t0)
        _ = t.apply(ev(.sessionStarted, session: "s2", at: t0.plus(minutes: 30)), now: t0.plus(minutes: 30))
        #expect(t.expire(now: t0.plus(minutes: 119)) == .none)
        #expect(t.expire(now: t0.plus(minutes: 120)).transitions == [.sessionEnded(key)])
        #expect(t.sessions.map(\.key.sessionID) == ["s2"])
    }

    @Test func sessionsByUrgency() {
        var t = SessionTracker()
        _ = t.apply(ev(.sessionStarted, session: "idle", at: t0.plus(minutes: 9)), now: t0.plus(minutes: 9))
        _ = t.apply(ev(.agentStarted, session: "work-old", at: t0), now: t0)
        _ = t.apply(ev(.agentStarted, session: "work-new", at: t0.plus(minutes: 5)), now: t0.plus(minutes: 5))
        _ = t.apply(ev(.agentStarted, session: "wait", at: t0), now: t0)
        _ = t.apply(ev(.agentNeedsUser, session: "wait", at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1))
        #expect(t.sessionsByUrgency.map(\.key.sessionID) == ["wait", "work-new", "work-old", "idle"])
    }

    // MARK: Shell commands

    @Test func shellCommandsAreTrackedByPID() throws {
        var t = SessionTracker()
        let start = Make.event(.commandStarted, .shell, session: "4242", cwd: "/Users/dev/breakpoint", title: "swift", at: t0)
        let u = t.apply(start, now: t0)
        let command = try #require(t.commands.first)
        #expect(u.transitions == [.commandStarted(command)])
        #expect(command.shellPID == "4242" && command.command == "swift" && command.startedAt == t0 && command.projectName == "breakpoint")
        #expect(t.sessions.isEmpty)
        let done = t.apply(Make.event(.commandFinished, .shell, session: "4242", at: t0.plus(seconds: 30)), now: t0.plus(seconds: 30))
        #expect(done.transitions == [.commandFinished(command, CommandResult(exitCode: nil, duration: 30))] && t.commands.isEmpty)
        #expect(t.apply(Make.event(.commandFinished, .shell, session: "4242", at: t0.plus(seconds: 31)), now: t0.plus(seconds: 31)).dropped)
    }

    @Test func aNewCommandInTheSameShellReplacesTheOld() {
        var t = SessionTracker()
        _ = t.apply(Make.event(.commandStarted, .shell, session: "1", title: "make", at: t0), now: t0)
        let u = t.apply(Make.event(.commandStarted, .shell, session: "1", title: "/usr/bin/cargo build", at: t0.plus(minutes: 1)),
                        now: t0.plus(minutes: 1))
        #expect(u.transitions.count == 2)
        #expect(t.commands.map(\.command) == ["cargo"])
    }

    @Test func interactiveCommandsAndBadEventsAreNotTracked() {
        var t = SessionTracker()
        #expect(t.apply(Make.event(.commandStarted, .shell, session: "1", title: "vim", at: t0), now: t0).dropped)
        #expect(t.apply(Make.event(.commandStarted, .shell, session: nil, title: "make", at: t0), now: t0).dropped)
        #expect(t.apply(Make.event(.commandStarted, .shell, session: "2", title: nil, at: t0), now: t0).dropped)
        #expect(t.commands.isEmpty)
    }

    @Test func commandsExpireAfterAnHour() {
        var t = SessionTracker()
        _ = t.apply(Make.event(.commandStarted, .shell, session: "1", title: "make", at: t0), now: t0)
        #expect(t.expire(now: t0.plus(minutes: 59)) == .none)
        #expect(t.expire(now: t0.plus(minutes: 60)).transitions.count == 1)
        #expect(t.commands.isEmpty)
    }
}

@Suite("RunLengthEstimator (SPEC §2.6, §8)")
struct RunLengthEstimatorTests {
    @Test func defaultIsNinetySeconds() {
        #expect(RunLengthEstimator().expectedRunLength(for: .claudeCode) == 90)
        #expect(RunLengthEstimator().expectedRunLengths.isEmpty)
    }

    @Test func medianOfOddAndEvenCounts() {
        var e = RunLengthEstimator()
        for d in [300.0, 60, 120] { e.record(d, for: .claudeCode) }
        #expect(e.expectedRunLength(for: .claudeCode) == 120)
        e.record(600, for: .claudeCode)
        #expect(e.expectedRunLength(for: .claudeCode) == 210)
        #expect(e.expectedRunLength(for: .codex) == 90)
        #expect(e.expectedRunLengths == [.claudeCode: 210])
    }

    @Test func keepsTheLastTwentyPerSource() {
        var e = RunLengthEstimator()
        for i in 1...25 { e.record(TimeInterval(i), for: .codex) }
        #expect(e.runs[.codex] == (6...25).map(TimeInterval.init))
        #expect(e.expectedRunLength(for: .codex) == 15.5)
    }

    @Test func ignoresNonsense() {
        var e = RunLengthEstimator()
        e.record(0, for: .codex)
        e.record(-5, for: .codex)
        e.record(.infinity, for: .codex)
        e.record(.nan, for: .codex)
        #expect(e.runs.isEmpty)
    }

    @Test func persistsAndToleratesDamage() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        var e = RunLengthEstimator()
        e.record(240, for: .claudeCode)
        e.record(30, for: AgentSource("my-tool"))
        try RunLengthEstimator.file(dir.paths).write(e)
        #expect(RunLengthEstimator.load(dir.paths) == e)
        let text = try String(contentsOf: dir.paths.sessionsFile, encoding: .utf8)
        #expect(text.contains("\"claude-code\""))

        // Bad values are dropped, good ones kept, unknown keys ignored.
        let damaged = #"{"runs":{"codex":[60,"x",null,-1,120],"cursor":"nope"},"future":true}"#
        try Data(damaged.utf8).write(to: dir.paths.sessionsFile)
        let loaded = RunLengthEstimator.load(dir.paths)
        #expect(loaded.runs == [.codex: [60, 120]])

        try Data("not json".utf8).write(to: dir.paths.sessionsFile)
        #expect(RunLengthEstimator.load(dir.paths) == RunLengthEstimator())
        try FileManager.default.removeItem(at: dir.paths.sessionsFile)
        #expect(RunLengthEstimator.load(dir.paths) == RunLengthEstimator())
    }

    @Test func tolerantDecodingKeepsGoodSources() throws {
        let json = #"{"runs":{"codex":[60,"x",null,-1,120],"claude-code":[30]}}"#
        let decoded = try JSONFile<RunLengthEstimator>.decoder.decode(RunLengthEstimator.self, from: Data(json.utf8))
        #expect(decoded.runs == [.codex: [60, 120], .claudeCode: [30]])
    }
}
