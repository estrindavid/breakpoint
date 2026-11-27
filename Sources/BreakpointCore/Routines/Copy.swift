import Foundation

// Every sentence Breakpoint says about breaks, pauses, agents and its
// own decisions (SPEC §3.11). Screens call these instead of composing copy. UI chrome (button
// labels, settings descriptions) stays in the views that show it.

/// Copy for pop-ups, the overlay chip, the popover and the menu bar.
public enum Copy {
    // MARK: Nudge (SPEC §3.1)

    /// "20-sec eye rest?", "2-min stretch?", "6-min walk?", "1-min breather?" — always kind and
    /// length, question form, ≤ 7 words.
    public static func nudgeTitle(kind: BreakKind, length: TimeInterval) -> String {
        "\(DurationFormat.lengthAdjective(length)) \(kind.noun)?"
    }

    /// Auto-start countdown title: "20-sec eye rest in 10".
    public static func autoStartTitle(kind: BreakKind, length: TimeInterval, remaining: TimeInterval) -> String {
        "\(DurationFormat.lengthAdjective(length)) \(kind.noun) in \(Int(max(0, remaining).rounded(.up)))"
    }

    /// Countdown chip text: "Eye rest in 5".
    public static func countdownChip(kind: BreakKind, remaining: TimeInterval) -> String {
        "\(kind.menuTitle) in \(Int(max(0, remaining).rounded(.up)))"
    }

    /// Nudge subtitle (context): "Claude is working", "swift is running", and at a typing pause the
    /// timer that made the break due, in the popover's words: "52 min at the screen" (eye rest) or
    /// "68 min since you moved" (stretch, walk, breather).
    public static func nudgeSubtitle(for offer: BreakOffer) -> String {
        switch offer.opportunity.kind {
        case .agentStarted:
            return "\(offer.opportunity.source?.displayName ?? "Your agent") is working"
        case .longCommand:
            return "\(offer.opportunity.commandName ?? "A command") is running"
        case .typingPause, .manual:
            return offer.kind == .eyes
                ? DurationFormat.atTheScreen(offer.timerValue)
                : DurationFormat.sinceYouMoved(offer.timerValue)
        }
    }

    /// Why-now line shown on hover, in place of the subtitle: "18 min overdue · Claude usually
    /// takes 4 min", or "Due now". The title above it already names the break, so the line names
    /// only the facts; short enough to swap in on one line, so the card keeps its size on hover.
    public static func whyNow(for offer: BreakOffer) -> String {
        var parts: [String] = []
        if offer.overdueBy >= 60 {
            parts.append("\(DurationFormat.minutes(offer.overdueBy)) overdue")
        } else {
            parts.append("Due now")
        }
        if offer.opportunity.kind == .agentStarted, let run = offer.expectedRunLength,
           let name = offer.opportunity.source?.displayName {
            let usual = DurationFormat.minutes(max(60, run), rounding: .nearest)
            parts.append("\(name) usually takes \(usual)")
        }
        return parts.joined(separator: " · ")
    }

    /// VoiceOver announcement when a nudge appears (SPEC §4.8).
    public static func nudgeAnnouncement(kind: BreakKind, length: TimeInterval, hotkeysOn: Bool) -> String {
        let adjective = length < 60
            ? "\(Int(max(0, length).rounded()))-second"
            : "\(DurationFormat.wholeMinutes(length, rounding: .nearest))-minute"
        let offer = "Break offer: \(adjective) \(kind.noun)."
        return hotkeysOn ? offer + " Control-Option-Command-B to start." : offer
    }

    // MARK: Pauses (SPEC §2.4)

    /// "Paused: microphone is on", "Paused until 15:30", "Paused until tomorrow",
    /// "Paused: wrapped up for tonight".
    public static func pauseSentence(_ reason: PauseReason, now: Date, locale: Locale = .current,
                                     timeZone: TimeZone = .current) -> String {
        switch reason {
        case .call(let signals):
            return "Paused: \(signals.phrase ?? "call in progress")"
        case .manual(let until):
            if until.timeIntervalSince(now) > 12 * 3600 { return "Paused until tomorrow" }
            return "Paused until \(TimeFormat.timeOfDay(until, locale: locale, timeZone: timeZone))"
        case .windDownWrappedUp:
            return "Paused: wrapped up for tonight"
        }
    }

    /// Toast when a call pause withdrew a nudge or began while a break was due:
    /// "Breaks paused: microphone is on".
    public static func callPauseToast(_ signals: CallSignals) -> String {
        "Breaks paused: \(signals.phrase ?? "call in progress")"
    }

    // MARK: Decisions (SPEC §2.3, §3.5, §3.8)

    /// Away note / decision sentence: "Counted your 6 min away as a break" ("40 s" under a minute).
    public static func creditedAway(duration: TimeInterval) -> String {
        "Counted your \(awayLength(duration)) away as a break"
    }

