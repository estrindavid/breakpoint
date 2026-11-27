import Foundation

/// A change the coordinator reacts to (resume cards, withdrawing nudges, wind-down, history).
public enum SessionTransition: Equatable, Sendable {
    /// A session appeared (`sessionStarted`, or the first event of an unknown session).
    case sessionStarted(SessionKey)
    /// A run started (`agentStarted`).
    case runStarted(SessionKey)
    /// The session entered `waiting` (needs the user).
    case needsUser(SessionKey)
    /// `waiting` → `working` (the user approved something), or a session idled by the interrupt
    /// fallback showed it was still working.
    case resumedWorking(SessionKey)
    /// A run ended; `.finished` runs were recorded by the estimator.
    case runEnded(SessionKey, RunEnding)
    /// The session was removed (`sessionEnded`, or no event for 2 h).
    case sessionEnded(SessionKey)
    case commandStarted(RunningCommand)
    /// A command ended (or was replaced or expired). The result is there when the shell reported
    /// the end with `commandFinished` (exit status and duration).
    case commandFinished(RunningCommand, CommandResult?)
}

/// What one event (or one expiry pass) changed.
public struct TrackerUpdate: Equatable, Sendable {
    public var transitions: [SessionTransition]
    /// The `agentStarted` opportunity, if the event produced one.
    public var opportunity: Opportunity?
    /// The event was dropped (relayed duplicate, unknown session for a non-creating event, `test`).
    public var dropped: Bool

    public init(transitions: [SessionTransition] = [], opportunity: Opportunity? = nil, dropped: Bool = false) {
        self.transitions = transitions
        self.opportunity = opportunity
        self.dropped = dropped
    }

    public static let none = TrackerUpdate()
    static let droppedEvent = TrackerUpdate(dropped: true)
}

/// Turns `AgentEvent`s into `AgentSession`s and `RunningCommand`s (SPEC §2.6). A value type with
/// no I/O; the coordinator persists `estimator` to `sessions.json` via `RunLengthEstimator.file`.
/// All times come from the `now` passed in (the coordinator's clock), never from event timestamps.
///
/// Contract (`apply`):
/// - `sessionStarted` → create session, `idle` (an existing session only refreshes: Claude Code
///   also sends it after compaction, mid-run).
/// - `agentStarted` → `working`, start a run (a previous `working` or `waiting` run closes as
///   `.cancelled`, not recorded); emits an `agentStarted` opportunity. Creates the session if
///   unknown. Stores `title` only when `storePromptSnippets` is on.
/// - `agentActivity` → refresh `lastEventAt`; `waiting` → `working` (`.resumedWorking`). On a
///   session idled by the interrupt fallback it revives the run (`.resumedWorking`); on any other
///   idle session it only refreshes (an async hook can arrive after `agentFinished`). A `tool` of
///   kind `edit` or `command` is counted in the run's `report` while the session is not idle.
/// - `agentNeedsUser` → `waiting` (`.needsUser`). With detail `idle_prompt`: only if `working`;
///   ignored on an `idle` session. An event that names a `tool` sets the run's `request` (the
///   subject only with snippets on); one without keeps the request already known.
/// - `agentFinished` with detail `background` (background work still running) → handled like
///   `agentActivity` without a tool: the session stays (or becomes) `working`; nothing ends.
/// - `agentFinished` → `idle`. Detail `aborted` / `interrupted` → `.cancelled`; `error` (or
///   `failed`, `failure`) → `.failed` with the event's `reason` kept in the report; otherwise
///   `.finished(duration)` and the run is recorded by the estimator; the event's `message` (snippets
///   on only) is kept in the report. A run idled by the interrupt fallback still ends normally here
///   but is not recorded. A second `agentFinished` for an already idle session only refreshes it.
/// - `subagentFinished` → refresh `lastEventAt` only.
/// - `sessionEnded` → remove.
/// - `commandStarted` / `commandFinished` → `RunningCommand` keyed by shell PID (source `shell`);
///   `commandFinished` carries a `CommandResult` (exit status, duration: the event's `durationMS`,
///   else the time since `commandStarted`).
///   Interactive programs (`CommandDenylist`) are not tracked: they never make opportunities and
///   would only clutter the agents list.
/// - `test` → dropped (the coordinator handles it before the tracker).
/// - Relayed duplicates: `via == "claude-code-hooks"` with source `cursor` is dropped when
///   `nativeCursorInstalled`, accepted otherwise.
/// - Unknown sessions: `sessionStarted`, `agentStarted`, `agentActivity`, `agentNeedsUser` (not
///   `idle_prompt`) and `agentFinished` create the session (the app may have started mid-run, e.g.
///   after a watchdog relaunch); a run whose start was not seen is never recorded.
///   `subagentFinished`, `sessionEnded` and `idle_prompt` on an unknown session are dropped.
///
/// Run length for the estimator = working time: the run's wall time minus the time it spent
/// `waiting` for the user (a run that waited ten minutes for a permission answer is not a
/// ten-minute run). The resume card's "ran N min" uses the wall time.
///
/// Contract (`expire`, every tick): `working` sessions with no event for 10 min (Claude Code) or
/// 60 min (others) → `idle`, run `.cancelled`; sessions with no event for 2 h removed; commands
/// older than 60 min removed. A later `agentFinished` on a stale-idled session is handled normally.
public struct SessionTracker: Equatable, Sendable {
    public private(set) var sessions: [AgentSession]
    public private(set) var commands: [RunningCommand]
    public var estimator: RunLengthEstimator
    /// The native Cursor integration is installed (relayed Cursor events are then dropped).
    public var nativeCursorInstalled: Bool
    /// "Keep prompt snippets" (SPEC §3.9 Privacy). When off, titles, agent messages and request
    /// subjects are never stored, and turning it off forgets the stored ones.
    public var storePromptSnippets: Bool {
        didSet {
            guard !storePromptSnippets else { return }
            for index in sessions.indices {
                sessions[index].title = nil
                sessions[index].report = sessions[index].report.withoutSensitiveText
            }
        }
    }

