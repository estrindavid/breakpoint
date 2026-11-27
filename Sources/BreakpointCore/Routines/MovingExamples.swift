import Foundation

/// One everyday activity the popover's small line compares your moving to (SPEC §3.8): "That's
/// like walking the dog." It frames the total as something you did, not as a length of time.
public struct MovingExample: Equatable, Hashable, Sendable {
    /// Minutes of moving at which the example appears: the long end of the activity's usual
    /// length, so the comparison can only understate.
    public let minutes: Int
    /// The phrase after "That's like", lower case, without the full stop.
    public let activity: String
    /// The usual length assumed, for review (never shown).
    public let usually: String

    public init(_ minutes: Int, _ activity: String, usually: String) {
        self.minutes = minutes
        self.activity = activity
        self.usually = usually
    }

}

/// The ladder of examples, strictly increasing. Dense at the start (the first one after a couple
/// of stretches, a new one every day or two in the first weeks), then about weekly, then further
/// apart, so the line keeps changing for months. Everyday activities only, recognisable anywhere,
/// no distance, effort, calories or health; spellings that read the same in British and American
/// English ("a football match": "match" reads as the 90-minute game in both).
public enum MovingExamples {
    public static let all: [MovingExample] = [
        MovingExample(3, "walking to the end of the street", usually: "1–3 min"),
        MovingExample(4, "dancing to a whole song", usually: "a song is 3–4 min"),
        MovingExample(6, "a game of musical chairs", usually: "3–6 min"),
        MovingExample(10, "the warm-up before a run", usually: "5–10 min"),
        MovingExample(15, "a walk around the block", usually: "10–15 min"),
        MovingExample(20, "a game of tag with the kids", usually: "10–20 min"),
        MovingExample(30, "walking the dog", usually: "most daily dog walks are 20–30 min"),
        MovingExample(40, "a game of frisbee in the park", usually: "20–40 min"),
        MovingExample(45, "a swim at the local pool", usually: "30–45 min"),
        MovingExample(60, "a full yoga class", usually: "45–60 min"),
        MovingExample(75, "a long walk on the beach", usually: "45–75 min"),
        MovingExample(90, "a dance class", usually: "60–90 min"),
        MovingExample(105, "a full football match", usually: "90 min of play plus stoppage time"),
        MovingExample(120, "a tennis match", usually: "best of three sets, 1.5–2 h"),
        MovingExample(150, "a walking tour of a city", usually: "1.5–2.5 h"),
        MovingExample(180, "a morning hike", usually: "2–3 h"),
        MovingExample(210, "a Sunday bike ride", usually: "2–3.5 h"),
        MovingExample(240, "dancing all evening at a wedding", usually: "3–4 h"),
        MovingExample(270, "a round of golf", usually: "18 holes, 4–4.5 h"),
        MovingExample(300, "an afternoon of gardening", usually: "3–5 h"),
        MovingExample(360, "spring cleaning the whole house", usually: "4–6 h"),
        MovingExample(420, "a day of sightseeing on foot", usually: "5–7 h"),
        MovingExample(480, "a full day's hike", usually: "6–8 h on the trail"),
        MovingExample(540, "a day on the ski slopes", usually: "7–9 h, first lift to last"),
        MovingExample(600, "helping a friend move", usually: "a long day, 8–10 h"),
        MovingExample(720, "a twelve-week yoga course", usually: "12 classes of an hour"),
        MovingExample(780, "a summer of Saturday tennis", usually: "13 Saturdays of an hour"),
        MovingExample(900, "a month of walking the dog", usually: "30 walks of 30 min"),
        MovingExample(960, "a weekend of hiking", usually: "2 days of 8 h"),
        MovingExample(1080, "a long weekend of cycling", usually: "3 days of 6 h"),
        MovingExample(1200, "five days of walking in the hills", usually: "5 days of 4 h"),
        MovingExample(1350, "a month of morning swims", usually: "30 swims of 45 min"),
        MovingExample(1440, "a three-day hike", usually: "3 days of 8 h"),
        MovingExample(1800, "a month of daily yoga", usually: "30 classes of an hour"),
        MovingExample(2160, "a week of skiing", usually: "6 days of 6 h"),
        MovingExample(2520, "a week-long bike tour", usually: "6 days of 7 h"),
        MovingExample(2880, "a year of weekly dance classes", usually: "48 classes of an hour"),
        MovingExample(3360, "a week-long trek", usually: "7 days of 8 h"),
        MovingExample(6000, "a hundred yoga classes", usually: "100 classes of an hour"),
        MovingExample(6720, "a two-week trek", usually: "14 days of 8 h"),
    ]

    /// Index in `all` of the highest example at or below `movingSeconds` in whole minutes (as the
    /// figure shows them, rounded down); nil below the first.
    public static func index(forMovingSeconds movingSeconds: TimeInterval) -> Int? {
        let minutes = DurationFormat.wholeMinutes(movingSeconds)
        return all.lastIndex { $0.minutes <= minutes }
    }

    /// The highest example reached by `movingSeconds`, if any.
    public static func example(forMovingSeconds movingSeconds: TimeInterval) -> MovingExample? {
        index(forMovingSeconds: movingSeconds).map { all[$0] }
    }
}