    /// Decision sentence when timers reset silently: "Reset timers after 4 min away".
    public static func timersReset(duration: TimeInterval) -> String {
        "Reset timers after \(awayLength(duration)) away"
    }

    /// Popover decision line (without "· Undo"): "Counted 6 min away as a break" /
    /// "Reset timers after 4 min away".
    public static func decisionLine(_ decision: AutoDecision) -> String {
        switch decision.kind {
        case .creditedAway(_, let duration): return "Counted \(awayLength(duration)) away as a break"
        case .timersReset(let duration): return timersReset(duration: duration)
        }
    }

    /// An away time: "40 s" under a minute (a short lock), else "6 min", "1 h 5 min".
    static func awayLength(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(max(0, seconds).rounded(.down))) s" : DurationFormat.minutes(seconds)
    }

    public static let timersRestored = "Timers restored"

    // MARK: Agents (SPEC §3.3 chip, §3.5 resume card)

    /// "Claude is still working · 1:42".
    public static func chipWorking(agent: String, elapsed: TimeInterval) -> String {
        "\(agent) is still working · \(DurationFormat.clock(elapsed, rounding: .down))"
    }
    /// "Claude is done. No rush."
    public static func chipDone(agent: String) -> String { "\(agent) is done. No rush." }
    /// "Claude needs you".
    public static func needsYou(agent: String) -> String { "\(agent) needs you" }

    /// The `walk` instruction once an agent needs you (the walk copy promised a chime; it has
    /// sounded, so the line says what to do now).
    public static func walkNeedsYouInstruction(agent: String) -> String { "\(agent) needs you. Head back when you're ready." }
    /// "2 agents working".
    public static func agentsWorking(_ count: Int) -> String { "\(count) agents working" }

    /// Resume card title for one session: "Claude finished · ran 6 min" / "Claude stopped with an
    /// error"; `nil` for cancelled runs (no card).
    public static func resumeTitle(agent: String, ending: RunEnding) -> String? {
        switch ending {
        case .finished(let duration): return "\(agent) finished · ran \(DurationFormat.minutes(duration, rounding: .nearest))"
        case .failed: return "\(agent) stopped with an error"
        case .cancelled: return nil
        }
    }

    /// "2 agents finished".
    public static func agentsFinished(_ count: Int) -> String { "\(count) agents finished" }

    // MARK: Status (SPEC §3.7, §3.8)

    /// Popover caption over the big number: "Eye rest in" / "Stretch in" / "Stretch due".
    public static func statusCaption(kind: BreakKind, isDue: Bool) -> String {
        let name = kind == .eyes ? "Eye rest" : "Stretch"
        return isDue ? "\(name) due" : "\(name) in"
    }

    /// Popover detail line in the first minute after launch, before anything reset still time:
    /// "You moved less than a minute ago" would be a guess (SPEC §3.8).
    public static let countingFromNow = "Counting from now"

    /// Menu-bar text for "time to next break": "6m" or "due".
    public static func menuBarCountdown(_ remaining: TimeInterval) -> String {
        remaining <= 0 ? "due" : DurationFormat.compact(remaining, rounding: .up)
    }

    /// Menu-bar text for "agent state": "Claude 3m".
    public static func menuBarAgent(_ agent: String, elapsed: TimeInterval) -> String {
        "\(agent) \(DurationFormat.compact(elapsed, rounding: .down))"
    }

    // MARK: Wind-down (SPEC §2.8, §3.6)

    /// "It's 23:20."
    public static func windDownTitle(now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        "It's \(TimeFormat.timeOfDay(now, locale: locale, timeZone: timeZone))."
    }

    /// "You planned to stop at 23:00."
    public static func windDownBody(stopTime: TimeOfDay, on date: Date, locale: Locale = .current,
                                    timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let stop = stopTime.date(on: date, calendar: calendar)
        return "You planned to stop at \(TimeFormat.timeOfDay(stop, locale: locale, timeZone: timeZone))."
    }

    /// "Hold 3 s".
    public static func windDownHold(_ seconds: TimeInterval) -> String { "Hold \(Int(seconds)) s" }

    /// One "Where you left off" line: "breakpoint — fix the login redirect".
    public static func wrapUpLine(folder: String?, snippet: String?) -> String {
        switch (folder, snippet) {
        case let (folder?, snippet?): return "\(folder) — \(snippet)"
        case let (folder?, nil): return folder
        case let (nil, snippet?): return snippet
        case (nil, nil): return "Untitled session"
        }
    }

    // MARK: Accessibility (SPEC §3.3)

    public static func breakStartedAnnouncement(title: String, length: TimeInterval) -> String {
        "Break started: \(title), \(DurationFormat.spokenLength(length))"
    }
    public static let breakOverAnnouncement = "Break over"
}