    /// Per-run bookkeeping that is not part of `AgentSession`.
    struct RunNotes: Equatable, Sendable {
        /// The run's start was not observed (session created mid-run), so its length is unknown.
        var startUnobserved = false
        /// Time spent `waiting` so far.
        var waited: TimeInterval = 0
    }

    private var runNotes: [SessionKey: RunNotes] = [:]
    /// Runs idled by the interrupt fallback: their start, so a late `agentFinished` or
    /// `agentActivity` can still be handled normally.
    private var staleRuns: [SessionKey: Date] = [:]

    public init(estimator: RunLengthEstimator = RunLengthEstimator(), nativeCursorInstalled: Bool = false,
                storePromptSnippets: Bool = true) {
        self.sessions = []
        self.commands = []
        self.estimator = estimator
        self.nativeCursorInstalled = nativeCursorInstalled
        self.storePromptSnippets = storePromptSnippets
    }

    // MARK: Events

    public mutating func apply(_ event: AgentEvent, now: Date) -> TrackerUpdate {
        if event.kind == .test { return .droppedEvent }
        if isRelayedDuplicate(event) { return .droppedEvent }
        if event.kind.isCommandEvent { return applyCommand(event, now: now) }

        let key = SessionKey(source: event.source, sessionID: Self.sessionID(for: event))
        var transitions: [SessionTransition] = []
        let isIdlePrompt = event.kind == .agentNeedsUser && event.detail == Self.idlePrompt

        var index = sessions.firstIndex { $0.key == key }
        if index == nil {
            switch event.kind {
            case .sessionStarted, .agentStarted, .agentActivity, .agentFinished:
                break
            case .agentNeedsUser where !isIdlePrompt:
                break
            default:
                return .droppedEvent
            }
            sessions.append(AgentSession(key: key, state: .idle, createdAt: now))
            index = sessions.count - 1
            transitions.append(.sessionStarted(key))
        }
        guard let i = index else { return .droppedEvent }

        sessions[i].lastEventAt = now
        if let cwd = event.cwd, !cwd.isEmpty { sessions[i].cwd = cwd }
        sessions[i].via = event.via
        var opportunity: Opportunity?

        switch event.kind {
        case .sessionStarted, .subagentFinished:
            break

        case .agentStarted:
            if sessions[i].state != .idle {
                transitions.append(endRun(at: i, ending: .cancelled, now: now))
            }
            staleRuns[key] = nil
            startRun(at: i, now: now, observed: true)
            sessions[i].title = storePromptSnippets ? event.title.flatMap(Self.cleanTitle) : nil
            sessions[i].report = .empty
            transitions.append(.runStarted(key))
            opportunity = Opportunity(kind: .agentStarted, source: key.source, sessionID: key.sessionID, createdAt: now)

        case .agentActivity:
            continueWorking(at: i, key: key, now: now, transitions: &transitions)
            if sessions[i].state != .idle {
                switch event.tool {
                case .edit: sessions[i].report.edits += 1
                case .command: sessions[i].report.commands += 1
                default: break
                }
            }

        case .agentNeedsUser:
            defer {
                if sessions[i].state == .waiting, let tool = event.tool {
                    sessions[i].report.request = AgentRequest(tool: tool, subject: storePromptSnippets ? event.message : nil)
                }
            }
            switch sessions[i].state {
            case .waiting:
                break
            case .working:
                enterWaiting(at: i, now: now)
                transitions.append(.needsUser(key))
            case .idle:
                guard !isIdlePrompt else { break }
                if let start = staleRuns.removeValue(forKey: key) {
                    startRun(at: i, now: start, observed: false)
                } else {
                    startRun(at: i, now: now, observed: false)
                }
                enterWaiting(at: i, now: now)
                transitions.append(.needsUser(key))
            }

        case .agentFinished where event.detail == HookPayloadParser.backgroundDetail:
            // Paused for background work, not done: still working (SPEC §2.6).
            continueWorking(at: i, key: key, now: now, transitions: &transitions)

        case .agentFinished:
            let ending = Self.ending(for: event.detail)
            if sessions[i].state != .idle || staleRuns[key] != nil {
                switch ending {
                case .finished: sessions[i].report.message = storePromptSnippets ? event.message : nil
                case .failed: sessions[i].report.failure = event.reason
                case .cancelled: break
                }
            }
            if sessions[i].state != .idle {
                transitions.append(endRun(at: i, ending: ending, now: now))
            } else if let start = staleRuns.removeValue(forKey: key) {
                // Idled by the interrupt fallback: still a finished run for the resume card and
                // wind-down, but its length is not trusted for the estimator.
                startRun(at: i, now: start, observed: false)
                transitions.append(endRun(at: i, ending: ending, now: now))
            }

        case .sessionEnded:
            sessions.remove(at: i)
            runNotes[key] = nil
            staleRuns[key] = nil
            transitions.append(.sessionEnded(key))

        case .commandStarted, .commandFinished, .test:
            break
        }
        return TrackerUpdate(transitions: transitions, opportunity: opportunity)
    }

