#if canImport(CoreText)
import CoreText
#endif
import Foundation
import Testing
@testable import BreakpointCore

@Suite("All-time totals in the popover (SPEC §2.7, §3.8)")
struct TotalsTests {
    let calendar = Fixture.calendar
    let us = Locale(identifier: "en_US")

    func entry(_ kind: BreakKind, _ outcome: BreakOutcome, at date: Date = Fixture.date(10),
               duration: TimeInterval = 0) -> HistoryEntry {
        HistoryEntry(kind: kind, outcome: outcome, opportunityKind: .agentStarted, source: .claudeCode, start: date,
                     duration: duration)
    }

    // MARK: What counts

    @Test func countsEveryStartedStretchWalkAndEyeRest() {
        let totals = HistoryTotals.counting([
            entry(.move, .completed, duration: 120),
            entry(.walk, .completed, duration: 6 * 60),
            entry(.eyes, .completed, duration: 20),
            entry(.move, .declined),
            entry(.walk, .ignored),
            entry(.eyes, .endedEarly, duration: 12),
            entry(.eyes, .endedEarly, duration: 3),             // Skip right after the guard: it counts
            entry(.breathe, .completed, duration: 60),
            entry(.move, .credited, duration: 20 * 60),
            entry(.eyes, .credited, duration: 6 * 60),
            // Older versions recorded a short break ended with Skip as skipped: read, not counted.
            entry(.move, .skipped, duration: 40),
            entry(.eyes, .skipped, duration: 5),
        ])
        #expect(totals.movingSeconds == 120 + 360)
        #expect(totals.stretches == 1)
        #expect(totals.walks == 1)
        #expect(totals.eyeRests == 3)
    }

