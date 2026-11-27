import Foundation
import Testing
@testable import BreakpointCore

/// `breakpoint status --line` (SPEC §5.8): the grammar, the colours, and the command as a prompt
/// runs it, against no app, a fixture app and a hung one.
@Suite("Status line", .serialized)
struct StatusLineTests {
    static let now = Date(timeIntervalSince1970: 1_795_400_000)

    static func session(_ source: AgentSource, _ id: String, _ state: AgentState, ranFor: TimeInterval? = nil) -> StatusReport.Session {
        StatusReport.Session(source: source, sessionID: id, state: state, cwd: "/work/alpha", lastEventAt: now,
                             runStartedAt: ranFor.map { now.addingTimeInterval(-$0) })
    }

    /// A report as the app sends it.
    static func report(next: BreakKind = .eyes, in seconds: TimeInterval = 12 * 60, paused: PauseReason? = nil,
                       sessions: [StatusReport.Session] = [], activeBreak: StatusReport.ActiveBreak? = nil,
                       nudge: StatusReport.Nudge? = nil) -> StatusReport {
        StatusReport(generatedAt: now, sessions: sessions, paused: paused.map { Copy.pauseSentence($0, now: now) },
                     nextBreak: .init(kind: next, seconds: seconds), activeBreak: activeBreak, nudge: nudge)
    }

    static func line(_ report: StatusReport) -> String { StatusLine.render(report) }

    @Test func theNextBreakInTheMenuBarsWords() {
        #expect(Self.line(Self.report()) == "eye rest in 12 min")
        #expect(Self.line(Self.report(next: .move, in: 65 * 60)) == "stretch in 1 h 5 min")
        #expect(Self.line(Self.report(in: 20)) == "eye rest in 1 min", "under a minute rounds up, like the menu bar")
        #expect(Self.line(Self.report(next: .move, in: 0)) == "stretch due")
        #expect(Self.line(Self.report(next: .eyes, in: -300)) == "eye rest due")
    }

    @Test func oneAgentIsNamed() {
        let working = Self.report(sessions: [Self.session(.claudeCode, "s1", .working, ranFor: 190)])
        #expect(Self.line(working) == "eye rest in 12 min · Claude working 3 min")
        let justStarted = Self.report(sessions: [Self.session(.claudeCode, "s1", .working, ranFor: 20)])
        #expect(Self.line(justStarted) == "eye rest in 12 min · Claude working")
        let waiting = Self.report(next: .move, in: 0, sessions: [Self.session(.codex, "c1", .waiting, ranFor: 40)])
        #expect(Self.line(waiting) == "stretch due · Codex needs you")
        let idleOnly = Self.report(sessions: [Self.session(.claudeCode, "s1", .idle)])
        #expect(Self.line(idleOnly) == "eye rest in 12 min", "idle agents are not shown")
    }

    @Test func severalAgentsAreCountedNeedsYouFirst() {
        let mixed = Self.report(next: .move, in: 0, sessions: [
            Self.session(.claudeCode, "s1", .working, ranFor: 10), Self.session(.codex, "c1", .working, ranFor: 20),
            Self.session(.cursor, "u1", .waiting), Self.session(.gemini, "g1", .idle),
        ])
        #expect(Self.line(mixed) == "stretch due · 1 needs you · 2 working")
        let twoWaiting = Self.report(sessions: [Self.session(.claudeCode, "s1", .waiting), Self.session(.codex, "c1", .waiting)])
        #expect(Self.line(twoWaiting) == "eye rest in 12 min · 2 need you")
    }

    @Test func aBreakOnScreenShowsTimeLeft() {
        let onBreak = Self.report(next: .move, in: -60, sessions: [Self.session(.claudeCode, "s1", .working, ranFor: 70)],
                                  activeBreak: .init(kind: .move, startedAt: Self.now.addingTimeInterval(-40), length: 120))
        #expect(Self.line(onBreak) == "stretch 1:20 left · Claude working 1 min")
        let breather = Self.report(activeBreak: .init(kind: .breathe, startedAt: Self.now.addingTimeInterval(-90), length: 60))
        #expect(Self.line(breather) == "breather 0:00 left")
    }

