import Foundation
import Testing
@testable import BreakpointCore

@Suite("Formatting helpers")
struct FormattingTests {
    @Test func clock() {
        #expect(DurationFormat.clock(19) == "0:19")
        #expect(DurationFormat.clock(18.2) == "0:19")
        #expect(DurationFormat.clock(0) == "0:00")
        #expect(DurationFormat.clock(-4) == "0:00")
        #expect(DurationFormat.clock(102, rounding: .down) == "1:42")
        #expect(DurationFormat.clock(102.9, rounding: .down) == "1:42")
        #expect(DurationFormat.clock(3725, rounding: .down) == "1:02:05")
    }

    @Test func minutes() {
        #expect(DurationFormat.minutes(6 * 60 + 40) == "6 min")
        #expect(DurationFormat.minutes(6 * 60 + 40, rounding: .up) == "7 min")
        #expect(DurationFormat.minutes(30) == "<1 min")
        #expect(DurationFormat.minutes(30, rounding: .up) == "1 min")
        #expect(DurationFormat.minutes(3600) == "1 h")
        #expect(DurationFormat.minutes(3900) == "1 h 5 min")
    }

    @Test func compact() {
        #expect(DurationFormat.compact(5 * 60 + 1) == "6m")
        #expect(DurationFormat.compact(20) == "1m")
        #expect(DurationFormat.compact(0) == "<1m")
        #expect(DurationFormat.compact(3 * 60 + 50, rounding: .down) == "3m")
        #expect(DurationFormat.compact(65 * 60) == "1h 5m")
    }

    @Test func lengthsAndPhrases() {
        #expect(DurationFormat.lengthAdjective(20) == "20-sec")
        #expect(DurationFormat.lengthAdjective(120) == "2-min")
        #expect(DurationFormat.lengthAdjective(360) == "6-min")
        #expect(DurationFormat.spokenLength(120) == "2 minutes")
        #expect(DurationFormat.spokenLength(60) == "1 minute")
        #expect(DurationFormat.sinceYouMoved(42 * 60 + 30) == "42 min since you moved")
        #expect(DurationFormat.atTheScreen(52 * 60) == "52 min at the screen")
        #expect(DurationFormat.approximately(4 * 60 + 10) == "about 4 min")
        #expect(DurationFormat.approximately(10) == "about 1 min")
    }

    @Test func timeOfDayUsesTheGivenLocale() {
        #expect(TimeFormat.timeOfDay(Fixture.date(14, 5), locale: Fixture.posix, timeZone: Fixture.utc) == "14:05")
        let us = TimeFormat.timeOfDay(Fixture.date(14, 5), locale: Locale(identifier: "en_US"), timeZone: Fixture.utc)
        #expect(us.hasPrefix("2:05"))
    }

    @Test func text() {
        #expect(TextFormat.truncated("  short  ", limit: 80) == "short")
        let long = String(repeating: "word ", count: 30)
        let cut = TextFormat.truncated(long, limit: 80)
        #expect(cut.hasSuffix("…") && cut.count <= 81)
        #expect(TextFormat.firstLine("\n\n  fix the bug  \nmore") == "fix the bug")
    }
}
