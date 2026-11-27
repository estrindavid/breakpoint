import Foundation
import Testing
@testable import BreakpointCore

@Suite("Model values and Codable round trips")
struct ModelTests {
    let now = Fixture.date(14)

    @Test func breakKinds() {
        #expect(BreakKind.eyes.defaultLength == 20)
        #expect(BreakKind.move.defaultLength == 120)
        #expect(BreakKind.breathe.defaultLength == 60)
        #expect(BreakKind.walkTarget(expectedRun: 90) == 300)
        #expect(BreakKind.walkTarget(expectedRun: 6 * 60 + 20) == 360)
        #expect(BreakKind.walkTarget(expectedRun: 6 * 60 + 40) == 420)
        #expect(BreakKind.walkTarget(expectedRun: 3600) == 600)
        #expect(BreakKind.move.allowsExtension && BreakKind.breathe.allowsExtension)
        #expect(!BreakKind.eyes.allowsExtension && !BreakKind.walk.allowsExtension)
        #expect(BreakOutcome.allCases.filter(\.countsAsTaken) == [.completed, .endedEarly, .credited])
    }

    @Test func agentSourceDisplayNames() throws {
        #expect(AgentSource.claudeCode.displayName == "Claude")
        #expect(AgentSource.copilot.displayName == "Copilot")
        #expect(AgentSource("my-tool").displayName == "my-tool")
        #expect(String(decoding: try JSONEncoder().encode(AgentSource.cursor), as: UTF8.self) == #""cursor""#)
        let dict: [AgentSource: Double] = [.codex: 1]
        #expect(String(decoding: try JSONEncoder().encode(dict), as: UTF8.self) == #"{"codex":1}"#)
    }

    @Test func callSignalsRespectSettings() {
        var s = Settings()
        let both: CallSignals = [.microphone, .camera]
        #expect(both.filtered(by: s) == both)
        s.pauseForCamera = false
        #expect(both.filtered(by: s) == .microphone)
        s.pauseForMicrophone = false
        s.pauseForCamera = true
        #expect(both.filtered(by: s) == [])
    }

    @Test func pauseStatePrimaryReason() {
        let state = PauseState(reasons: [.manual(until: now), .call(.microphone)])
        #expect(state.isPaused)
        #expect(state.primaryReason == .call(.microphone))
        #expect(state.callSignals == .microphone)
        #expect(PauseState(cooldownUntil: now.addingTimeInterval(10)).isCoolingDown(at: now))
    }

    @Test func inputGuard() {
        #expect(InputSample(takenAt: now, secondsSinceKey: 1.5).isTyping)
        #expect(!InputSample(takenAt: now, secondsSinceKey: 2).isTyping)
        #expect(InputSample(takenAt: now, secondsSinceDrag: 0.5).isPointerBusy)
        #expect(InputSample(takenAt: now, mouseButtonDown: true).isBusy)
        #expect(!InputSample.quiet(at: now).isBusy)
    }

    @Test func opportunitiesExpireAfterThirtySeconds() {
        let o = Opportunity(kind: .agentStarted, source: .claudeCode, sessionID: "s", createdAt: now)
        #expect(o.expiresAt == now.addingTimeInterval(30))
        #expect(!o.isExpired(at: now.addingTimeInterval(29)))
        #expect(o.isExpired(at: now.addingTimeInterval(30)))
        #expect(o.sessionKey == SessionKey(source: .claudeCode, sessionID: "s"))
        #expect(Opportunity(kind: .longCommand, source: .shell, sessionID: "1", createdAt: now).sessionKey == nil)
    }

    @Test func autoDecisionUndoWindow() {
        let d = AutoDecision(kind: .timersReset(duration: 240), madeAt: now, sentence: "x", previous: .zero)
        #expect(d.undoExpiresAt == now.addingTimeInterval(600))
        #expect(d.isUndoable(at: now.addingTimeInterval(599)))
        #expect(!d.isUndoable(at: now.addingTimeInterval(600)))
        #expect(TimerState(screenTime: 1, stillTime: 2).adding(10) == TimerState(screenTime: 11, stillTime: 12))
    }

