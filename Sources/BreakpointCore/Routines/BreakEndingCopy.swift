import Foundation

// The walk's rotating idea line and the closing line of a completed
// break (SPEC §3.4, §3.11). Same rules as all break copy: second person or plain statements, no
// "should", no "!", no medical claims, never "look away". Closing lines name the routine or the
// time, never praise and never a count.

extension BreakCopyLibrary {
    /// `walk`: a second line with something to do on the way (drawn from its own shuffle bag).
    public static let walkIdeas: [String] = [
        "Refill your water",
        "Take the stairs",
        "Step outside for a minute",
        "Walk a lap of the room",
        "Water a plant",
        "Open a window for some air",
    ]

    /// Rotation key of the walk ideas' shuffle bag in `rotation.json`.
    public static let walkIdeaBag = "walk.idea"

    /// Rotation key of each kind's closing-line shuffle bag in `rotation.json`.
    public static func closingBag(_ kind: BreakKind) -> String { "closing.\(kind.rawValue)" }

    /// Closing-line templates per kind. `{length}` is the time spent ("two minutes"), `{Length}`
    /// the same capitalised, `{routine}` the routine's short name ("Shoulders").
    public static func closingTemplates(_ kind: BreakKind) -> [String] {
        switch kind {
        case .eyes: return ["That's {length}.", "{Length}, done.", "Eye rest done."]
        case .move: return ["That's {length}.", "{routine} done.", "{Length}, done."]
        case .walk: return ["That's {length}.", "Walk done.", "{Length} on your feet."]
        case .breathe: return ["That's {length}.", "{Length}, done.", "Breathing done."]
        }
    }

    /// The short name a closing line uses for a routine ("Shoulders done.").
    public static let routineClosingNames: [String: String] = [
        "neck-and-shoulders": "Shoulders",
        "wrists-and-forearms": "Wrists",
        "upper-back": "Upper back",
        "chest-opener": "Chest opener",
        "hips-and-calves": "Hips and calves",
        "stand-and-reach": "Stand and reach",
        "seated-legs": "Legs",
        "band-raises": "Band raises",
        "band-pull-aparts": "Pull-aparts",
    ]

    /// The closing line for a completed break: template `rotation` (wrapping) of the kind, filled
    /// with the time spent (`elapsed`, rounded) and, for `move`, the routine's short name.
    public static func closingLine(kind: BreakKind, rotation: Int, elapsed: TimeInterval, routine: Routine?) -> String {
        let templates = closingTemplates(kind)
        let template = templates[((rotation % templates.count) + templates.count) % templates.count]
        let length = spokenLength(elapsed)
        let name = routine.map { routineClosingNames[$0.id] ?? $0.name } ?? "Stretch"
        return template
            .replacingOccurrences(of: "{length}", with: length)
            .replacingOccurrences(of: "{Length}", with: length.prefix(1).uppercased() + length.dropFirst())
            .replacingOccurrences(of: "{routine}", with: name)
    }

    /// A time spent, in words: "twenty seconds", "one minute", "two minutes", "15 minutes". Under
    /// 55 s it rounds to 10 s; from there, to the minute.
    public static func spokenLength(_ seconds: TimeInterval) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve"]
        if seconds < 55 {
            let tens = max(1, Int((seconds / 10).rounded()))
            let names = [1: "ten", 2: "twenty", 3: "thirty", 4: "forty", 5: "fifty"]
            return "\(names[tens] ?? "\(tens * 10)") seconds"
        }
        let minutes = max(1, Int((seconds / 60).rounded()))
        let number = minutes < words.count ? words[minutes] : "\(minutes)"
        return minutes == 1 ? "\(number) minute" : "\(number) minutes"
    }
}
