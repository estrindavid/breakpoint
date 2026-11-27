import Foundation
import Testing
@testable import BreakpointCore

@Suite("Resume card wording (SPEC §3.5)")
struct ResumeFactsTests {
    let t0 = Fixture.date(10)

    func idle(_ ending: RunEnding?, report: RunReport = .empty, title: String? = "fix the login redirect") -> AgentSession {
        AgentSession(key: SessionKey(source: .claudeCode, sessionID: "s1"), state: .idle, cwd: "/Users/dev/breakpoint",
                     title: title, createdAt: t0, lastRunEnding: ending, report: report)
    }

    // MARK: One session

    @Test func finishedSaysWhatTheAgentSaid() throws {
        let report = RunReport(edits: 7, commands: 12, message: "Fixed the redirect; all 214 tests pass.")
        let facts = try #require(ResumeFacts.session(idle(.finished(duration: 6 * 60), report: report), keepSnippets: true))
        #expect(facts.headline == "Claude finished · ran 6 min")
        #expect(facts.folder == "breakpoint")
        #expect(facts.detail == ResumeLine("Fixed the redirect; all 214 tests pass."))
        #expect(!facts.failed && !facts.needsYou)
    }

    @Test func withSnippetsOffTheCardStillSaysWhatHappened() throws {
        let report = RunReport(edits: 7, commands: 12, message: "Fixed the redirect; all 214 tests pass.")
        let facts = try #require(ResumeFacts.session(idle(.finished(duration: 6 * 60), report: report), keepSnippets: false))
        #expect(facts.message == nil && facts.snippet == nil)
        #expect(facts.headline == "Claude finished · ran 6 min")
        #expect(facts.detail == ResumeLine("7 edits · 12 commands"))
        // Nothing to count: no supporting line at all.
        let bare = try #require(ResumeFacts.session(idle(.finished(duration: 60)), keepSnippets: false))
        #expect(bare.detail == nil)
    }

    @Test func withoutAMessageThePromptSnippetLabelsTheRun() throws {
        let facts = try #require(ResumeFacts.session(idle(.finished(duration: 60), report: RunReport(edits: 1)), keepSnippets: true))
        #expect(facts.detail == ResumeLine("fix the login redirect"))
    }

    @Test(arguments: [
        ("rate_limit", "Claude hit the usage limit", "usage limit"),
        ("authentication_failed", "Claude could not sign in", "sign-in"),
        ("server_error", "Claude stopped: server error", "error"),
        ("max_output_tokens", "Claude stopped: reply too long", "error"),
        ("billing_error", "Claude stopped: billing problem", "error"),
        ("something_new", "Claude stopped with an error", "error"),
    ])
    func failuresInPlainWords(_ reason: String, _ headline: String, _ short: String) throws {
        let facts = try #require(ResumeFacts.session(idle(.failed, report: RunReport(failure: reason)), keepSnippets: false))
        #expect(facts.headline == headline && facts.shortStatus == short && facts.failed)
        #expect(!facts.headline.contains("_"))
    }

    @Test func aFailureWithoutAReason() throws {
        let facts = try #require(ResumeFacts.session(idle(.failed), keepSnippets: true))
        #expect(facts.headline == "Claude stopped with an error")
        #expect(facts.detail == ResumeLine("fix the login redirect"))
    }

    @Test func nothingToSayForWorkingOrCancelledSessions() {
        var working = idle(nil)
        working.state = .working
        #expect(ResumeFacts.session(working, keepSnippets: true) == nil)
        #expect(ResumeFacts.session(idle(.cancelled), keepSnippets: true) == nil)
        #expect(ResumeFacts.session(idle(nil), keepSnippets: true) == nil)
    }

    // MARK: Needs you

    @Test(arguments: [
        (AgentToolKind.command, "npm install", "Wants to run", "npm install", "Wants to run a command"),
        (.edit, "Auth.swift", "Wants to edit", "Auth.swift", "Wants to edit a file"),
        (.fetch, "example.com", "Wants to open", "example.com", "Wants to open a web page"),
        (.question, "Which database?", "Has a question for you", nil, "Has a question for you"),
        (.plan, nil, "Has a plan for you to review", nil, "Has a plan for you to review"),
        (.other, nil, "Wants to use a tool", nil, "Wants to use a tool"),
    ] as [(AgentToolKind, String?, String, String?, String)])
    func needsYouSaysWhatItWants(_ tool: AgentToolKind, _ subject: String?, _ text: String, _ code: String?, _ privateText: String) throws {
        var session = idle(nil, report: RunReport(request: AgentRequest(tool: tool, subject: subject)))
        session.state = .waiting
        let open = try #require(ResumeFacts.session(session, keepSnippets: true))
        #expect(open.headline == "Claude needs you" && open.needsYou && open.sortRank == 0)
        #expect(open.detail == ResumeLine(text, code: code))
        let closed = try #require(ResumeFacts.session(session, keepSnippets: false))
        #expect(closed.detail == ResumeLine(privateText))
    }

