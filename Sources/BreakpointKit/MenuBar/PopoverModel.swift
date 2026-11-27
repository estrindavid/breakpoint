import Foundation
import BreakpointCore

// What the popover says, derived from `AppState`
// in one place so the view stays declarative and every state reads deliberately.

@MainActor
enum PopoverModel {
    /// The status block: caption over one big value (number + unit), and one detail line.
    struct Status: Equatable {
        var caption: String
        /// The big value's leading small word ("until"), if any.
        var prefix: String?
        /// The big value ("6", "1:12", "15:30", "Now"); `nil` shows no number (call pause).
        var number: String?
        /// The unit after the number ("min"), small.
        var unit: String?
        /// Drives the digit roll.
        var rollValue: Double
        var detail: String
        /// Progress toward the break the caption names (or through the current break), 0…1.
        var ringProgress: Double
        var ringDimmed: Bool
        /// The ring's glyph: the kind the caption names, so a stretch figure never sits beside
        /// "Eye rest in".
        var ringSymbol: String
    }

    static func status(_ state: AppState) -> Status {
        let status = state.status
        let now = state.now
        let still = status.nextBreakProgress
        let symbol = status.nextBreakKind.symbolName
        // Under a minute: since a break or time away, or (before either) only since launch, when
        // Breakpoint cannot know when the user last moved. Later, still time is a lower bound.
        let sinceMoved = status.timers.stillTime < 60
            ? (status.stillCountedSinceLaunch ? Copy.countingFromNow : "You moved less than a minute ago")
            : DurationFormat.sinceYouMoved(status.timers.stillTime)

        if let active = state.activeBreak {
            return Status(caption: "\(active.kind.menuTitle) in progress", prefix: nil,
                          number: DurationFormat.clock(active.remaining), unit: nil,
                          rollValue: active.remaining, detail: active.kind == .walk
                              ? "Take your time. Breakpoint calls you back."
                              : "\(capitalized(DurationFormat.spokenLength(active.plannedLength))) in all",
                          ringProgress: active.progress, ringDimmed: false, ringSymbol: active.kind.symbolName)
        }

        if let reason = status.pause.primaryReason {
            switch reason {
            case .call:
                return Status(caption: status.pauseSentence ?? Copy.pauseSentence(reason, now: now), prefix: nil,
                              number: nil, unit: nil, rollValue: 0,
                              detail: "Breaks come back a minute after the call ends.",
                              ringProgress: still, ringDimmed: true, ringSymbol: symbol)
            case .manual(let until):
                let remaining = until.timeIntervalSince(now)
                let overnight = remaining > 12 * 3600
                return Status(caption: "Paused", prefix: "until", number: TimeFormat.timeOfDay(until), unit: nil,
                              rollValue: until.timeIntervalSinceReferenceDate,
                              detail: overnight ? "Breaks come back tomorrow morning."
                                  : "\(DurationFormat.minutes(remaining, rounding: .up)) left",
                              ringProgress: still, ringDimmed: true, ringSymbol: symbol)
            case .windDownWrappedUp(let until):
                return Status(caption: "Wrapped up for tonight", prefix: "until", number: TimeFormat.timeOfDay(until),
                              unit: nil, rollValue: until.timeIntervalSinceReferenceDate,
                              detail: Copy.wrappedUpDetail(now: now), ringProgress: still, ringDimmed: true, ringSymbol: symbol)
            }
        }

        let caption = Copy.statusCaption(kind: status.nextBreakKind, isDue: status.isDue)
        if status.isDue {
            return Status(caption: caption, prefix: nil, number: "Now", unit: nil, rollValue: 0,
                          detail: windDownLine(state) ?? sinceMoved, ringProgress: still, ringDimmed: false, ringSymbol: symbol)
        }
        let text = DurationFormat.minutes(status.nextBreakIn, rounding: .up)
        let (number, unit) = splitUnit(text)
        return Status(caption: caption, prefix: nil, number: number, unit: unit,
                      rollValue: Double(DurationFormat.wholeMinutes(status.nextBreakIn, rounding: .up)),
                      detail: windDownLine(state) ?? sinceMoved, ringProgress: still, ringDimmed: false, ringSymbol: symbol)
    }

    private static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    /// "Why not now?" under the status block (§3.8): only while a break is due and is not on offer
    /// or paused, the one moment the status block cannot answer it ("Stretch due" but no nudge).
    static func whyNotNow(_ state: AppState) -> String? {
        guard state.activeBreak == nil, let reason = state.status.whyNotNow, reason.explainsADueBreak else { return nil }
        return Copy.whyNotNow(reason, now: state.now)
    }

