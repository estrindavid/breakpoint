import Foundation
import Testing
@testable import BreakpointCore

@Suite("PausePolicy: reasons and cool-downs (SPEC §2.4)")
struct PausePolicyTests {
    let now = Fixture.date(14)
    let settings = Settings.defaults
    let calendar = Fixture.calendar

    func update(_ state: PauseState, _ signals: CallSignals, at date: Date, settings: Settings = .defaults) -> PauseState {
        PausePolicy.update(state, callSignals: signals, settings: settings, now: date)
    }

    @Test func manualPauseLastsItsDurationThenCoolsDown() {
        let paused = PausePolicy.pause(.none, for: .thirtyMinutes, now: now, calendar: calendar)
        #expect(paused.reasons == [.manual(until: now.plus(minutes: 30))])
        #expect(Copy.pauseSentence(paused.primaryReason!, now: now, locale: Fixture.posix, timeZone: Fixture.utc) == "Paused until 14:30")
        let during = update(paused, [], at: now.plus(minutes: 29.9))
        #expect(during == paused)
        let after = update(paused, [], at: now.plus(minutes: 30))
        #expect(!after.isPaused)
        #expect(after.cooldownUntil == now.plus(minutes: 31))
        #expect(after.isCoolingDown(at: now.plus(minutes: 30.9)))
        #expect(!after.isCoolingDown(at: now.plus(minutes: 31)))
    }

    @Test func pauseDurations() {
        #expect(PausePolicy.pause(.none, for: .oneHour, now: now, calendar: calendar).reasons == [.manual(until: now.plus(minutes: 60))])
        let tomorrow = PausePolicy.pause(.none, for: .untilTomorrow, now: now, calendar: calendar)
        #expect(tomorrow.reasons == [.manual(until: Fixture.date(5, day: 23))])
        // After midnight but before 05:00, "tomorrow" is this morning at 05:00.
        let late = Fixture.date(1, day: 23)
        #expect(PausePolicy.pause(.none, for: .untilTomorrow, now: late, calendar: calendar).reasons
                == [.manual(until: Fixture.date(5, day: 23))])
    }

    @Test func aNewManualPauseReplacesTheOldOne() {
        let first = PausePolicy.pause(.none, for: .oneHour, now: now, calendar: calendar)
        let second = PausePolicy.pause(first, for: .thirtyMinutes, now: now.plus(minutes: 10), calendar: calendar)
        #expect(second.reasons == [.manual(until: now.plus(minutes: 40))])
    }

    @Test func callPauseFollowsTheSignalsAndSettings() {
        #expect(update(.none, .microphone, at: now).reasons == [.call(.microphone)])
        #expect(update(.none, [.microphone, .camera], at: now).reasons == [.call([.microphone, .camera])])
        #expect(update(.none, .camera, at: now).reasons == [.call(.camera)])

        var noCamera = Settings()
        noCamera.pauseForCamera = false
        #expect(update(.none, .camera, at: now, settings: noCamera) == .none)
        #expect(update(.none, [.microphone, .camera], at: now, settings: noCamera).reasons == [.call(.microphone)])

        var off = Settings()
        off.pauseForMicrophone = false
        #expect(update(.none, [.microphone, .camera], at: now, settings: off) == .none)
    }

    @Test func callSignalsChangeAndEnd() {
        var s = update(.none, .microphone, at: now)
        s = update(s, [.microphone, .camera], at: now.plus(minutes: 1))
        #expect(s.reasons == [.call([.microphone, .camera])])
        #expect(Copy.pauseSentence(s.primaryReason!, now: now) == "Paused: microphone and camera are on")
        #expect(s.cooldownUntil == nil)
        s = update(s, [], at: now.plus(minutes: 40))
        #expect(!s.isPaused)
        #expect(s.cooldownUntil == now.plus(minutes: 41))
    }

    @Test func coolDownStartsOnlyWhenTheLastReasonEnds() {
        var s = PausePolicy.pause(.none, for: .oneHour, now: now, calendar: calendar)
        s = update(s, .microphone, at: now.plus(minutes: 5))
        #expect(s.primaryReason == .call(.microphone))
        s = update(s, [], at: now.plus(minutes: 20))
        #expect(s.isPaused && s.cooldownUntil == nil)
        s = update(s, [], at: now.plus(minutes: 60))
        #expect(!s.isPaused && s.cooldownUntil == now.plus(minutes: 61))
    }

    @Test func resumeNowIgnoresTheCurrentCallUntilItEnds() {
        var s = update(.none, .microphone, at: now)
        s = PausePolicy.resumeNow(s, now: now.plus(minutes: 2))
        #expect(!s.isPaused && s.ignoringCurrentCall)
        #expect(s.cooldownUntil == now.plus(minutes: 3))
        // The same call goes on (and grows a camera): still ignored.
        s = update(s, [.microphone, .camera], at: now.plus(minutes: 10))
        #expect(!s.isPaused && s.ignoringCurrentCall)
        // All signals stop: the next call pauses again.
        s = update(s, [], at: now.plus(minutes: 30))
        #expect(!s.ignoringCurrentCall && !s.isPaused)
        s = update(s, .camera, at: now.plus(minutes: 45))
        #expect(s.reasons == [.call(.camera)])
    }

    @Test func resumeNowClearsManualAndWrapUp() {
        var s = PausePolicy.pause(.none, for: .untilTomorrow, now: now, calendar: calendar)
        s = PausePolicy.wrapUp(s, now: now, calendar: calendar)
        s = PausePolicy.resumeNow(s, now: now.plus(minutes: 1))
        #expect(s.reasons.isEmpty && !s.ignoringCurrentCall)
        #expect(s.cooldownUntil == now.plus(minutes: 2))
        // Nothing to resume: no cool-down.
        #expect(PausePolicy.resumeNow(.none, now: now) == .none)
    }

    @Test func wrapUpLastsUntilFiveInTheMorning() {
        let night = Fixture.date(23, 20)
        var s = PausePolicy.wrapUp(.none, now: night, calendar: calendar)
        #expect(s.reasons == [.windDownWrappedUp(until: Fixture.date(5, day: 23))])
        #expect(Copy.pauseSentence(s.primaryReason!, now: night) == "Paused: wrapped up for tonight")
        s = update(s, [], at: Fixture.date(4, 59, day: 23))
        #expect(s.isPaused)
        s = update(s, [], at: Fixture.date(5, day: 23))
        #expect(!s.isPaused && s.cooldownUntil == Fixture.date(5, 1, day: 23))
    }

    @Test func primaryReasonIsCallThenWrapUpThenManual() {
        var s = PausePolicy.pause(.none, for: .oneHour, now: now, calendar: calendar)
        s = PausePolicy.wrapUp(s, now: now, calendar: calendar)
        #expect(s.primaryReason == .windDownWrappedUp(until: Fixture.date(5, day: 23)))
        s = update(s, .microphone, at: now)
        #expect(s.primaryReason == .call(.microphone))
        #expect(s.reasons.count == 3)
    }

    @Test func startCooldownNeverShortensALaterOne() {
        let s = PausePolicy.startCooldown(.none, now: now)
        #expect(s.cooldownUntil == now.plus(seconds: 60))
        let later = PausePolicy.startCooldown(PauseState(cooldownUntil: now.plus(minutes: 5)), now: now)
        #expect(later.cooldownUntil == now.plus(minutes: 5))
        let extended = PausePolicy.startCooldown(s, now: now.plus(seconds: 30))
        #expect(extended.cooldownUntil == now.plus(seconds: 90))
    }

    @Test func updateIsStableWhenNothingChanges() {
        var s = PausePolicy.pause(.none, for: .oneHour, now: now, calendar: calendar)
        s = update(s, .microphone, at: now)
        #expect(update(s, .microphone, at: now.plus(seconds: 1)) == s)
    }
}

