import Foundation
import Testing
@testable import BreakpointCore

@Suite("What the tracker keeps for the resume card (SPEC §2.6, §3.5)")
struct RunReportTests {
    let t0 = Fixture.date(10)
    let key = SessionKey(source: .claudeCode, sessionID: "s1")

    func ev(_ kind: AgentEventKind, detail: String? = nil, message: String? = nil, tool: AgentToolKind? = nil,
            reason: String? = nil, at minutes: Double) -> AgentEvent {
        AgentEvent(kind: kind, source: .claudeCode, sessionID: "s1", cwd: "/Users/dev/breakpoint", detail: detail,
                   timestamp: t0.plus(seconds: minutes * 60), message: message, tool: tool, reason: reason)
    }

    func apply(_ t: inout SessionTracker, _ event: AgentEvent) -> TrackerUpdate {
        t.apply(event, now: event.timestamp)
    }

    func session(_ t: SessionTracker) -> AgentSession? { t.sessions.first { $0.key == key } }

    // MARK: Background work

    @Test func aStopWithBackgroundWorkKeepsTheSessionWorking() throws {
        var t = SessionTracker()
        _ = apply(&t, ev(.agentStarted, at: 0))
        let paused = apply(&t, ev(.agentFinished, detail: HookPayloadParser.backgroundDetail, message: "Tests are running", at: 3))
        #expect(paused.transitions.isEmpty)
        #expect(session(t)?.state == .working && session(t)?.lastRunEnding == nil)
        #expect(t.estimator.runs[.claudeCode] == nil)
        // The real end, later: one run, measured from the prompt.
        let done = apply(&t, ev(.agentFinished, message: "All 214 tests pass.", at: 9))
        #expect(done.transitions == [.runEnded(key, .finished(duration: 9 * 60))])
        #expect(session(t)?.report.message == "All 214 tests pass.")
        #expect(t.estimator.runs[.claudeCode] == [TimeInterval]([9 * 60]))
    }

    @Test func aBackgroundStopWhileWaitingMeansWorkingAgain() {
        var t = SessionTracker()
        _ = apply(&t, ev(.agentStarted, at: 0))
        _ = apply(&t, ev(.agentNeedsUser, tool: .command, at: 1))
        let u = apply(&t, ev(.agentFinished, detail: HookPayloadParser.backgroundDetail, at: 2))
        #expect(u.transitions == [.resumedWorking(key)])
        #expect(session(t)?.state == .working && session(t)?.report.request == nil)
    }

    @Test func aBackgroundStopRevivesARunTheFallbackIdled() {
        var t = SessionTracker()
        _ = apply(&t, ev(.agentStarted, at: 0))
        _ = t.expire(now: t0.plus(minutes: 10))
        #expect(session(t)?.state == .idle)
        let u = apply(&t, ev(.agentFinished, detail: HookPayloadParser.backgroundDetail, at: 12))
        #expect(u.transitions == [.resumedWorking(key)] && session(t)?.state == .working)
    }

    // MARK: Messages, failures and requests

    @Test func finishedRunsKeepTheLastMessageOnlyWithSnippetsOn() {
        var on = SessionTracker()
        _ = apply(&on, ev(.agentStarted, at: 0))
        _ = apply(&on, ev(.agentFinished, message: "Fixed the redirect.", at: 6))
        #expect(on.sessions.first?.report.message == "Fixed the redirect.")

        var off = SessionTracker(storePromptSnippets: false)
        _ = apply(&off, ev(.agentStarted, at: 0))
        _ = apply(&off, ev(.agentFinished, message: "Fixed the redirect.", at: 6))
        #expect(off.sessions.first?.report.message == nil)

        // Turning the setting off forgets what was kept.
        on.storePromptSnippets = false
        #expect(on.sessions.first?.report.message == nil)
    }

    @Test func failedRunsKeepTheReason() {
        var t = SessionTracker(storePromptSnippets: false)
        _ = apply(&t, ev(.agentStarted, at: 0))
        let u = apply(&t, ev(.agentFinished, detail: "error", reason: "rate_limit", at: 2))
        #expect(u.transitions == [.runEnded(key, .failed)])
        #expect(session(t)?.report.failure == "rate_limit" && session(t)?.report.message == nil)
    }