    /// The stats stay honest: a short break counts once, with only the seconds it ran.
    @Test func aShortBreakAddsOnlyTheSecondsItRan() {
        let totals = HistoryTotals.counting([
            entry(.move, .endedEarly, duration: 5),
            entry(.walk, .endedEarly, duration: 0),          // I'm back at once
            entry(.move, .endedEarly, duration: 30),
            entry(.walk, .endedEarly, duration: 150),
            entry(.eyes, .endedEarly, duration: 4),
        ])
        #expect(totals.movingSeconds == 5 + 0 + 30 + 150)
        #expect(totals.stretches == 2)
        #expect(totals.walks == 2)
        #expect(totals.eyeRests == 1)
        // The popover rounds moving down, so seconds never read as minutes.
        let one = HistoryTotals.counting([entry(.move, .endedEarly, duration: 5)])
        #expect(TotalsCopy.moving(one.movingSeconds) == "0 min")
        #expect(TotalsCopy.accessibility(one, now: Fixture.date(12), calendar: calendar, locale: us)
                == "Today: 0 min moving, 1 stretch, 0 eye rests.")
        #expect(TotalsCopy.exampleLine(one) == nil)
    }

    @Test func realElapsedTimeCountsAndADamagedDurationIsCapped() {
        let totals = HistoryTotals.counting([
            entry(.move, .completed, duration: 4 * 60),   // with two "1 more minute"
            entry(.walk, .completed, duration: 50 * 60),  // longer than the walk ceiling: damaged
            entry(.move, .completed, duration: -30),
        ])
        #expect(totals.movingSeconds == 4 * 60 + Timing.walkCeiling)
        #expect(totals.stretches == 2 && totals.walks == 1)
    }

    @Test func firstEntryIsTheEarliestOfAnyOutcome() {
        var totals = HistoryTotals()
        #expect(!totals.hasHistory)
        totals.add(entry(.move, .declined, at: Fixture.date(10)))
        #expect(totals.firstEntry == Fixture.date(10))
        // A credited away period is recorded after the fact, with its earlier start.
        totals.add(entry(.move, .credited, at: Fixture.date(9), duration: 600))
        totals.add(entry(.eyes, .completed, at: Fixture.date(11), duration: 20))
        #expect(totals.firstEntry == Fixture.date(9))
        #expect(totals.movingSeconds == 0)
    }

    @Test func remembersTheMovingTimeBeforeTheLatestStretchOrWalk() {
        var totals = HistoryTotals()
        totals.add(entry(.move, .completed, duration: 120))
        #expect(totals.movingBeforeLatest == 0)
        totals.add(entry(.move, .completed, duration: 120))
        #expect(totals.movingBeforeLatest == 120)
        totals.add(entry(.eyes, .completed, duration: 20))
        totals.add(entry(.breathe, .completed, duration: 60))
        #expect(totals.movingBeforeLatest == 120, "only a stretch or walk moves it")
        #expect(totals.movingSeconds == 240)
    }

    // MARK: The store

    @Test func storeScanMatchesCountingEveryEntryInFileOrder() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let store = HistoryStore(paths: dir.paths, calendar: calendar)
        #expect(try store.totals() == .empty)
        let entries = [
            entry(.move, .declined, at: Fixture.date(8)),
            entry(.move, .completed, at: Fixture.date(9), duration: 118),
            entry(.eyes, .completed, at: Fixture.date(9, 30), duration: 20),
            entry(.breathe, .completed, at: Fixture.date(10), duration: 60),
            entry(.walk, .endedEarly, at: Fixture.date(11), duration: 200),
            entry(.move, .credited, at: Fixture.date(7), duration: 900),
            entry(.move, .completed, at: Fixture.date(12), duration: 121),
        ]
        for e in entries { try store.append(e) }
        let scanned = try store.totals()
        #expect(scanned == HistoryTotals.counting(entries))
        #expect(scanned.firstEntry == Fixture.date(7))
        #expect(scanned.movingBeforeLatest == 118 + 200)
        try store.deleteAll()
        #expect(try store.totals() == .empty)
    }

    /// Lines in another spelling (an older version, a hand edit) are decoded, never dropped.
    @Test func storeScanReadsOtherSpellings() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        try dir.paths.ensureAppSupportDirectory()
        let lines = [
            #"{"duration":120,"id":"\#(UUID())","kind":"move","outcome":"completed","start":"2026-11-21T10:00:00Z"}"#,
            #"{ "duration": 20, "id": "\#(UUID())", "kind": "eyes", "outcome": "completed", "start": "2026-11-22T10:00:00.000Z" }"#,
            #"{"duration":120,"id":"\#(UUID())","kind":"move","movementDetected":false,"outcome":"completed","start":"2026-11-22T11:00:00.000Z"}"#,
            "not json",
            "",
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: dir.paths.historyFile)
        let totals = try HistoryStore(paths: dir.paths, calendar: calendar).totals()
        #expect(totals.stretches == 2)
        #expect(totals.eyeRests == 1)
        #expect(totals.movingSeconds == 240)
        #expect(totals.firstEntry == Fixture.date(10, day: 21))
    }

    /// The popover opens often and history grows by every offer forever: a year of it (60 lines a
    /// day) is scanned once at launch, then each new entry is added in constant time.
    @Test func aYearOfHistoryIsCheap() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let store = HistoryStore(paths: dir.paths, calendar: calendar)
        var data = Data()
        let encoder = HistoryStore.lineEncoder
        let start = Fixture.date(9).addingTimeInterval(-365 * 86_400)
        var expected = HistoryTotals()
        let kinds: [BreakKind] = [.move, .eyes, .eyes, .walk, .breathe]
        let outcomes: [BreakOutcome] = [.completed, .ignored, .declined, .completed, .endedEarly, .skipped, .credited]
        for i in 0..<(365 * 60) {
            let e = HistoryEntry(kind: kinds[i % kinds.count], outcome: outcomes[i % outcomes.count],
                                 opportunityKind: .agentStarted, source: .claudeCode,
                                 start: start.addingTimeInterval(TimeInterval(i) * 86_400 / 60), duration: 90)
            expected.add(e)
            data.append(try encoder.encode(e))
            data.append(0x0A)
        }
        try dir.paths.ensureAppSupportDirectory()
        try data.write(to: dir.paths.historyFile)
        let clock = ContinuousClock()
        var scanned = HistoryTotals()
        let scan = try clock.measure { scanned = try store.totals() }
        #expect(scanned == expected)
        #expect(scan < .milliseconds(150), "a year of history took \(scan) to scan")

        let next = entry(.move, .completed, at: Fixture.date(13), duration: 120)
        let add = clock.measure { for _ in 0..<1000 { scanned.add(next) } }
        #expect(add < .milliseconds(5), "1000 adds took \(add)")
    }

    // MARK: Wording

    @Test func movingFigureGoesFromMinutesToHours() {
        func text(_ minutes: Double) -> String { TotalsCopy.moving(minutes * 60, locale: us) }
        #expect(text(0) == "0 min")
        #expect(text(0.9) == "0 min")
        #expect(text(1) == "1 min")
        #expect(text(74.9) == "74 min", "rounds down")
        #expect(text(99) == "99 min")
        #expect(text(100) == "1 h 40 min")
        #expect(text(120) == "2 h")
        #expect(text(320) == "5 h 20 min")
        #expect(text(599) == "9 h 59 min")
        #expect(text(600) == "10 h")
        #expect(text(719) == "11 h", "whole hours from 10 h, rounded down")
        #expect(text(62_400) == "1,040 h")
        #expect(TotalsCopy.movingParts(320 * 60, locale: us) == [.init("5", "h"), .init("20", "min")])
    }

    @Test func countsAndTheirLabels() {
        #expect(TotalsCopy.count(0, locale: us) == "0")
        #expect(TotalsCopy.count(26, locale: us) == "26")
        #expect(TotalsCopy.count(2915, locale: us) == "2,915")
        #expect(TotalsCopy.stretchesLabel(0) == "stretches")
        #expect(TotalsCopy.stretchesLabel(1) == "stretch")
        #expect(TotalsCopy.stretchesLabel(2) == "stretches")
        #expect(TotalsCopy.eyeRestsLabel(1) == "eye rest")
        #expect(TotalsCopy.eyeRestsLabel(61) == "eye rests")
        #expect(TotalsCopy.movingLabel == "moving")
    }

    @Test func periodIsTodayOnTheFirstDayThenSinceItsDate() {
        func period(_ first: Date?, now: Date = Fixture.date(14)) -> String {
            TotalsCopy.period(firstEntry: first, now: now, calendar: calendar, locale: us)
        }
        #expect(period(nil) == "Today")
        #expect(period(Fixture.date(5)) == "Today")
        // The day runs 05:00 to 05:00: 01:00 on the 23rd is still the 22nd's day.
        #expect(period(Fixture.date(9), now: Fixture.date(1, day: 23)) == "Today")
        #expect(period(Fixture.date(4, 59)) == "Since Nov 21", "04:59 belongs to the day before")
        #expect(period(Fixture.date(10, day: 16)) == "Since Nov 16")
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 9, day: 14, hour: 10))!
        #expect(period(lastYear) == "Since Sep 14, 2025")
    }

    @Test func accessibilityReadsAsOneSentence() {
        let totals = HistoryTotals(movingSeconds: 74 * 60, stretches: 26, eyeRests: 61, firstEntry: Fixture.date(10, day: 16))
        #expect(TotalsCopy.accessibility(totals, now: Fixture.date(14), calendar: calendar, locale: us)
                == "Since Nov 16: 74 min moving, 26 stretches, 61 eye rests. That's like a full yoga class.")
        let one = HistoryTotals(movingSeconds: 120, stretches: 1, eyeRests: 1, firstEntry: Fixture.date(10))
        #expect(TotalsCopy.accessibility(one, now: Fixture.date(14), calendar: calendar, locale: us)
                == "Today: 2 min moving, 1 stretch, 1 eye rest.")
    }

    // MARK: The examples

    @Test func examplesAreStrictlyIncreasingAndKeepComing() {
        let all = MovingExamples.all
        #expect(all.count >= 30)
        for (a, b) in zip(all, all.dropFirst()) { #expect(a.minutes < b.minutes, "\(a.activity) → \(b.activity)") }
        #expect(Set(all.map(\.activity)).count == all.count, "no example twice")
        // The first after a stretch or two (a stretch is 2 min; Done comes at 80%, 96 s).
        #expect(all[0].minutes <= 3)
        // A new one every day or two in the first two weeks (about 11 min of moving a day)…
        #expect(all.filter { $0.minutes <= 150 }.count >= 14)
        // …and still arriving after several months (about 75 min a week).
        #expect(all.filter { $0.minutes > 26 * 75 }.count >= 4)
        #expect(all.last!.minutes >= 52 * 75)
    }

    @Test func examplesFollowTheCopyRules() {
        let banned = ["should", "health", "healthy", "fitness", "fit", "calorie", "calories", "burn", "burned", "burnt",
                      "workout", "exercise", "cure", "heal", "treat", "prevent", "posture", "pain", "stress", "benefit",
                      "better", "improve", "km", "kilometres", "kilometers", "miles", "metres", "meters", "steps",
                      "colour", "favourite", "neighbourhood", "color", "favorite", "neighborhood", "look", "away"]
        for example in MovingExamples.all {
            let line = TotalsCopy.line(for: example)
            #expect(!line.contains("!"), "\(line)")
            let words = line.lowercased().split { !$0.isLetter }.map(String.init)
            for word in banned { #expect(!words.contains(word), "\(line) uses \(word)") }
            #expect(example.activity == example.activity.trimmingCharacters(in: .whitespaces))
            #expect(!example.activity.hasSuffix("."))
            #expect(example.activity.first?.isLowercase == true || example.activity.hasPrefix("Sunday"))
            #expect(line.split(separator: " ").count <= 10, "\(line)")
        }
    }

    #if canImport(CoreText)
    /// Each line fits the popover's text column (320 pt wide, 16 pt margins, 4 pt inset) at its
    /// 12 pt size without shrinking.
    @Test func everyLineFitsThePopover() {
        let font = CTFontCreateUIFontForLanguage(.system, 12, nil)!
        for example in MovingExamples.all {
            let line = TotalsCopy.line(for: example)
            let text = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)
            #expect(width <= 320 - 2 * 16 - 2 * 4, "\(line) is \(width) pt")
        }
    }
    #endif

    @Test func theLineShowsTheHighestExampleReached() {
        let first = MovingExamples.all[0], second = MovingExamples.all[1], last = MovingExamples.all.last!
        func line(_ seconds: TimeInterval) -> TotalsCopy.ExampleLine? {
            TotalsCopy.exampleLine(HistoryTotals(movingSeconds: seconds))
        }
        #expect(line(0) == nil)
        #expect(line(TimeInterval(first.minutes * 60) - 1) == nil, "nothing before the first example")
        #expect(line(TimeInterval(first.minutes * 60))?.activity == first.activity)
        #expect(line(TimeInterval(second.minutes * 60) - 1)?.activity == first.activity)
        #expect(line(TimeInterval(second.minutes * 60))?.activity == second.activity)
        #expect(line(TimeInterval(last.minutes * 60) * 10)?.activity == last.activity, "the last one stays")
        #expect(line(74 * 60)?.text == "That's like a full yoga class.")
    }

    @Test func anExampleIsNewWhileTheLatestStretchOrWalkReachedIt() {
        var totals = HistoryTotals()
        totals.add(entry(.move, .completed, duration: 120))
        #expect(TotalsCopy.exampleLine(totals) == nil)
        totals.add(entry(.move, .completed, duration: 120))
        #expect(TotalsCopy.exampleLine(totals)?.activity == "dancing to a whole song")
        #expect(TotalsCopy.exampleLine(totals)?.isNew == true)
        totals.add(entry(.eyes, .completed, duration: 20))
        #expect(TotalsCopy.exampleLine(totals)?.isNew == true, "an eye rest does not change it")
        totals.add(entry(.move, .completed, duration: 60))
        #expect(TotalsCopy.exampleLine(totals)?.activity == "dancing to a whole song")
        #expect(TotalsCopy.exampleLine(totals)?.isNew == false, "the next stretch reached nothing new")
        totals.add(entry(.walk, .completed, duration: 6 * 60))
        #expect(TotalsCopy.exampleLine(totals)?.activity == "the warm-up before a run")
        #expect(TotalsCopy.exampleLine(totals)?.isNew == true)
    }
}
