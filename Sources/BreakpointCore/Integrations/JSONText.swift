import Foundation

// A small JSON reader that remembers where every value sits in the original bytes, so installers
// can splice their entries into a user's settings file without re-serialising (and so without
// reordering keys, reformatting or dropping anything).

/// A JSON value Breakpoint writes (object keys keep their order).
indirect enum JValue: Equatable, Sendable {
    case object([JMember])
    case array([JValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func int(_ value: Int) -> JValue { .number(String(value)) }

    /// Equality that ignores object key order and number spelling (`2` == `2.0`).
    func semanticallyEquals(_ other: JValue) -> Bool {
        switch (self, other) {
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for member in a {
                guard let match = b.first(where: { $0.key == member.key }), match.value.semanticallyEquals(member.value) else {
                    return false
                }
            }
            return Set(a.map(\.key)).count == a.count
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.semanticallyEquals($1) }
        case (.number(let a), .number(let b)):
            if a == b { return true }
            guard let x = Double(a), let y = Double(b) else { return false }
            return x == y
        default:
            return self == other
        }
    }

    subscript(key: String) -> JValue? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var isEmptyContainer: Bool {
        switch self {
        case .object(let m): return m.isEmpty
        case .array(let a): return a.isEmpty
        default: return false
        }
    }
}

struct JMember: Equatable, Sendable {
    var key: String
    var value: JValue
    init(_ key: String, _ value: JValue) {
        self.key = key
        self.value = value
    }
}

// MARK: - Rendering

enum JSONRender {
    /// `value` as JSON text. Multi-line output starts at the current position: the first line has
    /// no indentation, nested lines are indented by `indent` + n × `unit`.
    static func render(_ value: JValue, indent: String, unit: String, newline: String, compact: Bool) -> String {
        switch value {
        case .string(let s): return quote(s)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            if items.isEmpty { return "[]" }
            if compact {
                return "[" + items.map { render($0, indent: indent, unit: unit, newline: newline, compact: true) }.joined(separator: ", ") + "]"
            }
            let inner = indent + unit
            return "[" + newline
                + items.map { inner + render($0, indent: inner, unit: unit, newline: newline, compact: false) }
                    .joined(separator: "," + newline)
                + newline + indent + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            if compact {
                return "{" + members.map { quote($0.key) + ": " + render($0.value, indent: indent, unit: unit, newline: newline, compact: true) }
                    .joined(separator: ", ") + "}"
            }
            let inner = indent + unit
            return "{" + newline
                + members.map { inner + quote($0.key) + ": " + render($0.value, indent: inner, unit: unit, newline: newline, compact: false) }
                    .joined(separator: "," + newline)
                + newline + indent + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Parsing with positions

struct JSONSyntaxError: Error, Equatable, Sendable {
    var message: String
    var line: Int
    var column: Int

    /// "unexpected character on line 3"
    var reason: String { "\(message) on line \(line)" }
}

/// A parsed value with its byte range in the source.
struct JNode: Sendable {
    enum Kind: Sendable {
        case object([JNodeMember])
        case array([JNode])
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    var kind: Kind
    /// Offset of the first byte (`{`, `[`, `"`, digit, …).
    var start: Int
    /// Offset just past the last byte.
    var end: Int

    var members: [JNodeMember]? {
        if case .object(let m) = kind { return m }
        return nil
    }

    var elements: [JNode]? {
        if case .array(let e) = kind { return e }
        return nil
    }

    var isObject: Bool { members != nil }
    var isArray: Bool { elements != nil }

    func member(_ key: String) -> JNodeMember? { members?.last { $0.key == key } }

    var value: JValue {
        switch kind {
        case .object(let m): return .object(m.map { JMember($0.key, $0.value.value) })
        case .array(let e): return .array(e.map(\.value))
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .null: return .null
        }
    }
}

struct JNodeMember: Sendable {
    var key: String
    /// Offset of the key's opening quote.
    var start: Int
    var value: JNode
    var end: Int { value.end }
}

/// Recursive-descent JSON parser over UTF-8 bytes. Optionally accepts `//` and `/* */` comments
/// (JSONC). Never accepts trailing commas, single quotes or other JSON5 extensions.
struct JSONTextParser {
    let bytes: [UInt8]
    let allowComments: Bool
    private var i = 0
    private var depth = 0
    static let maxDepth = 256

    init(bytes: [UInt8], allowComments: Bool) {
        self.bytes = bytes
        self.allowComments = allowComments
    }

    /// Parses a whole document: optional BOM, whitespace/comments, one value, whitespace/comments.
    static func parse(_ bytes: [UInt8], allowComments: Bool) throws -> JNode {
        var parser = JSONTextParser(bytes: bytes, allowComments: allowComments)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.i = 3 }
        try parser.skipTrivia()
        guard parser.i < bytes.count else { throw parser.error("the file is empty") }
        let node = try parser.parseValue()
        try parser.skipTrivia()
        guard parser.i == bytes.count else { throw parser.error("unexpected text after the end of the JSON") }
        return node
    }

    private func error(_ message: String) -> JSONSyntaxError {
        var line = 1
        var column = 1
        for b in bytes[..<min(i, bytes.count)] {
            if b == 0x0A { line += 1; column = 1 } else { column += 1 }
        }
        return JSONSyntaxError(message: message, line: line, column: column)
    }

    private mutating func skipTrivia() throws {
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                i += 1
            } else if c == 0x2F, i + 1 < bytes.count, bytes[i + 1] == 0x2F || bytes[i + 1] == 0x2A {
                guard allowComments else { throw error("comments are not allowed in this file") }
                if bytes[i + 1] == 0x2F {
                    while i < bytes.count, bytes[i] != 0x0A { i += 1 }
                } else {
                    i += 2
                    var closed = false
                    while i + 1 < bytes.count {
                        if bytes[i] == 0x2A, bytes[i + 1] == 0x2F { i += 2; closed = true; break }
                        i += 1
                    }
                    guard closed else { throw error("a comment is not closed") }
                }
            } else {
                return
            }
        }
    }

    private mutating func parseValue() throws -> JNode {
        guard i < bytes.count else { throw error("unexpected end of file") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""):
            let start = i
            let s = try parseString()
            return JNode(kind: .string(s), start: start, end: i)
        case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true))
        case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false))
        case UInt8(ascii: "n"): return try parseLiteral("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("unexpected character")
        }
    }

    private mutating func parseLiteral(_ word: String, _ kind: JNode.Kind) throws -> JNode {
        let w = Array(word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { throw error("unexpected word") }
        let start = i
        i += w.count
        return JNode(kind: kind, start: start, end: i)
    }

    private mutating func parseNumber() throws -> JNode {
        let start = i
        func digits() -> Int {
            let s = i
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            return i - s
        }
        if bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { throw error("bad number") }
        if bytes[i] == UInt8(ascii: "0") {
            i += 1
        } else {
            guard digits() > 0 else { throw error("bad number") }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw error("bad number") }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw error("bad number") }
        }
        return JNode(kind: .number(String(decoding: bytes[start..<i], as: UTF8.self)), start: start, end: i)
    }

    private mutating func parseString() throws -> String {
        i += 1  // opening quote
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flushRaw() throws {
            guard !raw.isEmpty else { return }
            guard let s = String(bytes: raw, encoding: .utf8) else { throw error("text that is not UTF-8") }
            scalars.append(contentsOf: s.unicodeScalars)
            raw.removeAll(keepingCapacity: true)
        }
        while true {
            guard i < bytes.count else { throw error("a string is not closed") }
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                try flushRaw()
                return String(scalars)
            }
            if c < 0x20 { throw error("a control character inside a string") }
            if c == UInt8(ascii: "\\") {
                try flushRaw()
                i += 1
                guard i < bytes.count else { throw error("a string is not closed") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {
                        if i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                code = 0xFFFD
                            }
                        } else {
                            code = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(code) {
                        code = 0xFFFD
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default:
                    throw error("a bad escape in a string")
                }
            } else {
                raw.append(c)
                i += 1
            }
        }
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else {
            throw error("a bad \\u escape")
        }
        i += 4
        return v
    }

    private mutating func parseArray() throws -> JNode {
        let start = i
        depth += 1
        guard depth <= Self.maxDepth else { throw error("nesting is too deep") }
        defer { depth -= 1 }
        i += 1
        var items: [JNode] = []
        try skipTrivia()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
            i += 1
            return JNode(kind: .array(items), start: start, end: i)
        }
        while true {
            try skipTrivia()
            items.append(try parseValue())
            try skipTrivia()
            guard i < bytes.count else { throw error("a list is not closed") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                try skipTrivia()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { throw error("a trailing comma") }
                continue
            }
            if bytes[i] == UInt8(ascii: "]") {
                i += 1
                return JNode(kind: .array(items), start: start, end: i)
            }
            throw error("expected , or ]")
        }
    }

    private mutating func parseObject() throws -> JNode {
        let start = i
        depth += 1
        guard depth <= Self.maxDepth else { throw error("nesting is too deep") }
        defer { depth -= 1 }
        i += 1
        var members: [JNodeMember] = []
        try skipTrivia()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
            i += 1
            return JNode(kind: .object(members), start: start, end: i)
        }
        while true {
            try skipTrivia()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected a quoted key") }
            let keyStart = i
            let key = try parseString()
            try skipTrivia()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected :") }
            i += 1
            try skipTrivia()
            let value = try parseValue()
            members.append(JNodeMember(key: key, start: keyStart, value: value))
            try skipTrivia()
            guard i < bytes.count else { throw error("an object is not closed") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                try skipTrivia()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { throw error("a trailing comma") }
                continue
            }
            if bytes[i] == UInt8(ascii: "}") {
                i += 1
                return JNode(kind: .object(members), start: start, end: i)
            }
            throw error("expected , or }")
        }
    }
}