    @Test func aWaitingAgentsRequestIsKeptUntilItMovesOn() throws {
        var t = SessionTracker()
        _ = apply(&t, ev(.agentStarted, at: 0))
        _ = apply(&t, ev(.agentNeedsUser, message: "npm install", tool: .command, at: 1))
        #expect(session(t)?.report.request == AgentRequest(tool: .command, subject: "npm install"))
        // The permission notification ~6 s later names no tool: the request stays.
        _ = apply(&t, ev(.agentNeedsUser, detail: "permission_prompt", at: 1.1))
        #expect(session(t)?.report.request == AgentRequest(tool: .command, subject: "npm install"))
        // Approved: working again, the request is gone.
        let resumed = apply(&t, ev(.agentActivity, tool: .command, at: 2))
        #expect(resumed.transitions == [.resumedWorking(key)])
        #expect(session(t)?.report.request == nil && session(t)?.report.commands == 1)
        // Asked again, then the run ends: no stale request on the finished run.
        _ = apply(&t, ev(.agentNeedsUser, tool: .edit, at: 3))
        _ = apply(&t, ev(.agentFinished, at: 4))
        #expect(session(t)?.report.request == nil)
    }

    @Test func requestSubjectsNeedSnippets() {
        var t = SessionTracker(storePromptSnippets: false)
        _ = apply(&t, ev(.agentStarted, at: 0))
        _ = apply(&t, ev(.agentNeedsUser, message: "npm install", tool: .command, at: 1))
        #expect(session(t)?.report.request == AgentRequest(tool: .command, subject: nil))

        var on = SessionTracker()
        _ = apply(&on, ev(.agentStarted, at: 0))
        _ = apply(&on, ev(.agentNeedsUser, message: "npm install", tool: .command, at: 1))
        on.storePromptSnippets = false
        #expect(on.sessions.first?.report.request == AgentRequest(tool: .command, subject: nil))
    }

    // MARK: Counts

    @Test func editsAndCommandsAreCountedPerRun() {
        var t = SessionTracker()
        _ = apply(&t, ev(.agentStarted, at: 0))
        for (i, tool) in [AgentToolKind.edit, .edit, .command, .fetch, .edit].enumerated() {
            _ = apply(&t, ev(.agentActivity, tool: tool, at: 0.1 * Double(i + 1)))
        }
        _ = apply(&t, ev(.agentActivity, at: 0.8))
        _ = apply(&t, ev(.agentFinished, at: 1))
        #expect(session(t)?.report.edits == 3 && session(t)?.report.commands == 1)
        // A late heartbeat after the stop does not count; a new prompt starts afresh.
        _ = apply(&t, ev(.agentActivity, tool: .edit, at: 1.1))
        #expect(session(t)?.report.edits == 3)
        _ = apply(&t, ev(.agentStarted, at: 2))
        #expect(session(t)?.report == .empty)
    }

    // MARK: Shell commands

    @Test func commandResultsCarryExitStatusAndDuration() throws {
        var t = SessionTracker()
        let start = Make.event(.commandStarted, .shell, session: "4242", title: "swift", at: t0)
        _ = t.apply(start, now: t0)
        let command = try #require(t.commands.first)
        var finish = Make.event(.commandFinished, .shell, session: "4242", title: "swift", at: t0.plus(minutes: 4))
        finish.exitCode = 1
        finish.durationMS = 241_500
        let u = t.apply(finish, now: t0.plus(minutes: 4))
        #expect(u.transitions == [.commandFinished(command, CommandResult(exitCode: 1, duration: 241.5))])

        // Without the shell's own measurement: the time since it started.
        _ = t.apply(Make.event(.commandStarted, .shell, session: "7", title: "cargo", at: t0), now: t0)
        let other = try #require(t.commands.first)
        let v = t.apply(Make.event(.commandFinished, .shell, session: "7", at: t0.plus(seconds: 90)), now: t0.plus(seconds: 90))
        #expect(v.transitions == [.commandFinished(other, CommandResult(exitCode: nil, duration: 90))])
    }

    @Test func replacedAndExpiredCommandsHaveNoResult() throws {
        var t = SessionTracker()
        _ = t.apply(Make.event(.commandStarted, .shell, session: "1", title: "make", at: t0), now: t0)
        let make = try #require(t.commands.first)
        let replaced = t.apply(Make.event(.commandStarted, .shell, session: "1", title: "cargo", at: t0.plus(minutes: 1)),
                               now: t0.plus(minutes: 1))
        #expect(replaced.transitions.first == .commandFinished(make, nil))
        let expired = t.expire(now: t0.plus(minutes: 61))
        #expect(expired.transitions.count == 1)
        if case .commandFinished(_, let result) = expired.transitions.first { #expect(result == nil) }
    }
}
