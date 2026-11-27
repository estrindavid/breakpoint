import Foundation

/// Errors from encoding or decoding wire lines (SPEC §6).
public enum WireError: Error, Equatable, Sendable {
    /// The line is longer than `WireMessage.maxLineBytes`.
    case lineTooLong(Int)
    /// Not a JSON object, or a required field is missing or of the wrong type.
    case malformed(String)
    /// An event kind this version does not know. Callers drop the message without error.
    case unknownEventKind(String)
}

/// The app's answer to `{"v":1,"type":"status"}`: sessions, timers and pause state (SPEC §6).
/// Printed by `breakpoint status` and `breakpoint doctor`.
public struct StatusReport: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable {
        public var source: AgentSource
        public var sessionID: String
        public var state: AgentState
        public var cwd: String?
        public var lastEventAt: Date
        /// Start of the current run while working or waiting (absent from apps before 0.3).
        public var runStartedAt: Date?

        public init(source: AgentSource, sessionID: String, state: AgentState, cwd: String?, lastEventAt: Date,
                    runStartedAt: Date? = nil) {
            self.source = source
            self.sessionID = sessionID
            self.state = state
            self.cwd = cwd
            self.lastEventAt = lastEventAt
            self.runStartedAt = runStartedAt
        }
    }

    /// The break that comes next and when, as the menu bar counts it (SPEC §2.3, §3.7): `seconds`
    /// ≤ 0 means it is due.
    public struct NextBreak: Codable, Equatable, Sendable {
        public var kind: BreakKind
        public var seconds: TimeInterval
        public init(kind: BreakKind, seconds: TimeInterval) {
            self.kind = kind
            self.seconds = seconds
        }
    }

    /// A break on screen now (previews excluded).
    public struct ActiveBreak: Codable, Equatable, Sendable {
        public var kind: BreakKind
        public var startedAt: Date
        /// Planned length plus extensions, in seconds.
        public var length: TimeInterval
        public init(kind: BreakKind, startedAt: Date, length: TimeInterval) {
            self.kind = kind
            self.startedAt = startedAt
            self.length = length
        }
    }

    /// A nudge on screen now (previews excluded); `title` is the card's own words ("2-min stretch?").
    public struct Nudge: Codable, Equatable, Sendable {
        public var kind: BreakKind
        public var title: String
        public init(kind: BreakKind, title: String) {
            self.kind = kind
            self.title = title
        }
    }

    public var appVersion: String
    public var generatedAt: Date
    public var sessions: [Session]
    public var commands: [RunningCommand]
    public var timers: TimerState
    public var cadence: Cadence
    /// One sentence when paused ("Paused: microphone is on"); `nil` otherwise.
    public var paused: String?
    public var away: Bool
    /// Last event time per source (for `doctor`).
    public var lastEventBySource: [AgentSource: Date]
    // For `breakpoint status --line` (SPEC §5.8). Optional, so a reply from an app before 0.3
    // still decodes.
    public var nextBreak: NextBreak?
    public var activeBreak: ActiveBreak?
    public var nudge: Nudge?

    public init(
        appVersion: String = BreakpointVersion.current,
        generatedAt: Date,
        sessions: [Session] = [],
        commands: [RunningCommand] = [],
        timers: TimerState = .zero,
        cadence: Cadence = Settings.defaults.cadence,
        paused: String? = nil,
        away: Bool = false,
        lastEventBySource: [AgentSource: Date] = [:],
        nextBreak: NextBreak? = nil,
        activeBreak: ActiveBreak? = nil,
        nudge: Nudge? = nil
    ) {
        self.appVersion = appVersion
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.commands = commands
        self.timers = timers
        self.cadence = cadence
        self.paused = paused
        self.away = away
        self.lastEventBySource = lastEventBySource
        self.nextBreak = nextBreak
        self.activeBreak = activeBreak
        self.nudge = nudge
    }
}

/// One line of the socket protocol (SPEC §6): a UTF-8 JSON object with `"v":1` and a `type`.
///
/// - `{"v":1,"type":"event","event":{…}}` — an `AgentEvent`; fire-and-forget, no reply.
/// - `{"v":1,"type":"status"}` — request; the server replies with one `statusReply` line.
/// - `{"v":1,"type":"statusReply","status":{…}}` — the reply (`StatusReport`).
/// - `{"v":1,"type":"command","name":"…","args":[…]}` — a request the app answers with one
///   `reply` line of plain text: `activate` (a second copy of the app hands over to the running
///   one), `signals` (the activity monitor's diagnostic report, for `breakpoint doctor`) and, in
///   debug builds only, `debug` (the end-to-end harness, see CLAUDE.md).
/// - `{"v":1,"type":"reply","text":"…"}` — the answer to a `command`.
///
/// Unknown fields are ignored. Unknown `type`s, unknown event kinds and other versions decode to
/// `nil` (dropped without error). Dates are seconds since 1970 (JSON numbers).
public enum WireMessage: Equatable, Sendable {
    case event(AgentEvent)
    case statusRequest
    case statusReply(StatusReport)
    /// A named request with string arguments, answered with `.reply` (see above).
    case command(name: String, arguments: [String])
    /// Plain-text answer to `.command`.
    case reply(String)

