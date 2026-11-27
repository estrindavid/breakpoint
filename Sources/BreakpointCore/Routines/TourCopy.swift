import Foundation

// The tour's coach lines (SPEC §3.12). Same rules as every other line: second person, plain verbs,
// no "should", no "!", no health claims, never "look away". One idea per caption; each says what
// the surface is and what to press.

public enum TourCopy {
    /// The coach line for a step (`popover`: the part being named).
    /// `hotkeys`: the nudge hotkeys are on, so the sample nudge's buttons carry their keycaps.
    public static func coach(_ step: TourStep, part: TourPopoverPart = .status, agent: String = "Claude",
                             hotkeys: Bool = true) -> TourCoach {
        switch step {
        case .offer:
            return TourCoach(title: "Take the one-minute tour?",
                             text: "Rehearse one break with sample data, right where real ones appear. Nothing is recorded.",
                             primary: "Take the tour", secondary: "Not now")
        case .mark:
            return TourCoach(title: "This is Breakpoint",
                             text: "It lives in your menu bar. The mark changes with your agent and your breaks.",
                             primary: "Next")
        case .nudge:
            return TourCoach(title: "How a break is offered",
                             text: hotkeys ? nudgeWithKeys : nudgeWithoutKeys)
        case .declined:
            return TourCoach(title: "That was Not now",
                             text: "Nothing starts and nothing is counted. Breakpoint offers again at a later pause.",
                             primary: "Offer it again")
        case .breakScreen:
            return TourCoach(text: breakControls)
        case .resumeCard:
            return TourCoach(title: "Back from a break",
                             text: "When you come back, one line says what your agent did.",
                             primary: "Next")
        case .popover:
            return TourCoach(text: popoverPart(part), primary: "Next")
        case .farewell:
            return TourCoach(title: "That's the whole cycle",
                             text: "Settings and this tour are under the gear in the popover. Your first real break comes while \(agent) is working, once one is due.",
                             primary: "Done")
        }
    }

    /// The sample nudge's coach line. Its buttons carry their keycaps (faint until the pointer
    /// arrives), so the line names them instead of repeating them.
    public static let nudgeWithKeys = "Press Start or Not now, or the keys shown on each button. It never takes your keyboard."
    public static let nudgeWithoutKeys = "Press Start or Not now. It never takes your keyboard."

    /// What each part of the popover is, in one line.
    public static func popoverPart(_ part: TourPopoverPart) -> String {
        switch part {
        case .status:
            return "Your next break. When one is due but waiting, a line here says why not now."
        case .actions:
            return "Take a break now, or Pause for 30 min, an hour or until tomorrow."
        case .totals:
            return "Your own totals. Every break you start counts, however short."
        case .gear:
            return "Settings live here, with a shortcut to open this popover from anywhere."
        }
    }

    // MARK: The sample break (on the break screen itself)

    /// Under the agent chip while the sample agent works.
    public static let breakChipWorking = "Your agent, live. It turns mint when the run ends."
    /// Under the agent chip once the sample agent is done.
    public static let breakChipDone = "Done. No rush: finish the break, then go back."
    /// Beside the controls.
    public static let breakControls = "Skip, or esc twice, ends it early. Nothing is forced."
    /// The footer that labels the whole screen.
    public static let rehearsalLabel = "Rehearsal with sample data. Nothing is recorded."

    // MARK: The sample nudge

    /// The sample nudge's hover line (where a real one says why now).
    public static let nudgeWhyNow = "A rehearsal: nothing is recorded"

    // MARK: The mark's states (the legend under the mark)

    public static let legendWorking = "Working"
    public static let legendNeedsYou = "Needs you"
    public static let legendDue = "Break due"
    public static let legendOnBreak = "On a break"
    public static let legendPaused = "Paused"

    // MARK: Sample data

    /// The sample agent's last message on the sample resume card.
    public static let sampleAgentMessage = "Added the sign-in form and its tests"

    /// Progress for VoiceOver: "Tour, step 2 of 6".
    public static func progress(_ index: Int, of count: Int) -> String { "Tour, step \(index) of \(count)" }

    /// Every caption, for the copy tests.
    public static var allLines: [String] {
        var lines: [String] = []
        for step in TourStep.allCases {
            let coach = coach(step)
            lines.append(contentsOf: [coach.title, coach.text, coach.primary, coach.secondary].compactMap { $0 })
        }
        lines += [nudgeWithKeys, nudgeWithoutKeys]
        lines += TourPopoverPart.allCases.map(popoverPart)
        lines += [breakChipWorking, breakChipDone, breakControls, rehearsalLabel, nudgeWhyNow, sampleAgentMessage,
                  legendWorking, legendNeedsYou, legendDue, legendOnBreak, legendPaused]
        return lines
    }
}

/// The first-use hints on real surfaces (SPEC §3.12): one line each, in the coach lines' voice.
public enum HintCopy {
    /// The first ordinary nudge: what happens if you do nothing.
    public static let nudge = "Start, or carry on: it asks again later."
    /// The first eye rest that starts by itself.
    public static let autoStart = "It starts by itself. Press any key to keep working."

    public static func nudge(_ lesson: HintLesson) -> String { lesson == .autoStart ? autoStart : nudge }

    /// The first real break, under the agent chip (the screen already shows how to skip): what the
    /// chip is for. `agent` nil: several agents are working.
    public static func breakChip(agent: String?) -> String {
        guard let agent else { return "The chip above follows your agents and turns amber if one needs you." }
        return "The chip above follows \(agent) and turns amber if \(agent) needs you."
    }
    /// The first real break when no agent is running (the chip shows the time).
    public static let breakNoAgent = "Skip whenever you like: nothing is forced."

    /// The first resume card that goes by itself.
    public static let resumeCard = "It sums up your time away, then goes by itself."
    /// The first resume card that waits because an agent needs you.
    public static func resumeNeedsYou(dismissKey: String?) -> String {
        dismissKey.map { "It stays until you press \($0) or click it." } ?? "It stays until you click it."
    }

    /// The first time the popover opens.
    public static let popover = "Option-click the mark to see why no break yet."
    /// The first call pause, under "Breaks paused: microphone is on".
    public static let callPause = "Breaks come back by themselves after the call."

    /// Every hint, for the copy tests.
    public static var allLines: [String] {
        [nudge, autoStart, breakChip(agent: "Claude"), breakChip(agent: nil), breakNoAgent, resumeCard,
         resumeNeedsYou(dismissKey: "⌃⌥⌘."), resumeNeedsYou(dismissKey: nil), popover, callPause]
    }
}