    @Test func codableRoundTrips() throws {
        let opportunity = Opportunity(kind: .longCommand, source: .shell, sessionID: "9", commandName: "swift", createdAt: now)
        let offer = BreakOffer(kind: .walk, length: 360, opportunity: opportunity, overdueBy: 60, timerValue: 3060,
                               expectedRunLength: 400)
        #expect(try Fixture.jsonRoundTrip(offer) == offer)
        for decision in [EngineDecision.offer(offer), .hold(.typing), .suppress(.paused(.call(.camera))),
                         .suppress(.cooldown(until: now)), .suppress(.strictMode), .nothing] {
            #expect(try Fixture.jsonRoundTrip(decision) == decision)
        }
        let session = AgentSession(key: SessionKey(source: .claudeCode, sessionID: "a"), state: .working, cwd: "/p",
                                   title: "t", createdAt: now, runStartedAt: now, lastRunEnding: .finished(duration: 90))
        #expect(try Fixture.jsonRoundTrip(session) == session)
        let decision = AutoDecision(kind: .creditedAway([.eyes, .move], duration: 400), madeAt: now, sentence: "s",
                                    previous: TimerState(screenTime: 1300, stillTime: 3100), historyEntryIDs: [UUID()])
        #expect(try Fixture.jsonRoundTrip(decision) == decision)
        let entry = HistoryEntry(kind: .move, outcome: .completed, opportunityKind: .agentStarted, source: .codex,
                                 start: now, duration: 120, movementDetected: true)
        #expect(try Fixture.jsonRoundTrip(entry) == entry)
        let pause = PauseState(reasons: [.manual(until: now), .windDownWrappedUp(until: now), .call([.microphone, .camera])],
                               cooldownUntil: now, ignoringCurrentCall: true)
        #expect(try Fixture.jsonRoundTrip(pause) == pause)
        let summary = DaySummary(dayStart: now, breaksTaken: 3, takenByKind: [.eyes: 2, .move: 1])
        #expect(try Fixture.jsonRoundTrip(summary) == summary)
        let totals = HistoryTotals(movingSeconds: 4440, stretches: 26, walks: 3, eyeRests: 61, firstEntry: now,
                                   movingBeforeLatest: 4320)
        #expect(try Fixture.jsonRoundTrip(totals) == totals)
        #expect(try Fixture.jsonRoundTrip(summary) == summary)
        let breakSession = BreakSessionRules.makeSession(kind: .move, opportunity: opportunity, settings: .defaults,
                                                         expectedRun: nil, agentName: nil, copyRotation: 1, now: now)
        #expect(try Fixture.jsonRoundTrip(breakSession) == breakSession)
        #expect(try Fixture.jsonRoundTrip(IntegrationStatus.connected(lastEvent: now)) == .connected(lastEvent: now))
        #expect(try Fixture.jsonRoundTrip(IntegrationStatus.connected(lastEvent: nil)) == .connected(lastEvent: nil))
        #expect(try Fixture.jsonRoundTrip(PresenceStatus.away(since: now, cause: .locked)) == .away(since: now, cause: .locked))
    }

    @Test func historyEntryToleratesMissingOptionalFields() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"eyes","outcome":"credited","start":"2026-11-22T14:00:00Z"}"#
        let entry = try JSONFile<HistoryEntry>.decoder.decode(HistoryEntry.self, from: Data(json.utf8))
        #expect(entry.duration == 0 && !entry.movementDetected && entry.opportunityKind == nil)
    }

    @Test func daySummaryCountsOnlyBreaksTakenInTheDay() {
        let cal = Fixture.calendar
        let entries = [
            HistoryEntry(kind: .eyes, outcome: .completed, start: Fixture.date(9)),
            HistoryEntry(kind: .move, outcome: .credited, start: Fixture.date(11)),
            HistoryEntry(kind: .move, outcome: .skipped, start: Fixture.date(12)),
            HistoryEntry(kind: .eyes, outcome: .declined, start: Fixture.date(13)),
            HistoryEntry(kind: .eyes, outcome: .completed, start: Fixture.date(4)),        // previous day
            HistoryEntry(kind: .eyes, outcome: .completed, start: Fixture.date(4, day: 23)), // still today (before 05:00)
            HistoryEntry(kind: .eyes, outcome: .completed, start: Fixture.date(5, day: 23)), // next day
        ]
        let summary = DaySummary.summarize(entries, dayStart: Fixture.date(14), calendar: cal)
        #expect(summary.dayStart == Fixture.date(5))
        #expect(summary.breaksTaken == 3)
        #expect(summary.takenByKind == [.eyes: 2, .move: 1])
    }

    @Test func integrationStatusMerging() {
        // Installed is connected at once; the last event is information, not a condition.
        #expect(IntegrationStatus(installState: .installed, lastEvent: nil) == .connected(lastEvent: nil))
        #expect(IntegrationStatus(installState: .installed, lastEvent: now) == .connected(lastEvent: now))
        #expect(IntegrationStatus(installState: .installed, lastEvent: nil).isInstalled)
        // A failed install check replaces the ✓ with what to do.
        #expect(IntegrationStatus(installState: .installed, lastEvent: now, checkProblem: "Fix it.") == .problem("Fix it."))
        #expect(!IntegrationStatus(installState: .installed, lastEvent: nil, checkProblem: "Fix it.").isInstalled)
        #expect(IntegrationStatus(installState: .notInstalled, lastEvent: nil, checkProblem: "Fix it.") == .notInstalled)
        #expect(IntegrationStatus(installState: .notFound, lastEvent: now) == .notFound)
        #expect(IntegrationID(rawValue: "codex-notify") == .codexNotify)
        #expect(IntegrationID.claudeCode.source == .claudeCode)
    }

    @Test func commandDenylist() {
        #expect(CommandDenylist.contains("vim"))
        #expect(CommandDenylist.contains("/usr/bin/python3"))
        #expect(!CommandDenylist.contains("swift"))
        #expect(CommandDenylist.names.count == 32)
    }
}