    public static let version = 1
    /// Maximum bytes per line, excluding the newline.
    public static let maxLineBytes = 64 * 1024

    private enum CodingKeys: String, CodingKey { case v, type, event, status, name, args, text }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// The JSON object for this message, without a trailing newline.
    public func encoded() throws -> Data {
        let encoder = Self.makeEncoder()
        let data: Data
        switch self {
        case .event(let event):
            data = try encoder.encode(Envelope(v: Self.version, type: "event", event: event, status: nil))
        case .statusRequest:
            data = try encoder.encode(Envelope(v: Self.version, type: "status", event: nil, status: nil))
        case .statusReply(let report):
            data = try encoder.encode(Envelope(v: Self.version, type: "statusReply", event: nil, status: report))
        case .command(let name, let arguments):
            data = try encoder.encode(Envelope(v: Self.version, type: "command", name: name, args: arguments))
        case .reply(let text):
            data = try encoder.encode(Envelope(v: Self.version, type: "reply", text: text))
        }
        guard data.count <= Self.maxLineBytes else { throw WireError.lineTooLong(data.count) }
        return data
    }

    /// The encoded object followed by "\n", ready to write to the socket.
    public func encodedLine() throws -> Data {
        var data = try encoded()
        data.append(0x0A)
        return data
    }

    /// Decodes one line (a trailing newline is allowed).
    /// - Returns: the message, or `nil` if it should be dropped silently (unknown type or kind,
    ///   other protocol version).
    /// - Throws: `WireError.lineTooLong` or `WireError.malformed`.
    public static func decode(line: Data) throws -> WireMessage? {
        var line = line
        while let last = line.last, last == 0x0A || last == 0x0D { line.removeLast() }
        guard line.count <= maxLineBytes else { throw WireError.lineTooLong(line.count) }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: line)
        } catch {
            throw WireError.malformed("not JSON")
        }
        guard let dict = object as? [String: Any] else { throw WireError.malformed("not an object") }
        guard let v = dict["v"] as? Int else { throw WireError.malformed("missing v") }
        guard v == version else { return nil }
        guard let type = dict["type"] as? String else { throw WireError.malformed("missing type") }
        let decoder = makeDecoder()
        switch type {
        case "event":
            guard let eventObject = dict["event"] as? [String: Any] else { throw WireError.malformed("missing event") }
            let eventData = try JSONSerialization.data(withJSONObject: eventObject)
            do {
                return .event(try decoder.decode(AgentEvent.self, from: eventData))
            } catch WireError.unknownEventKind {
                return nil
            } catch {
                throw WireError.malformed("bad event: \(error)")
            }
        case "status":
            return .statusRequest
        case "statusReply":
            guard let statusObject = dict["status"] as? [String: Any] else { throw WireError.malformed("missing status") }
            let statusData = try JSONSerialization.data(withJSONObject: statusObject)
            do {
                return .statusReply(try decoder.decode(StatusReport.self, from: statusData))
            } catch {
                throw WireError.malformed("bad status: \(error)")
            }
        case "command":
            guard let name = dict["name"] as? String, !name.isEmpty else { throw WireError.malformed("missing name") }
            let arguments = (dict["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .command(name: name, arguments: arguments)
        case "reply":
            guard let text = dict["text"] as? String else { throw WireError.malformed("missing text") }
            return .reply(text)
        default:
            return nil
        }
    }

    private struct Envelope: Encodable {
        var v: Int
        var type: String
        var event: AgentEvent? = nil
        var status: StatusReport? = nil
        var name: String? = nil
        var args: [String]? = nil
        var text: String? = nil

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(v, forKey: .v)
            try c.encode(type, forKey: .type)
            try c.encodeIfPresent(event, forKey: .event)
            try c.encodeIfPresent(status, forKey: .status)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(args, forKey: .args)
            try c.encodeIfPresent(text, forKey: .text)
        }
    }
}
