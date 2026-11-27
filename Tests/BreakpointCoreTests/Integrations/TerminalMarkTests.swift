import Foundation
import Testing
@testable import BreakpointCore

/// `breakpoint --version` (SPEC §5.8): the mark in a terminal, one plain line in a pipe.
@Suite("Terminal mark")
struct TerminalMarkTests {
    let term = ["TERM": "xterm-256color"]

    @Test func pipedOutputIsTheOneParseableLine() {
        let output = TerminalMark.versionOutput(version: "1.2.3", isTerminal: false, environment: term)
        #expect(output == "breakpoint 1.2.3\n")
    }

    @Test func aTerminalGetsTheMarkInMint() {
        let output = TerminalMark.versionOutput(version: "1.2.3", isTerminal: true, environment: term)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 5 && lines.last == "")
        #expect(output.contains("\u{1B}[38;5;79m▄███████████▄"))
        // The version is still one plain "breakpoint 1.2.3" on its own line, after the mark.
        #expect(lines[1].hasSuffix("  breakpoint 1.2.3"))
        #expect(output.contains("Break reminders that wait for your agent."))
        let truecolour = TerminalMark.versionOutput(version: "1.2.3", isTerminal: true,
                                                    environment: ["TERM": "xterm-256color", "COLORTERM": "truecolor"])
        #expect(truecolour.contains("\u{1B}[38;2;61;214;176m"))
    }

    @Test func noColorAndDumbTerminalsArePlain() {
        for environment in [["TERM": "xterm-256color", "NO_COLOR": "1"], ["TERM": "dumb"], [:]] {
            let output = TerminalMark.versionOutput(version: "1.2.3", isTerminal: true, environment: environment)
            #expect(!output.contains("\u{1B}"), "\(environment)")
            #expect(output.contains("▄███████████▄"))
            #expect(output.split(separator: "\n").allSatisfy { !$0.hasSuffix(" ") })
        }
        // An empty NO_COLOR does not count (no-color.org).
        #expect(TerminalMark.colour(isTerminal: true, environment: ["TERM": "xterm", "NO_COLOR": ""]) == .palette256)
    }

    @Test func theArtIsTheMark() {
        // Four lines of equal width; two eyes knocked out of the tag, side by side, each two
        // columns wide and three half-block pixels tall (round, not tall bars).
        #expect(Set(TerminalMark.art.map(\.count)).count == 1)
        #expect(TerminalMark.art[1].hasPrefix("███  ██  ███"))
        #expect(TerminalMark.art[2].hasPrefix("███▄▄██▄▄███"))
    }
}