    // MARK: Shell commands

    func command(exit: Int?, seconds: TimeInterval) -> ResumeFacts {
        let running = RunningCommand(shellPID: "4242", command: "swift", cwd: "/Users/dev/breakpoint", startedAt: t0)
        return ResumeFacts.command(running, result: CommandResult(exitCode: exit, duration: seconds))
    }

    @Test func longCommandsSayHowTheyEnded() {
        let failed = command(exit: 1, seconds: 4 * 60 + 10)
        #expect(failed.headline == "swift failed after 4 min" && failed.failed && failed.shortStatus == "failed")
        #expect(failed.folder == "breakpoint" && failed.detail == nil)
        let ok = command(exit: 0, seconds: 6 * 60)
        #expect(ok.headline == "swift finished in 6 min" && !ok.failed && ok.shortStatus == "6 min")
        #expect(command(exit: nil, seconds: 45).headline == "swift finished in 45 s")
    }

    @Test func onlyLongUninterruptedCommandsAreShown() {
        #expect(!ResumeFacts.commandIsWorthShowing(CommandResult(exitCode: 0, duration: Timing.longCommandDelay - 1)))
        #expect(ResumeFacts.commandIsWorthShowing(CommandResult(exitCode: 0, duration: Timing.longCommandDelay)))
        #expect(ResumeFacts.commandIsWorthShowing(CommandResult(exitCode: 2, duration: 600)))
        #expect(!ResumeFacts.commandIsWorthShowing(CommandResult(exitCode: CommandResult.interruptedExitCode, duration: 600)))
    }

    // MARK: Several rows

    @Test func severalRowsTitles() throws {
        let finished = try #require(ResumeFacts.session(idle(.finished(duration: 60)), keepSnippets: true))
        var waitingSession = idle(nil)
        waitingSession.state = .waiting
        let waiting = try #require(ResumeFacts.session(waitingSession, keepSnippets: true))
        let failedCommand = command(exit: 1, seconds: 300)
        #expect(Copy.resumeSeveralTitle([finished, finished]) == "2 agents finished")
        #expect(Copy.resumeSeveralTitle([finished, waiting]) == "Claude needs you")
        #expect(Copy.resumeSeveralTitle([waiting, waiting, finished]) == "2 agents need you")
        #expect(Copy.resumeSeveralTitle([failedCommand, failedCommand]) == "2 commands finished")
        #expect(Copy.resumeSeveralTitle([finished, failedCommand, finished]) == "3 runs finished")
        #expect([finished, failedCommand, waiting].map(\.sortRank) == [2, 1, 0])
        #expect(waiting.shortStatus == "needs you" && finished.shortStatus == "1 min")
    }

    @Test func countsWording() {
        #expect(Copy.resumeCounts(edits: 0, commands: 0) == nil)
        #expect(Copy.resumeCounts(edits: 1, commands: 0) == "1 edit")
        #expect(Copy.resumeCounts(edits: 0, commands: 1) == "1 command")
        #expect(Copy.resumeCounts(edits: 3, commands: 2) == "3 edits · 2 commands")
    }

    @Test func noExclamationsOrShouldAnywhere() {
        var lines: [String] = []
        for reason in ["rate_limit", "authentication_failed", "billing_error", "account_on_hold", "server_error",
                       "max_output_tokens", "model_not_found", "invalid_request", "unknown"] {
            lines.append(Copy.resumeFailureTitle(agent: "Claude", reason: reason))
        }
        for tool in AgentToolKind.allCases {
            lines.append(Copy.resumeRequestLine(AgentRequest(tool: tool)).plain)
        }
        lines.append(Copy.resumeCommandTitle(command: "swift", result: CommandResult(exitCode: 1, duration: 300)))
        for line in lines {
            #expect(!line.contains("!") && !line.lowercased().contains("should"), "\(line)")
        }
    }
}