@Suite("WindDownPolicy (SPEC §2.8)")
struct WindDownPolicyTests {
    let calendar = Fixture.calendar
    // 2026-11-22 is a Sunday.
    let sundayStart = Fixture.date(5)

    var enabled: Settings {
        var s = Settings()
        s.windDownEnabled = true
        return s
    }

    func offers(_ state: WindDownState? = nil, settings: Settings? = nil, at date: Date) -> Bool {
        WindDownPolicy.shouldOfferCard(state ?? WindDownState(dayStart: sundayStart), settings: settings ?? enabled,
                                       now: date, calendar: calendar)
    }

    @Test func offStaysQuiet() {
        #expect(!offers(settings: .defaults, at: Fixture.date(23, 30)))
    }

    @Test func fromTheStopTimeUntilFiveInTheMorning() {
        #expect(!offers(at: Fixture.date(22, 59)))
        #expect(offers(at: Fixture.date(23)))
        #expect(offers(at: Fixture.date(23, 20)))
        #expect(offers(at: Fixture.date(2, day: 23)))
        // 05:00 starts a new day, before its stop time.
        #expect(!offers(at: Fixture.date(5, day: 23)))
        // 04:59 on Sunday morning is still Saturday night, after Saturday's stop time.
        #expect(offers(at: Fixture.date(4, 59)))
        #expect(!offers(at: Fixture.date(22, 59, day: 21)))
    }