    // MARK: Expiry

    public mutating func expire(now: Date) -> TrackerUpdate {
        var transitions: [SessionTransition] = []

        for i in sessions.indices where sessions[i].state == .working {
            let limit = sessions[i].source.sendsHeartbeat ? Timing.staleHeartbeatSource : Timing.staleOtherSource
            guard now.timeIntervalSince(sessions[i].lastEventAt) >= limit else { continue }
            let key = sessions[i].key
            let start = sessions[i].runStartedAt
            transitions.append(endRun(at: i, ending: .cancelled, now: now))
            staleRuns[key] = start
        }

        let expired = sessions.filter { now.timeIntervalSince($0.lastEventAt) >= Timing.sessionExpiry }
        for session in expired.sorted(by: { $0.key < $1.key }) {
            sessions.removeAll { $0.key == session.key }
            runNotes[session.key] = nil
            staleRuns[session.key] = nil
            transitions.append(.sessionEnded(session.key))
        }

        let oldCommands = commands.filter { $0.elapsed(at: now) >= Timing.commandExpiry }
        for command in oldCommands {
            commands.removeAll { $0.id == command.id }
            transitions.append(.commandFinished(command, nil))
        }
        return transitions.isEmpty ? .none : TrackerUpdate(transitions: transitions)
    }

    /// Expected run length for `source` (median of the last 20 runs, default 90 s).
    public func expectedRunLength(for source: AgentSource) -> TimeInterval {
        estimator.expectedRunLength(for: source)
    }

    /// Sessions sorted most urgent first (waiting > working > idle), then most recent event first.
    public var sessionsByUrgency: [AgentSession] {
        sessions.sorted {
            ($0.state.urgency, $0.lastEventAt) > ($1.state.urgency, $1.lastEventAt)
        }
    }

    // MARK: Runs