    /// "You planned to stop at 23:00." once the wind-down stop time has passed today.
    static func windDownLine(_ state: AppState) -> String? {
        let settings = state.settings
        guard settings.windDownEnabled, settings.stopDays.contains(state.now) else { return nil }
        let stop = settings.stopTime.date(on: state.now)
        guard state.now >= stop, state.now.timeIntervalSince(stop) < 6 * 3600 else { return nil }
        return Copy.windDownBody(stopTime: settings.stopTime, on: state.now)
    }

    /// "1 h 5 min" → ("1 h 5", "min"); "6 min" → ("6", "min"); "1 h" → ("1", "h").
    static func splitUnit(_ text: String) -> (String, String?) {
        guard let space = text.lastIndex(of: " ") else { return (text, nil) }
        let unit = String(text[text.index(after: space)...])
        guard unit.allSatisfy(\.isLetter) else { return (text, nil) }
        return (String(text[..<space]), unit)
    }

    /// Menu label lengths: "20 sec", "2 min", "5 min", "1 min".
    static func lengthLabel(_ kind: BreakKind) -> String {
        let length = kind.defaultLength
        return length < 60 ? "\(Int(length)) sec" : "\(Int(length / 60)) min"
    }

    // MARK: Agents

    struct AgentRow: Identifiable, Equatable {
        var id: String
        var symbol: String
        var title: String
        var chip: String
        var tone: Theme.Tone
        var elapsed: String
        var accessibility: String
    }

    static func agentRows(_ state: AppState) -> [AgentRow] {
        let now = state.now
        var rows = state.sessions.map { session -> AgentRow in
            let folder = session.projectName ?? session.displayName
            let chip: String
            let tone: Theme.Tone
            let elapsed: String
            switch session.state {
            case .working:
                chip = "working"; tone = .agent
                elapsed = DurationFormat.clock(session.runElapsed(at: now) ?? 0, rounding: .down)
            case .waiting:
                chip = "needs you"; tone = .needsYou
                elapsed = DurationFormat.clock(now.timeIntervalSince(session.waitingSince ?? session.lastEventAt), rounding: .down)
            case .idle:
                chip = "idle"; tone = .neutral
                elapsed = ago(now.timeIntervalSince(session.lastRunEndedAt ?? session.lastEventAt))
            }
            return AgentRow(id: session.key.description, symbol: MenuBarGlyphs.sourceSymbol(session.source),
                            title: folder, chip: chip, tone: tone, elapsed: elapsed,
                            accessibility: "\(session.displayName) in \(folder), \(chip), \(elapsed)")
        }
        rows += state.commands.map { command in
            let folder = command.projectName ?? command.displayName
            let elapsed = DurationFormat.clock(command.elapsed(at: now), rounding: .down)
            return AgentRow(id: "cmd-\(command.shellPID)", symbol: MenuBarGlyphs.sourceSymbol(.shell), title: folder,
                            chip: "\(command.displayName) running", tone: .neutral, elapsed: elapsed,
                            accessibility: "\(command.displayName) running in \(folder), \(elapsed)")
        }
        return rows
    }

    /// How long ago an idle session last ran, coarse and in the popover's own units, so it never
    /// reads like the running stopwatch of a working row: "just now", "12 min ago", "9 h ago".
    static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(DurationFormat.minutes(seconds)) ago" }
        return "\(Int(seconds / 3600)) h ago"
    }

    /// No tool is installed: the agents section invites the user to connect one.
    static func showsConnectPrompt(_ state: AppState) -> Bool {
        state.sessions.isEmpty && state.commands.isEmpty && !state.integrations.contains { $0.status.isInstalled }
    }

    // MARK: Footer

    struct Footer: Equatable {
        var text: String
        var tone: Theme.Tone?
    }

    static func footer(_ state: AppState) -> Footer {
        let installed = state.integrations.filter { $0.status.isInstalled }
        guard !installed.isEmpty else { return Footer(text: "No tools connected yet", tone: nil) }
        let heard = installed.compactMap { row -> (String, Date)? in
            if case .connected(let date?) = row.status { return (row.displayName, date) }
            return nil
        }
        if let latest = heard.max(by: { $0.1 < $1.1 }) {
            let when = Self.ago(state.now.timeIntervalSince(latest.1))
            let names = heard.count == 1 ? latest.0 : "\(heard.count) tools"
            return Footer(text: "\(names) · last event \(when)", tone: .mint)
        }
        // The last event is information; a connected tool needs none to count.
        let names = installed.count == 1 ? installed[0].displayName : "\(installed.count) tools"
        return Footer(text: "\(names) connected", tone: .mint)
    }
}