    @Test func aNudgeShowsItsTitleAndAPauseItsSentence() {
        let nudge = Self.report(next: .move, in: -30, sessions: [Self.session(.claudeCode, "s1", .working, ranFor: 2)],
                                nudge: .init(kind: .move, title: "2-min stretch?"))
        #expect(Self.line(nudge) == "2-min stretch? · Claude working")
        #expect(Self.line(Self.report(paused: .call([.microphone]))) == "paused: microphone is on")
        #expect(Self.line(Self.report(next: .move, in: -100, paused: .windDownWrappedUp(until: Self.now.addingTimeInterval(20000))))
            == "paused: wrapped up for tonight", "paused wins over due")
        let withAgent = Self.report(paused: .call([.camera]), sessions: [Self.session(.claudeCode, "s1", .waiting)])
        #expect(Self.line(withAgent) == "paused: camera is on · Claude needs you")
    }

    @Test func precedenceIsBreakThenNudgeThenPauseThenDue() {
        var report = Self.report(next: .move, in: -1, paused: .call([.microphone]),
                                 activeBreak: .init(kind: .eyes, startedAt: Self.now, length: 20),
                                 nudge: .init(kind: .move, title: "2-min stretch?"))
        #expect(Self.line(report) == "eye rest 0:20 left")
        report.activeBreak = nil
        #expect(Self.line(report) == "2-min stretch?")
        report.nudge = nil
        #expect(Self.line(report) == "paused: microphone is on")
        report.paused = nil
        #expect(Self.line(report) == "stretch due")
    }

    @Test func aReplyFromAnOlderAppStillDecodesAndMakesALine() throws {
        let old = StatusReport(generatedAt: Self.now,
                               sessions: [.init(source: .claudeCode, sessionID: "s1", state: .working, cwd: nil, lastEventAt: Self.now)],
                               timers: TimerState(screenTime: 8 * 60, stillTime: 49 * 60),
                               cadence: Settings.defaults.cadence)
        var json = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(old)) as? [String: Any])
        #expect(json["nextBreak"] == nil && json["nudge"] == nil && json["activeBreak"] == nil)
        json["sessions"] = (json["sessions"] as? [[String: Any]])?.map { $0.filter { $0.key != "runStartedAt" } }
        let decoded = try JSONDecoder().decode(StatusReport.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(Self.line(decoded) == "stretch in 1 min · Claude working")
    }

    @Test func coloursAreTheAppsOwn() {
        let report = Self.report(next: .move, in: 0, sessions: [Self.session(.claudeCode, "s1", .waiting)])
        #expect(!StatusLine.render(report).contains("\u{1B}"))
        #expect(StatusLine.render(report, colour: .trueColour)
            == "\u{1B}[38;2;61;214;176mstretch due\u{1B}[0m\u{1B}[2m · \u{1B}[0m\u{1B}[38;2;255;180;84mClaude needs you\u{1B}[0m")
        let working = Self.report(sessions: [Self.session(.claudeCode, "s1", .working)])
        #expect(StatusLine.render(working, colour: .palette256)
            == "eye rest in 12 min\u{1B}[2m · \u{1B}[0m\u{1B}[38;5;69mClaude working\u{1B}[0m", "nothing due: the break part stays plain")
    }

    @Test func typicalLinesFitAStatusBar() {
        let lines = [
            Self.line(Self.report(sessions: [Self.session(.claudeCode, "s1", .working, ranFor: 190)])),
            Self.line(Self.report(next: .move, in: 0, sessions: [Self.session(.claudeCode, "s1", .working),
                                                                 Self.session(.codex, "c1", .working),
                                                                 Self.session(.cursor, "u1", .waiting)])),
            Self.line(Self.report(paused: .call([.microphone]), sessions: [Self.session(.claudeCode, "s1", .waiting)])),
        ]
        for line in lines { #expect(line.count <= 44, "\(line) is \(line.count) characters") }
    }

    // MARK: The command

    @Test func withoutTheAppItPrintsNothingAndSucceeds() throws {
        try CLI.requireFreshBinary()
        let dir = ShortTemporaryDirectory()
        defer { dir.cleanup() }
        CLI.expectSilentSuccess(try CLI.run(["status", "--line"], home: dir.url), "status --line")
        CLI.expectSilentSuccess(try CLI.run(["status", "--line", "--color"], home: dir.url), "status --line --color")
        let bad = try CLI.run(["status", "--json"], home: dir.url)
        #expect(bad.status == 2 && bad.stderr.contains("Unknown option \"--json\""))
    }

    @Test func againstAnApp() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        f.server.statusProvider = {
            let now = Date()
            return StatusReport(generatedAt: now,
                                sessions: [.init(source: .claudeCode, sessionID: "s1", state: .working, cwd: nil, lastEventAt: now,
                                                 runStartedAt: now.addingTimeInterval(-190))],
                                nextBreak: .init(kind: .move, seconds: 0))
        }
        let plain = try CLI.run(["status", "--line"], home: f.dir.url)
        #expect(plain.status == 0)
        #expect(plain.stdout == "stretch due · Claude working 3 min\n", "a pipe is not a terminal: no colour")
        let forced = try CLI.run(["status", "--line", "--color"], home: f.dir.url, extraEnvironment: ["NO_COLOR": "1"])
        #expect(forced.stdout.hasPrefix("\u{1B}[38;5;79mstretch due"), "--color wins over NO_COLOR: \(forced.stdout.debugDescription)")
        let truecolour = try CLI.run(["status", "--line", "--color"], home: f.dir.url, extraEnvironment: ["COLORTERM": "truecolor"])
        #expect(truecolour.stdout.hasPrefix("\u{1B}[38;2;61;214;176mstretch due"))
    }

    @Test func neverWaitsLongForAHungApp() throws {
        try CLI.requireFreshBinary()
        let f = try ServerFixture()
        defer { f.tearDown() }
        // The delivery queue is busy: the app accepts but does not answer.
        f.queue.async { usleep(3_000_000) }
        let result = try CLI.run(["status", "--line"], home: f.dir.url)
        CLI.expectSilentSuccess(result, "hung app")
        #expect(result.seconds < 1.5, "took \(result.seconds) s")
    }
}