    /// The session is (still) working: `waiting` → `working`; an idle session revives a run the
    /// interrupt fallback idled, or starts one when this is the first sight of it (mid-run).
    private mutating func continueWorking(at i: Int, key: SessionKey, now: Date, transitions: inout [SessionTransition]) {
        switch sessions[i].state {
        case .waiting:
            leaveWaiting(at: i, now: now)
            sessions[i].state = .working
            transitions.append(.resumedWorking(key))
        case .idle:
            if let start = staleRuns.removeValue(forKey: key) {
                // The interrupt fallback was wrong: a long tool call just finished.
                startRun(at: i, now: start, observed: false)
                transitions.append(.resumedWorking(key))
            } else if transitions.contains(.sessionStarted(key)) {
                // First sight of this session, mid-run.
                startRun(at: i, now: now, observed: false)
                transitions.append(.resumedWorking(key))
            }
        case .working:
            break
        }
    }

    private mutating func startRun(at i: Int, now: Date, observed: Bool) {
        sessions[i].state = .working
        sessions[i].runStartedAt = now
        sessions[i].waitingSince = nil
        runNotes[sessions[i].key] = RunNotes(startUnobserved: !observed)
    }

    private mutating func enterWaiting(at i: Int, now: Date) {
        sessions[i].state = .waiting
        sessions[i].waitingSince = now
    }

    private mutating func leaveWaiting(at i: Int, now: Date) {
        sessions[i].report.request = nil
        if let since = sessions[i].waitingSince {
            runNotes[sessions[i].key, default: RunNotes()].waited += max(0, now.timeIntervalSince(since))
        }
        sessions[i].waitingSince = nil
    }

    /// Ends the current run of `sessions[i]`, recording `.finished` runs whose start was seen.
    private mutating func endRun(at i: Int, ending: RunEnding, now: Date) -> SessionTransition {
        let key = sessions[i].key
        if sessions[i].state == .waiting { leaveWaiting(at: i, now: now) }
        let notes = runNotes.removeValue(forKey: key) ?? RunNotes()
        let wall = sessions[i].runElapsed(at: now) ?? 0
        let final: RunEnding
        if case .finished = ending {
            final = .finished(duration: wall)
            if !notes.startUnobserved, sessions[i].runStartedAt != nil {
                estimator.record(wall - notes.waited, for: key.source)
            }
        } else {
            final = ending
        }
        sessions[i].state = .idle
        sessions[i].runStartedAt = nil
        sessions[i].waitingSince = nil
        sessions[i].lastRunEnding = final
        sessions[i].lastRunEndedAt = now
        return .runEnded(key, final)
    }

    // MARK: Commands

    private mutating func applyCommand(_ event: AgentEvent, now: Date) -> TrackerUpdate {
        guard let pid = event.sessionID, !pid.isEmpty else { return .droppedEvent }
        let existing = commands.first { $0.shellPID == pid }
        switch event.kind {
        case .commandStarted:
            guard let name = event.title.map(Self.commandName), !name.isEmpty, !CommandDenylist.contains(name) else {
                // An interactive program replaces whatever this shell ran before.
                if let existing {
                    commands.removeAll { $0.shellPID == pid }
                    return TrackerUpdate(transitions: [.commandFinished(existing, nil)])
                }
                return .droppedEvent
            }
            var transitions: [SessionTransition] = []
            if let existing {
                commands.removeAll { $0.shellPID == pid }
                transitions.append(.commandFinished(existing, nil))
            }
            let command = RunningCommand(shellPID: pid, command: name, cwd: event.cwd, startedAt: now)
            commands.append(command)
            transitions.append(.commandStarted(command))
            return TrackerUpdate(transitions: transitions)
        case .commandFinished:
            guard let existing else { return .droppedEvent }
            commands.removeAll { $0.shellPID == pid }
            let duration = event.durationMS.map { TimeInterval(max(0, $0)) / 1000 } ?? existing.elapsed(at: now)
            return TrackerUpdate(transitions: [.commandFinished(existing, CommandResult(exitCode: event.exitCode, duration: duration))])
        default:
            return .droppedEvent
        }
    }

    // MARK: Helpers

    static let idlePrompt = "idle_prompt"

    /// A Cursor event relayed through Claude Code's hooks while the native Cursor hooks are
    /// installed would be counted twice (SPEC §2.6, §5.4).
    func isRelayedDuplicate(_ event: AgentEvent) -> Bool {
        nativeCursorInstalled && event.source == .cursor && event.via == AgentEvent.viaClaudeCodeHooks
    }

