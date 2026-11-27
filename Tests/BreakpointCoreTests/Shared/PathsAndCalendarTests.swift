import Foundation
import Testing
@testable import BreakpointCore

@Suite("Paths (SPEC §8) and socket path (SPEC §5.1)")
struct PathsTests {
    let paths = BreakpointPaths(home: URL(fileURLWithPath: "/Users/tester", isDirectory: true))

    /// `/Users/tester` plus the platform's data folder (`Library/Application Support/Breakpoint`,
    /// or `AppData/Local/Breakpoint` on Windows).
    var data: String { "/Users/tester/" + BreakpointPaths.appSupportRelativePath }

    @Test func everyPathDerivesFromTheInjectedHome() {
        #expect(paths.appSupport.path == data)
        #expect(paths.settingsFile.path.hasSuffix("Breakpoint/settings.json"))
        #expect(paths.historyFile.lastPathComponent == "history.jsonl")
        #expect(paths.sessionsFile.lastPathComponent == "sessions.json")
        #expect(paths.watchdogLog.lastPathComponent == "watchdog.log")
        #expect(paths.backupsDirectory.path == data + "/backups")
        #expect(paths.cliCopy.path == "/Users/tester/.breakpoint/bin/" + BreakpointPaths.cliFileName)
        #expect(paths.shellPowerShellSnippet.path == "/Users/tester/.breakpoint/shell/breakpoint.ps1")
        #expect(paths.shellZshSnippet.path == "/Users/tester/.breakpoint/shell/breakpoint.zsh")
        #expect(paths.shellBashSnippet.path == "/Users/tester/.breakpoint/shell/breakpoint.bash")
        #expect(paths.fallbackSocketFile.path == "/Users/tester/.breakpoint/run/bp.sock")
    }

    @Test func backupNamesUseToolAndTimestamp() {
        let url = paths.backupFile(tool: "claude-code", fileExtension: "json", date: Fixture.date(14, 5), timeZone: Fixture.utc)
        #expect(url.lastPathComponent == "claude-code-20261122-140500.json")
    }

    @Test func homeOverrideVariable() {
        let live = BreakpointPaths.live(environment: ["BREAKPOINT_HOME": "/tmp/fake-home"])
        #expect(live.home.path == "/tmp/fake-home")
    }

    @Test func socketUsesPreferredPathWhenShort() {
        let socket = SocketPath(paths: paths)
        #expect(!socket.isFallback)
        #expect(socket.path == data + "/breakpoint.sock")
    }

    @Test func socketFallsBackWhenPathIsTooLong() {
        let longHome = "/Users/" + String(repeating: "x", count: 60)
        let socket = SocketPath(paths: BreakpointPaths(home: URL(fileURLWithPath: longHome)))
        #expect(socket.isFallback)
        #expect(socket.path == longHome + "/.breakpoint/run/bp.sock")
    }

    @Test func folderNames() {
        #expect(PathDisplay.folderName("/Users/x/breakpoint") == "breakpoint")
        #expect(PathDisplay.folderName("/Users/x/breakpoint/") == "breakpoint")
        #expect(PathDisplay.folderName("") == nil)
        #expect(PathDisplay.abbreviatingHome("/Users/x/code/app", home: "/Users/x") == "~/code/app")
        #expect(PathDisplay.abbreviatingHome("/Users/xy/app", home: "/Users/x") == "/Users/xy/app")
    }
}

@Suite("Day boundary, time of day, weekdays")
struct CalendarTests {
    let cal = Fixture.calendar

    @Test func dayRunsFromFiveToFive() {
        #expect(BreakpointDay.start(of: Fixture.date(14), calendar: cal) == Fixture.date(5))
        #expect(BreakpointDay.start(of: Fixture.date(5), calendar: cal) == Fixture.date(5))
        #expect(BreakpointDay.start(of: Fixture.date(3, day: 23), calendar: cal) == Fixture.date(5))
        #expect(BreakpointDay.nextBoundary(after: Fixture.date(23), calendar: cal) == Fixture.date(5, day: 23))
        #expect(BreakpointDay.nextBoundary(after: Fixture.date(4), calendar: cal) == Fixture.date(5))
        let interval = BreakpointDay.interval(containing: Fixture.date(1, day: 23), calendar: cal)
        #expect(interval.start == Fixture.date(5) && interval.end == Fixture.date(5, day: 23))
    }

    @Test func pauseDurations() {
        let now = Fixture.date(14)
        #expect(PauseDuration.thirtyMinutes.end(from: now, calendar: cal) == Fixture.date(14, 30))
        #expect(PauseDuration.oneHour.end(from: now, calendar: cal) == Fixture.date(15))
        #expect(PauseDuration.untilTomorrow.end(from: now, calendar: cal) == Fixture.date(5, day: 23))
    }

    @Test func timeOfDayParsesAndEncodes() throws {
        #expect(TimeOfDay(string: "23:00") == TimeOfDay(hour: 23, minute: 0))
        #expect(TimeOfDay(string: "7:05")?.description == "07:05")
        #expect(TimeOfDay(string: "24:00") == nil)
        #expect(TimeOfDay(string: "nope") == nil)
        let data = try JSONEncoder().encode(TimeOfDay(hour: 9, minute: 5))
        #expect(String(decoding: data, as: UTF8.self) == #""09:05""#)
        #expect(TimeOfDay(hour: 23, minute: 0).date(on: Fixture.date(10), calendar: cal) == Fixture.date(23))
    }

    @Test func weekdays() throws {
        // 2026-11-22 is a Sunday.
        #expect(Weekdays.all.contains(Fixture.date(12), calendar: cal))
        #expect(!Weekdays.weekdays.contains(Fixture.date(12), calendar: cal))
        #expect(Weekdays.weekdays.contains(Fixture.date(12, day: 23), calendar: cal))
        let data = try JSONEncoder().encode(Weekdays.weekdays)
        #expect(String(decoding: data, as: UTF8.self) == "[2,3,4,5,6]")
        #expect(try JSONDecoder().decode(Weekdays.self, from: data) == .weekdays)
    }
}