    @Test func onlyOnChosenDays() {
        var s = enabled
        s.stopDays = .weekdays
        // Sunday night: no; 01:00 Monday still belongs to Sunday night: no.
        #expect(!offers(settings: s, at: Fixture.date(23, 30)))
        #expect(!offers(settings: s, at: Fixture.date(1, day: 23)))
        // Monday night: yes.
        #expect(offers(settings: s, at: Fixture.date(23, 30, day: 23)))
    }

    @Test func aStopTimeAfterMidnightBelongsToTheNightBefore() {
        var s = enabled
        s.stopTime = TimeOfDay(hour: 0, minute: 30)
        s.stopDays = [.sunday]
        #expect(!offers(settings: s, at: Fixture.date(23, 50)))
        #expect(!offers(settings: s, at: Fixture.date(0, 29, day: 23)))
        #expect(offers(settings: s, at: Fixture.date(0, 30, day: 23)))
        #expect(offers(settings: s, at: Fixture.date(3, day: 23)))
        #expect(WindDownPolicy.stopMoment(s.stopTime, dayStart: sundayStart, calendar: calendar) == Fixture.date(0, 30, day: 23))
    }

    @Test func wrappedUpVisibleOrSnoozedStaysQuiet() {
        let night = Fixture.date(23, 10)
        #expect(!offers(WindDownState(dayStart: sundayStart, wrappedUp: true), at: night))
        #expect(!offers(WindDownState(dayStart: sundayStart, cardVisible: true), at: night))
        let snoozed = WindDownPolicy.extend(WindDownState(dayStart: sundayStart, cardVisible: true), now: night)
        #expect(snoozed.snoozedUntil == night.plus(minutes: 15) && !snoozed.cardVisible && snoozed.extensionsTonight == 1)
        #expect(!offers(snoozed, at: night.plus(minutes: 14.9)))
        #expect(offers(snoozed, at: night.plus(minutes: 15)))
    }

    @Test func aStateFromAnEarlierNightCountsAsFresh() {
        let lastNight = WindDownState(dayStart: Fixture.date(5, day: 21), wrappedUp: true)
        #expect(offers(lastNight, at: Fixture.date(23, 10)))
    }

    @Test func holdsEscalateThreeSixTen() {
        var state = WindDownState(dayStart: sundayStart)
        var holds: [TimeInterval] = []
        for minute in [0.0, 15, 30, 45, 60] {
            holds.append(WindDownPolicy.holdDuration(state, settings: enabled))
            state = WindDownPolicy.extend(state, now: Fixture.date(23).plus(minutes: minute))
        }
        #expect(holds == [3, 6, 10, 10, 10])
        var flat = enabled
        flat.escalatingHold = false
        #expect(WindDownPolicy.holdDuration(state, settings: flat) == 3)
        #expect(Copy.windDownHold(holds[1]) == "Hold 6 s")
    }

    @Test func wrapUpAndRollover() {
        let state = WindDownPolicy.wrapUp(WindDownState(dayStart: sundayStart, extensionsTonight: 2,
                                                        snoozedUntil: Fixture.date(23, 30), cardVisible: true),
                                          now: Fixture.date(23, 40))
        #expect(state.wrappedUp && !state.cardVisible)
        #expect(WindDownPolicy.rolledOver(state, now: Fixture.date(4, 59, day: 23), calendar: calendar) == state)
        let fresh = WindDownPolicy.rolledOver(state, now: Fixture.date(5, day: 23), calendar: calendar)
        #expect(fresh == WindDownState(dayStart: Fixture.date(5, day: 23)))
        #expect(WindDownPolicy.holdDuration(fresh, settings: enabled) == 3)
    }

    @Test func wrapUpNoteListsOpenSessionsMostRecentFirst() {
        let t = Fixture.date(23)
        func session(_ id: String, cwd: String?, title: String?, last: Double, state: AgentState = .idle) -> AgentSession {
            AgentSession(key: SessionKey(source: .claudeCode, sessionID: id), state: state, cwd: cwd, title: title,
                         createdAt: t, lastEventAt: t.plus(minutes: last))
        }
        let lines = WindDownPolicy.wrapUpNote(sessions: [
            session("a", cwd: "/Users/dev/api", title: "add rate limits", last: 1),
            session("b", cwd: "/Users/dev/breakpoint", title: "fix the login redirect", last: 9, state: .working),
            session("c", cwd: nil, title: nil, last: 12),
            session("d", cwd: "/Users/dev/notes", title: nil, last: 5),
            session("e", cwd: "/Users/dev/api", title: "add rate limits", last: 0),
        ])
        #expect(lines == ["breakpoint — fix the login redirect", "notes", "api — add rate limits"])
        #expect(WindDownPolicy.wrapUpNote(sessions: []).isEmpty)
    }
}
