import Foundation

// Copy for "Why not now?" (SPEC §3.7, §3.8) and the few lines in debugger voice (SPEC §3.11).
// Same rules as every other line: second person, plain verbs, no "should", no "!", no health
// claims, never "look away".

extension Copy {
    // MARK: Why not now?

    /// One line naming what Breakpoint is waiting for: "Nothing due: eye rest in 12 min",
    /// "Holding the nudge: you are typing", "Waiting for a pause: Claude is idle and you are typing".
    public static func whyNotNow(_ reason: WaitReason, now: Date, locale: Locale = .current,
                                 timeZone: TimeZone = .current) -> String {
        func time(_ date: Date) -> String { TimeFormat.timeOfDay(date, locale: locale, timeZone: timeZone) }
        switch reason {
        case .onBreak:
            return "On a break now"
        case .offering:
            return "Offering a break now"
        case .paused(let pause):
            return pauseSentence(pause, now: now, locale: locale, timeZone: timeZone)
        case .away:
            return "Waiting for you to come back"
        case .nothingDue(let next, let remaining):
            return "Nothing due: \(next.noun) in \(DurationFormat.minutes(remaining, rounding: .up))"
        case .easingBackIn(let until):
            return "Easing back in after a pause: next nudge from \(time(until))"
        case .spacingNudges(let until):
            return "Spacing out nudges: next one from \(time(until))"
        case .spacingKind(let kind, let until):
            return "Spacing out \(pluralNoun(kind)): next one from \(time(until))"
        case .afterBreather(let until):
            return "You took a breather: next stretch from \(time(until))"
        case .holding(.typing):
            return "Holding the nudge: you are typing"
        case .holding(.pointer):
            return "Holding the nudge: you are clicking or dragging"
        case .holding(.microphone):
            return "Holding the nudge: a microphone is on"
        case .waiting(let waiting):
            return waitingLine(waiting)
        }
    }

    static func waitingLine(_ waiting: WaitReason.Waiting) -> String {
        var facts: [String] = []
        if let agent = waiting.agent { facts.append(agentFact(agent)) }
        let lead: String
        switch waiting.next {
        case .typingPause where waiting.typing:
            lead = "Waiting for a pause"
            facts.append("you are typing")
        case .typingPause:
            // This pause already had its chance; the next pause after a key press counts.
            lead = "Waiting for your next pause in typing"
        case .agentRun, .agentRunOnly:
            lead = waiting.agent?.state == .working ? "Waiting for your next prompt" : "Waiting for an agent run"
        }
        if let quiet = waiting.quiet { facts.append(quiet.phrase) }
        var line = facts.isEmpty ? lead : "\(lead): \(facts.joined(separator: " and "))"
        if waiting.next == .agentRunOnly { line += " (only during agent runs)" }
        return line
    }

    /// "Claude is idle", "Codex is working", "2 agents are working", "Claude needs you".
    static func agentFact(_ agent: WaitReason.AgentFact) -> String {
        switch agent.state {
        case .waiting:
            return agent.count > 1 ? "\(agent.count) agents need you" : needsYou(agent: agent.name)
        case .working:
            return agent.count > 1 ? "\(agent.count) agents are working" : "\(agent.name) is working"
        case .idle:
            return agent.count > 1 ? "\(agent.count) agents are idle" : "\(agent.name) is idle"
        }
    }

    static func pluralNoun(_ kind: BreakKind) -> String {
        switch kind {
        case .eyes: return "eye rests"
        case .move: return "stretches"
        case .walk: return "walks"
        case .breathe: return "breathers"
        }
    }

    // MARK: Debugger voice (rare, used straight)

    /// The popover's detail line while wrapped up for the night, one per night (a night runs 05:00
    /// to 05:00). One of five reads in debugger voice.
    public static let wrappedUpDetails = [
        "Breaks come back tomorrow morning.",
        "Done for today. Breaks come back in the morning.",
        "Nothing more tonight. Breaks come back tomorrow.",
        "Breaks start again in the morning.",
        "Paused at a breakpoint until morning.",
    ]

    /// The wrapped-up detail line for the night that contains `now`.
    public static func wrappedUpDetail(now: Date, calendar: Calendar = .current) -> String {
        let night = BreakpointDay.start(of: now, calendar: calendar)
        let index = calendar.dateComponents([.day], from: Date(timeIntervalSinceReferenceDate: 0), to: night).day ?? 0
        return wrappedUpDetails[((index % wrappedUpDetails.count) + wrappedUpDetails.count) % wrappedUpDetails.count]
    }

    /// About, under the version.
    public static let aboutTagline = "Paused at a breakpoint since 2026."

    /// Every line in debugger voice, so tests can keep them rare: break titles from
    /// `BreakCopyLibrary`, the wrapped-up line and About.
    public static let debuggerVoice: Set<String> = [
        "Watch something far away",
        "Step through a few moves",
        "Step out for a while",
        "Paused at a breakpoint until morning.",
        aboutTagline,
    ]
}