    /// The event's session id; tools that send none share one session per folder (or per source).
    static func sessionID(for event: AgentEvent) -> String {
        if let id = event.sessionID, !id.isEmpty { return id }
        if let cwd = event.cwd, !cwd.isEmpty { return cwd }
        return "default"
    }

    /// `.cancelled` for `aborted` / `interrupted`, `.failed` for errors, else `.finished`.
    static func ending(for detail: String?) -> RunEnding {
        switch detail?.lowercased() {
        case "aborted", "interrupted", "cancelled", "canceled": return .cancelled
        case "error", "failed", "failure": return .failed
        default: return .finished(duration: 0)
        }
    }

    /// The first word of a command, without its path ("swift" for "/usr/bin/swift test").
    static func commandName(_ title: String) -> String {
        let first = title.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return (first as NSString).lastPathComponent
    }

    static func cleanTitle(_ title: String) -> String? {
        let line = TextFormat.firstLine(title)
        return line.isEmpty ? nil : TextFormat.truncated(line, limit: 80)
    }
}

/// Median of each source's last 20 recorded runs (SPEC §2.6). Stored in `sessions.json` as
/// `{"runs": {"claude-code": [41.5, 300, …]}}`. Decoding is tolerant: unknown keys, non-finite or
/// non-positive values and over-long lists are cleaned up rather than failing the file.
public struct RunLengthEstimator: Codable, Equatable, Sendable {
    /// Recorded run lengths per source, oldest first, at most `Timing.runHistoryLength` each.
    public private(set) var runs: [AgentSource: [TimeInterval]]

    public init(runs: [AgentSource: [TimeInterval]] = [:]) {
        self.runs = runs.compactMapValues { Self.cleaned($0) }
    }

    /// Records a finished run. Non-finite or non-positive lengths are ignored.
    public mutating func record(_ duration: TimeInterval, for source: AgentSource) {
        guard duration.isFinite, duration > 0 else { return }
        var list = runs[source] ?? []
        list.append(duration)
        if list.count > Timing.runHistoryLength { list.removeFirst(list.count - Timing.runHistoryLength) }
        runs[source] = list
    }

    /// Median of the recorded runs, or `Timing.defaultExpectedRun` with none.
    public func expectedRunLength(for source: AgentSource) -> TimeInterval {
        guard let list = runs[source], !list.isEmpty else { return Timing.defaultExpectedRun }
        let sorted = list.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Every source's expected run length (for `EngineSnapshot.expectedRunLengths`).
    public var expectedRunLengths: [AgentSource: TimeInterval] {
        Dictionary(uniqueKeysWithValues: runs.keys.map { ($0, expectedRunLength(for: $0)) })
    }

    /// The persisted file for `paths`.
    public static func file(_ paths: BreakpointPaths) -> JSONFile<RunLengthEstimator> {
        JSONFile(url: paths.sessionsFile)
    }

    /// The saved estimator, or an empty one when the file is missing or unreadable.
    public static func load(_ paths: BreakpointPaths) -> RunLengthEstimator {
        (try? file(paths).read()) ?? RunLengthEstimator()
    }

    enum CodingKeys: String, CodingKey { case runs }

    /// A number, or `nil` for anything else (one bad value does not lose the file).
    private struct LossyNumber: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Double.self)
        }
    }

    /// A list of numbers, or empty for anything else (one bad source does not lose the others).
    private struct LossyList: Decodable {
        let values: [Double]
        init(from decoder: Decoder) throws {
            values = ((try? decoder.singleValueContainer().decode([LossyNumber].self)) ?? []).compactMap(\.value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([String: LossyList].self, forKey: .runs)) ?? [:]
        var runs: [AgentSource: [TimeInterval]] = [:]
        for (source, list) in raw {
            if let cleaned = Self.cleaned(list.values) { runs[AgentSource(source)] = cleaned }
        }
        self.runs = runs
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let raw = Dictionary(uniqueKeysWithValues: runs.map { ($0.key.rawValue, $0.value) })
        try c.encode(raw, forKey: .runs)
    }

    /// Valid values, newest 20; `nil` when nothing valid is left.
    private static func cleaned(_ values: [TimeInterval]) -> [TimeInterval]? {
        let valid = values.filter { $0.isFinite && $0 > 0 }.suffix(Timing.runHistoryLength)
        return valid.isEmpty ? nil : Array(valid)
    }
}
