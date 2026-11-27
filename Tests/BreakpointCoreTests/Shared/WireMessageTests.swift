import Foundation
import Testing
@testable import BreakpointCore

@Suite("Wire format (SPEC §6)")
struct WireMessageTests {
    let specLine = #"""
    {"v":1,"type":"event","event":{"kind":"agentStarted","source":"claude-code","sessionID":"abc","cwd":"/path/project","title":"fix the login redirect","detail":null,"via":null,"ts":1795400000.0}}
    """#

    @Test func decodesTheSpecExample() throws {
        let message = try WireMessage.decode(line: Data(specLine.utf8))
        let expected = AgentEvent(kind: .agentStarted, source: .claudeCode, sessionID: "abc", cwd: "/path/project",
                                  title: "fix the login redirect", timestamp: Date(timeIntervalSince1970: 1_795_400_000))
        #expect(message == .event(expected))
    }

    @Test func eventRoundTrip() throws {
        let event = AgentEvent(kind: .commandFinished, source: .shell, sessionID: "4242", cwd: "/tmp/x", title: "swift",
                               detail: "x", via: AgentEvent.viaClaudeCodeHooks, timestamp: Date(timeIntervalSince1970: 1_795_400_123.5),
                               durationMS: 25_000, exitCode: 1)
        let line = try WireMessage.event(event).encodedLine()
        #expect(line.last == 0x0A)
        #expect(try WireMessage.decode(line: line) == .event(event))
    }

    @Test func encodesNullsForCoreOptionalsAndOmitsNumbers() throws {
        let event = AgentEvent(kind: .agentFinished, source: .codex, timestamp: Date(timeIntervalSince1970: 1))
        let text = String(decoding: try WireMessage.event(event).encoded(), as: UTF8.self)
        #expect(text.contains(#""detail":null"#))
        #expect(text.contains(#""sessionID":null"#))
        #expect(!text.contains("durationMS"))
        #expect(text.contains(#""ts":1"#))
        #expect(text.contains(#""v":1"#))
    }

    @Test func unknownKindIsDroppedWithoutError() throws {
        let line = #"{"v":1,"type":"event","event":{"kind":"teleported","source":"x","ts":1}}"#
        #expect(try WireMessage.decode(line: Data(line.utf8)) == nil)
    }

    @Test func unknownTypeAndOtherVersionsAreDropped() throws {
        #expect(try WireMessage.decode(line: Data(#"{"v":1,"type":"party"}"#.utf8)) == nil)
        #expect(try WireMessage.decode(line: Data(#"{"v":2,"type":"status"}"#.utf8)) == nil)
    }

    @Test func unknownFieldsAreIgnored() throws {
        let line = #"{"v":1,"type":"event","extra":true,"event":{"kind":"test","source":"cursor","ts":5,"color":"blue"}}"#
        let message = try WireMessage.decode(line: Data(line.utf8))
        #expect(message == .event(AgentEvent(kind: .test, source: .cursor, timestamp: Date(timeIntervalSince1970: 5))))
    }

    @Test func malformedLinesThrow() {
        #expect(throws: WireError.self) { try WireMessage.decode(line: Data("nope".utf8)) }
        #expect(throws: WireError.self) { try WireMessage.decode(line: Data("[1,2]".utf8)) }
        #expect(throws: WireError.self) { try WireMessage.decode(line: Data(#"{"type":"status"}"#.utf8)) }
        #expect(throws: WireError.self) {
            try WireMessage.decode(line: Data(#"{"v":1,"type":"event","event":{"kind":"test"}}"#.utf8))
        }
    }

    @Test func oversizedLinesAreRejected() {
        let huge = String(repeating: "a", count: WireMessage.maxLineBytes + 1)
        #expect(throws: WireError.lineTooLong(WireMessage.maxLineBytes + 1)) {
            try WireMessage.decode(line: Data(huge.utf8))
        }
        let event = AgentEvent(kind: .agentStarted, source: .claudeCode, title: huge, timestamp: Date())
        #expect(throws: WireError.self) { try WireMessage.event(event).encoded() }
    }

    @Test func statusRequestAndReplyRoundTrip() throws {
        #expect(String(decoding: try WireMessage.statusRequest.encoded(), as: UTF8.self) == #"{"type":"status","v":1}"#)
        #expect(try WireMessage.decode(line: Data(#"{"v":1,"type":"status"}"#.utf8)) == .statusRequest)
        let report = StatusReport(
            generatedAt: Date(timeIntervalSince1970: 1_795_400_000),
            sessions: [.init(source: .claudeCode, sessionID: "a", state: .working, cwd: "/p",
                             lastEventAt: Date(timeIntervalSince1970: 1_795_399_000))],
            commands: [RunningCommand(shellPID: "12", command: "swift", startedAt: Date(timeIntervalSince1970: 1_795_399_990))],
            timers: TimerState(screenTime: 600, stillTime: 1200),
            paused: "Paused: microphone is on",
            lastEventBySource: [.claudeCode: Date(timeIntervalSince1970: 1_795_399_000)])
        let decoded = try WireMessage.decode(line: try WireMessage.statusReply(report).encodedLine())
        #expect(decoded == .statusReply(report))
    }

    @Test func commandAndReplyRoundTrip() throws {
        let command = WireMessage.command(name: "debug", arguments: ["advance", "30"])
        #expect(String(decoding: try command.encoded(), as: UTF8.self) == #"{"args":["advance","30"],"name":"debug","type":"command","v":1}"#)
        #expect(try WireMessage.decode(line: try command.encodedLine()) == command)
        #expect(try WireMessage.decode(line: Data(#"{"v":1,"type":"command","name":"signals"}"#.utf8))
                == .command(name: "signals", arguments: []))
        #expect(throws: WireError.self) { try WireMessage.decode(line: Data(#"{"v":1,"type":"command"}"#.utf8)) }
        let reply = WireMessage.reply("Idle 3 s\nCamera: off")
        #expect(try WireMessage.decode(line: try reply.encodedLine()) == reply)
    }
}