// MARK: - Text-preserving edits

/// A JSON document being edited in place. Every edit splices bytes and re-parses, so unrelated
/// text (keys, order, spacing, comments) is never touched.
struct JSONTextDocument {
    private(set) var bytes: [UInt8]
    let allowComments: Bool
    private(set) var root: JNode

    init(text: String, allowComments: Bool) throws {
        bytes = Array(text.utf8)
        self.allowComments = allowComments
        root = try JSONTextParser.parse(bytes, allowComments: allowComments)
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    var newline: String {
        var previous: UInt8 = 0
        for b in bytes {
            if b == 0x0A { return previous == 0x0D ? "\r\n" : "\n" }
            previous = b
        }
        return "\n"
    }

    /// The indentation step: the leading whitespace of the root's first member when it sits on its
    /// own line, else two spaces.
    var indentUnit: String {
        if let first = root.members?.first, isOnOwnLine(first.start) {
            let indent = lineIndent(at: first.start)
            if !indent.isEmpty { return indent }
        }
        if let first = root.elements?.first, isOnOwnLine(first.start) {
            let indent = lineIndent(at: first.start)
            if !indent.isEmpty { return indent }
        }
        return "  "
    }

    private func lineStart(_ offset: Int) -> Int {
        var s = offset
        while s > 0, bytes[s - 1] != 0x0A { s -= 1 }
        return s
    }

    func lineIndent(at offset: Int) -> String {
        var s = lineStart(offset)
        var indent: [UInt8] = []
        while s < bytes.count, bytes[s] == 0x20 || bytes[s] == 0x09 {
            indent.append(bytes[s])
            s += 1
        }
        return String(decoding: indent, as: UTF8.self)
    }

    func isOnOwnLine(_ offset: Int) -> Bool {
        var s = lineStart(offset)
        while s < offset {
            if bytes[s] != 0x20 && bytes[s] != 0x09 { return false }
            s += 1
        }
        return true
    }

    private mutating func splice(_ range: Range<Int>, with replacement: String) throws {
        bytes.replaceSubrange(range, with: Array(replacement.utf8))
        root = try JSONTextParser.parse(bytes, allowComments: allowComments)
    }

    /// Finds the node at `path`.
    func node(at path: [JPath]) -> JNode? {
        var node = root
        for component in path {
            switch component {
            case .key(let key):
                guard let next = node.member(key)?.value else { return nil }
                node = next
            case .index(let index):
                guard let elements = node.elements, elements.indices.contains(index) else { return nil }
                node = elements[index]
            }
        }
        return node
    }

    /// Appends `key: value` as the last member of the object at `path`.
    mutating func appendMember(_ key: String, _ value: JValue, toObjectAt path: [JPath]) throws {
        guard let object = node(at: path), let members = object.members else { throw JSONEditError.notAnObject(path) }
        try append(to: object, itemStart: members.last?.start, itemEnd: members.last?.end) { indent, unit, newline, compact in
            JSONRender.quote(key) + ": " + JSONRender.render(value, indent: indent, unit: unit, newline: newline, compact: compact)
        }
    }

    /// Appends `value` as the last element of the array at `path`.
    mutating func appendElement(_ value: JValue, toArrayAt path: [JPath]) throws {
        guard let array = node(at: path), let elements = array.elements else { throw JSONEditError.notAList(path) }
        try append(to: array, itemStart: elements.last?.start, itemEnd: elements.last?.end) { indent, unit, newline, compact in
            JSONRender.render(value, indent: indent, unit: unit, newline: newline, compact: compact)
        }
    }

    /// Appends into a container at its end, matching the surrounding layout. Inserting after an
    /// existing item adds `,<newline><indent>item` right after that item, which `removeItem`
    /// deletes exactly, so an install followed by an uninstall restores the bytes.
    private mutating func append(to container: JNode, itemStart: Int?, itemEnd: Int?,
                                 render: (_ indent: String, _ unit: String, _ newline: String, _ compact: Bool) -> String) throws {
        let unit = indentUnit
        let nl = newline
        if let itemStart, let itemEnd {
            if isOnOwnLine(itemStart) {
                let indent = lineIndent(at: itemStart)
                try splice(itemEnd..<itemEnd, with: "," + nl + indent + render(indent, unit, nl, false))
            } else {
                try splice(itemEnd..<itemEnd, with: ", " + render("", unit, nl, true))
            }
            return
        }
        let containerIndent = lineIndent(at: container.start)
        let inner = containerIndent + unit
        let interior = (container.start + 1)..<(container.end - 1)
        let interiorIsBlank = bytes[interior].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        let rootIsEmpty = (root.members?.isEmpty ?? false) || (root.elements?.isEmpty ?? false)
        if interiorIsBlank, !rootIsEmpty, !bytes[root.start..<root.end].contains(0x0A) {
            // A one-line document with content stays on one line.
            try splice(interior, with: render("", unit, nl, true))
        } else if interiorIsBlank {
            try splice(interior, with: nl + inner + render(inner, unit, nl, false) + nl + containerIndent)
        } else {
            // Only comments inside: keep them, put the item first.
            try splice(interior.lowerBound..<interior.lowerBound, with: nl + inner + render(inner, unit, nl, false))
        }
    }

    /// Removes the member `key` (the last one with that name) from the object at `path`.
    mutating func removeMember(_ key: String, fromObjectAt path: [JPath]) throws {
        guard let object = node(at: path), let members = object.members else { throw JSONEditError.notAnObject(path) }
        guard let index = members.lastIndex(where: { $0.key == key }) else { return }
        try removeItem(at: index, in: object, starts: members.map(\.start), ends: members.map(\.end))
    }

    /// Removes element `index` from the array at `path`.
    mutating func removeElement(at index: Int, fromArrayAt path: [JPath]) throws {
        guard let array = node(at: path), let elements = array.elements else { throw JSONEditError.notAList(path) }
        try removeItem(at: index, in: array, starts: elements.map(\.start), ends: elements.map(\.end))
    }

    private mutating func removeItem(at index: Int, in container: JNode, starts: [Int], ends: [Int]) throws {
        guard starts.indices.contains(index) else { return }
        if starts.count == 1 {
            // Keep anything but whitespace (comments) that follows the item; drop the rest.
            let after = ends[0]..<(container.end - 1)
            let blankAfter = bytes[after].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
            try splice((container.start + 1)..<(blankAfter ? container.end - 1 : ends[0]), with: "")
        } else if index > 0 {
            try splice(ends[index - 1]..<ends[index], with: "")
        } else {
            try splice(starts[0]..<starts[1], with: "")
        }
    }
}

enum JSONEditError: Error, Equatable {
    case notAnObject([JPath])
    case notAList([JPath])
}

/// One step of a path into a JSON document.
enum JPath: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case key(String)
    case index(Int)
    init(stringLiteral value: String) { self = .key(value) }
    init(integerLiteral value: Int) { self = .index(value) }
}

extension JValue {
    /// Parses our own JSON snippets (tests and `HookEntry.handlerJSON`).
    static func parse(_ text: String) throws -> JValue {
        try JSONTextParser.parse(Array(text.utf8), allowComments: false).value
    }
}
