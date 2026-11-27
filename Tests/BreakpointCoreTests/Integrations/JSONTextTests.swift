import Foundation
import Testing
@testable import BreakpointCore

@Suite("JSON text editing")
struct JSONTextTests {
    @Test func parsesEveryValueKindWithPositions() throws {
        let text = #"{"a": [1, -2.5e3, true, false, null], "b": "x\"\u00e9\ud83d\ude00", "c": {}}"#
        let doc = try JSONTextDocument(text: text, allowComments: false)
        let a = try #require(doc.node(at: ["a"]))
        #expect(String(decoding: Array(text.utf8)[a.start..<a.end], as: UTF8.self) == "[1, -2.5e3, true, false, null]")
        #expect(doc.node(at: ["b"])?.value == .string("x\"é😀"))
        #expect(doc.node(at: ["a", 1])?.value == .number("-2.5e3"))
    }

    @Test(arguments: [
        "", "   ", "{", "{\"a\":}", "{\"a\":1,}", "[1,]", "{'a':1}", "{\"a\":1} x", "{\"a\":01}", "{\"a\":\"\u{01}\"}",
        "{\"a\":1} // c", "{/* c */}", "{\"a\": tru}", "{\"a\":\"\\x\"}", "nul",
    ])
    func rejectsInvalidStrictJSON(_ text: String) {
        #expect(throws: JSONSyntaxError.self) { try JSONTextDocument(text: text, allowComments: false) }
    }

    @Test func acceptsCommentsOnlyWhenAllowed() throws {
        let text = "// head\n{\n  /* inline */ \"a\": 1 // tail\n}\n/* end */\n"
        _ = try JSONTextDocument(text: text, allowComments: true)
        #expect(throws: JSONSyntaxError.self) { try JSONTextDocument(text: text, allowComments: false) }
        #expect(throws: JSONSyntaxError.self) { try JSONTextDocument(text: "{ /* open", allowComments: true) }
    }

    @Test func acceptsByteOrderMark() throws {
        let doc = try JSONTextDocument(text: "\u{FEFF}{\"a\": 1}", allowComments: false)
        #expect(doc.node(at: ["a"])?.value == .number("1"))
    }

    @Test func syntaxErrorsNameTheLine() {
        do {
            _ = try JSONTextDocument(text: "{\n  \"a\": 1,\n  \"b\" 2\n}", allowComments: false)
            Issue.record("expected an error")
        } catch let error as JSONSyntaxError {
            #expect(error.line == 3)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func appendAndRemoveRestoreBytesExactly() throws {
        let originals = [
            "{}",
            "{}\n",
            "{\n  \"a\": 1\n}\n",
            "{\n\t\"a\": [\n\t\t1\n\t]\n}",
            "{\"a\": 1, \"b\": [1, 2]}",
            "{\r\n    \"a\": 1\r\n}\r\n",
        ]
        for original in originals {
            var doc = try JSONTextDocument(text: original, allowComments: false)
            try doc.appendMember("hooks", .object([JMember("x", .array([.string("y")]))]), toObjectAt: [])
            #expect(doc.node(at: ["hooks", "x", 0])?.value == .string("y"))
            try doc.removeMember("hooks", fromObjectAt: [])
            #expect(doc.text == original, "\(original.debugDescription)")
        }
    }

    @Test func appendFollowsSurroundingIndentation() throws {
        var doc = try JSONTextDocument(text: "{\n\t\"a\": 1\n}\n", allowComments: false)
        try doc.appendMember("b", .object([JMember("c", .bool(true))]), toObjectAt: [])
        #expect(doc.text == "{\n\t\"a\": 1,\n\t\"b\": {\n\t\t\"c\": true\n\t}\n}\n")

        var crlf = try JSONTextDocument(text: "{\r\n  \"a\": 1\r\n}", allowComments: false)
        try crlf.appendMember("b", .array([.int(2)]), toObjectAt: [])
        #expect(crlf.text == "{\r\n  \"a\": 1,\r\n  \"b\": [\r\n    2\r\n  ]\r\n}")
    }

    @Test func oneLineDocumentsStayOnOneLine() throws {
        var doc = try JSONTextDocument(text: "{\"a\": 1}", allowComments: false)
        try doc.appendMember("hooks", .object([]), toObjectAt: [])
        try doc.appendMember("Stop", .array([]), toObjectAt: ["hooks"])
        try doc.appendElement(.object([JMember("k", .string("v"))]), toArrayAt: ["hooks", "Stop"])
        #expect(doc.text == "{\"a\": 1, \"hooks\": {\"Stop\": [{\"k\": \"v\"}]}}")
    }

    @Test func removingFirstOfSeveralKeepsTheRest() throws {
        var doc = try JSONTextDocument(text: "[\n  1,\n  2,\n  3\n]", allowComments: false)
        try doc.removeElement(at: 0, fromArrayAt: [])
        #expect(doc.text == "[\n  2,\n  3\n]")
        try doc.removeElement(at: 1, fromArrayAt: [])
        #expect(doc.text == "[\n  2\n]")
    }

    @Test func renderEscapes() {
        #expect(JSONRender.quote("a\"b\\c\n\u{01}/é") == "\"a\\\"b\\\\c\\n\\u0001/é\"")
    }

    @Test func semanticEqualityIgnoresKeyOrderAndNumberSpelling() throws {
        #expect(try json("{\"a\":1,\"b\":[2.0]}").semanticallyEquals(try json("{\"b\":[2],\"a\":1.0}")))
        #expect(!(try json("{\"a\":1}").semanticallyEquals(try json("{\"a\":1,\"b\":1}"))))
        #expect(!(try json("[1,2]").semanticallyEquals(try json("[2,1]"))))
    }
}
