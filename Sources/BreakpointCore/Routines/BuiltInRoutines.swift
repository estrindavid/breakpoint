import Foundation

// Content per SPEC §2.2 and §3.4; edit wording here, nowhere else.
//
// Every routine is plain data: an id that never changes (Settings and the rotation file refer to
// it), a name, a one-line summary for Settings, and steps. Every step has a title (2–5 words), one
// instruction sentence (≤ 12 words), a cue for the chip, a tempo (one repetition, played over and
// over) and a duration that is a whole number of repetitions. Each routine lasts exactly 120 s.
//
// The rules for what may ship (checked by RoutineWordingTests): movements only, never benefits or
// anything medical; second person; no "should", no "!"; doable standing or seated at a desk, in
// ordinary clothes, without turning away from the screen for long; nothing ballistic, no
// end-range neck circles, nothing held to discomfort.

/// The built-in routine library for `move` (SPEC §2.2).
public enum BuiltInRoutines {
    // MARK: No equipment

    public static let neckAndShoulders = Routine(
        id: "neck-and-shoulders",
        name: "Neck and shoulders",
        summary: "Shoulder-blade squeezes, an overhead reach, rolls and a side-bend.",
        steps: [
            RoutineStep(
                id: "shoulder-blade-squeeze",
                title: "Shoulder-blade squeeze",
                instruction: "Pull your shoulder blades together, then let them go.",
                cue: "3 s squeeze · 3 s release",
                tempo: [TempoPhase("squeeze", 3), TempoPhase("release", 3)],
                duration: 30),
            RoutineStep(
                id: "arms-up-the-wall",
                title: "Arms up the wall",
                instruction: "Back to a wall, or stand tall and reach overhead.",
                cue: "3 s up · 3 s down",
                tempo: [TempoPhase("up", 3), TempoPhase("down", 3)],
                duration: 36),
            RoutineStep(
                id: "shoulder-rolls",
                title: "Slow shoulder rolls",
                instruction: "Roll your shoulders up, back and down in slow circles.",
                cue: "4 s each circle",
                tempo: [TempoPhase("up and back", 2), TempoPhase("down", 2)],
                duration: 24),
            RoutineStep(
                id: "neck-side-bend",
                title: "Gentle neck side-bend",
                instruction: "Tip one ear toward your shoulder, then switch sides.",
                cue: "5 s each side",
                tempo: [TempoPhase("one side", 5), TempoPhase("other side", 5)],
                duration: 30),
        ])

    public static let wristsAndForearms = Routine(
        id: "wrists-and-forearms",
        name: "Wrists and forearms",
        summary: "Wrist circles, finger spreads and easy palm stretches.",
        steps: [
            RoutineStep(
                id: "wrist-circles",
                title: "Slow wrist circles",
                instruction: "Make loose fists and circle your wrists slowly.",
                cue: "4 s each circle · reverse halfway",
                tempo: [TempoPhase("circle", 4)],
                duration: 24),
            RoutineStep(
                id: "finger-spreads",
                title: "Spread and close",
                instruction: "Spread your fingers wide, then close them into a soft fist.",
                cue: "2 s open · 2 s close",
                tempo: [TempoPhase("open", 2), TempoPhase("close", 2)],
                duration: 24),
            RoutineStep(
                id: "palm-up-stretch",
                title: "Palm-up stretch",
                instruction: "Arm out, palm up; ease your fingers back with the other hand.",
                cue: "12 s each hand · easy",
                tempo: [TempoPhase("one hand", 12), TempoPhase("other hand", 12)],
                duration: 24),
            RoutineStep(
                id: "palm-down-stretch",
                title: "Palm-down stretch",
                instruction: "Arm out, palm down; ease your hand down with the other.",
                cue: "12 s each hand · easy",
                tempo: [TempoPhase("one hand", 12), TempoPhase("other hand", 12)],
                duration: 24),
            RoutineStep(
                id: "shake-out",
                title: "Shake out your hands",
                instruction: "Let your hands hang loose and shake them gently.",
                cue: "Loose and easy",
                tempo: [TempoPhase("shake", 4)],
                duration: 24),
        ])

    public static let upperBack = Routine(
        id: "upper-back",
        name: "Upper back",
        summary: "A seated cat-cow, elbow circles, rows and a gentle twist.",
        steps: [
            RoutineStep(
                id: "seated-cat-cow",
                title: "Seated cat-cow",
                instruction: "Hands on your knees, round your back, then lift your chest.",
                cue: "3 s round · 3 s lift",
                tempo: [TempoPhase("round", 3), TempoPhase("lift", 3)],
                duration: 36),
            RoutineStep(
                id: "elbow-circles",
                title: "Elbow circles",
                instruction: "Fingertips on your shoulders, draw slow circles with your elbows.",
                cue: "4 s each circle",
                tempo: [TempoPhase("circle", 4)],
                duration: 24),
            RoutineStep(
                id: "reach-and-row",
                title: "Reach and row",
                instruction: "Reach both arms forward, then pull your elbows back.",
                cue: "3 s reach · 3 s pull",
                tempo: [TempoPhase("reach", 3), TempoPhase("pull back", 3)],
                duration: 30),
            RoutineStep(
                id: "seated-twist",
                title: "Seated twist",
                instruction: "Sit tall and turn gently to one side, then the other.",
                cue: "5 s each side",
                tempo: [TempoPhase("one side", 5), TempoPhase("other side", 5)],
                duration: 30),
        ])

    public static let chestOpener = Routine(
        id: "chest-opener",
        name: "Chest opener",
        summary: "Clasped hands, goalpost arms, wide sweeps and a chest lift.",
        steps: [
            RoutineStep(
                id: "hands-clasped-behind",
                title: "Hands clasped behind",
                instruction: "Clasp your hands behind you and lift your chest a little.",
                cue: "5 s hold · 3 s release",
                tempo: [TempoPhase("hold", 5), TempoPhase("release", 3)],
                duration: 32),
            RoutineStep(
                id: "goalpost-arms",
                title: "Goalpost arms",
                instruction: "Raise your arms like goalposts and draw your elbows back.",
                cue: "3 s back · 3 s forward",
                tempo: [TempoPhase("back", 3), TempoPhase("forward", 3)],
                duration: 30),
            RoutineStep(
                id: "open-arm-sweeps",
                title: "Open-arm sweeps",
                instruction: "Sweep your arms wide open, then bring them together in front.",
                cue: "3 s open · 3 s close",
                tempo: [TempoPhase("open", 3), TempoPhase("close", 3)],
                duration: 30),
            RoutineStep(
                id: "chest-lift",
                title: "Chest lift",
                instruction: "Hands behind your head, elbows wide, lift your chest gently.",
                cue: "4 s lift · 3 s return",
                tempo: [TempoPhase("lift", 4), TempoPhase("return", 3)],
                duration: 28),
        ])

    public static let hipsAndCalves = Routine(
        id: "hips-and-calves",
        name: "Hips and calves",
        summary: "Standing: heel raises, a calf stretch, hip circles and a march.",
        steps: [
            RoutineStep(
                id: "heel-raises",
                title: "Heel raises",
                instruction: "Hold the desk, rise onto your toes, then lower slowly.",
                cue: "2 s up · 3 s down",
                tempo: [TempoPhase("up", 2), TempoPhase("down", 3)],
                duration: 30),
            RoutineStep(
                id: "calf-stretch",
                title: "Calf stretch",
                instruction: "Step one foot back, heel down, and lean gently forward.",
                cue: "15 s each side",
                tempo: [TempoPhase("one side", 15), TempoPhase("other side", 15)],
                duration: 30),
            RoutineStep(
                id: "hip-circles",
                title: "Hip circles",
                instruction: "Hands on your hips, draw slow circles with your hips.",
                cue: "5 s each circle · reverse halfway",
                tempo: [TempoPhase("circle", 5)],
                duration: 30),
            RoutineStep(
                id: "march-in-place",
                title: "March in place",
                instruction: "Lift one knee, then the other, at an easy pace.",
                cue: "Easy pace",
                tempo: [TempoPhase("one knee", 1.5), TempoPhase("other knee", 1.5)],
                duration: 30),
        ])

    public static let standAndReach = Routine(
        id: "stand-and-reach",
        name: "Stand and reach",
        summary: "Overhead and side reaches, a desk lean and shoulder shrugs.",
        steps: [
            RoutineStep(
                id: "overhead-reach",
                title: "Stand and reach",
                instruction: "Stand up and reach both arms overhead, then lower them.",
                cue: "4 s reach · 4 s lower",
                tempo: [TempoPhase("reach", 4), TempoPhase("lower", 4)],
                duration: 32),
            RoutineStep(
                id: "side-reach",
                title: "Side reach",
                instruction: "Reach one arm overhead and lean gently to the other side.",
                cue: "5 s each side",
                tempo: [TempoPhase("one side", 5), TempoPhase("other side", 5)],
                duration: 30),
            RoutineStep(
                id: "desk-lean",
                title: "Desk lean",
                instruction: "Hands on the desk, step back, and let your chest sink gently.",
                cue: "6 s lean · 4 s rise",
                tempo: [TempoPhase("lean", 6), TempoPhase("rise", 4)],
                duration: 30),
            RoutineStep(
                id: "shoulder-shrugs",
                title: "Shoulder shrugs",
                instruction: "Lift your shoulders toward your ears, then let them drop.",
                cue: "2 s up · 2 s down",
                tempo: [TempoPhase("up", 2), TempoPhase("down", 2)],
                duration: 28),
        ])

    public static let seatedLegs = Routine(
        id: "seated-legs",
        name: "Seated legs",
        summary: "Under the desk: ankle circles, leg lifts, heel-toe rocks and squeezes.",
        steps: [
            RoutineStep(
                id: "ankle-circles",
                title: "Ankle circles",
                instruction: "Lift one foot and circle your ankle slowly; switch halfway.",
                cue: "3 s each circle · switch feet",
                tempo: [TempoPhase("circle", 3)],
                duration: 30),
            RoutineStep(
                id: "seated-leg-lifts",
                title: "Seated leg lifts",
                instruction: "Straighten one knee, hold, then lower it; switch legs each time.",
                cue: "2 s up · 2 s hold · 2 s down",
                tempo: [TempoPhase("up", 2), TempoPhase("hold", 2), TempoPhase("down", 2)],
                duration: 30),
            RoutineStep(
                id: "heel-toe-rocks",
                title: "Heel and toe rocks",
                instruction: "Feet flat, rock up onto your toes, then onto your heels.",
                cue: "2 s toes · 2 s heels",
                tempo: [TempoPhase("toes", 2), TempoPhase("heels", 2)],
                duration: 28),
            RoutineStep(
                id: "seat-squeeze",
                title: "Seat squeeze",
                instruction: "Squeeze your glutes, then let them go.",
                cue: "4 s squeeze · 4 s release",
                tempo: [TempoPhase("squeeze", 4), TempoPhase("release", 4)],
                duration: 32),
        ])

    // MARK: Resistance band (only with "I have a resistance band")

    /// Rest between band sets.
    private static func bandRest(_ number: Int) -> RoutineStep {
        RoutineStep(
            id: "rest-\(number)",
            title: "Rest your arms",
            instruction: "Let your arms hang and breathe easy.",
            cue: "Rest",
            tempo: [TempoPhase("rest", 15)],
            duration: 15)
    }

    public static let bandRaises = Routine(
        id: "band-raises",
        name: "Band raises",
        summary: "Three sets of lateral raises with short rests.",
        equipment: .band,
        steps: [
            RoutineStep(
                id: "band-lateral-raise-1",
                title: "Band lateral raises",
                instruction: "Stand on the band and raise your arms out to the sides.",
                cue: "2 s up · 3 s down",
                tempo: [TempoPhase("up", 2), TempoPhase("down", 3)],
                duration: 30),
            bandRest(1),
            RoutineStep(
                id: "band-lateral-raise-2",
                title: "Band lateral raises",
                instruction: "Same again, arms out to the sides, slow and controlled.",
                cue: "2 s up · 3 s down",
                tempo: [TempoPhase("up", 2), TempoPhase("down", 3)],
                duration: 30),
            bandRest(2),
            RoutineStep(
                id: "band-lateral-raise-3",
                title: "Band lateral raises",
                instruction: "Last set, slow and controlled, resting when you need.",
                cue: "2 s up · 3 s down",
                tempo: [TempoPhase("up", 2), TempoPhase("down", 3)],
                duration: 30),
        ])

    public static let bandPullAparts = Routine(
        id: "band-pull-aparts",
        name: "Band pull-aparts",
        summary: "Three sets of pull-aparts at chest height with short rests.",
        equipment: .band,
        steps: [
            RoutineStep(
                id: "band-pull-apart-1",
                title: "Band pull-aparts",
                instruction: "Hold the band at chest height and pull your hands apart.",
                cue: "2 s apart · 3 s back",
                tempo: [TempoPhase("apart", 2), TempoPhase("back", 3)],
                duration: 30),
            bandRest(1),
            RoutineStep(
                id: "band-pull-apart-palms-up",
                title: "Palms-up pull-aparts",
                instruction: "Same move with your palms facing up.",
                cue: "2 s apart · 3 s back",
                tempo: [TempoPhase("apart", 2), TempoPhase("back", 3)],
                duration: 30),
            bandRest(2),
            RoutineStep(
                id: "band-pull-apart-3",
                title: "Band pull-aparts",
                instruction: "Last set, slow and controlled, resting when you need.",
                cue: "2 s apart · 3 s back",
                tempo: [TempoPhase("apart", 2), TempoPhase("back", 3)],
                duration: 30),
        ])

    // MARK: The library

    /// Every built-in routine, in the order Settings lists them. The first is the default.
    public static let all: [Routine] = [
        neckAndShoulders, wristsAndForearms, upperBack, chestOpener, hipsAndCalves, standAndReach, seatedLegs,
        bandRaises, bandPullAparts,
    ]

    /// The built-in routine with this id.
    public static func routine(id: String) -> Routine? { all.first { $0.id == id } }

    /// The routines the user's equipment allows (band routines only with "I have a resistance
    /// band"), whether or not they are excluded.
    public static func available(for settings: Settings) -> [Routine] {
        all.filter { $0.equipment == .none || settings.hasBand }
    }

    /// The routines a stretch break may use: available and not excluded. Never empty: if every one
    /// is excluded (a hand-edited file), exclusions are ignored.
    public static func allowed(for settings: Settings) -> [Routine] {
        let available = available(for: settings)
        let allowed = available.filter { !settings.excludedRoutines.contains($0.id) }
        return allowed.isEmpty ? available : allowed
    }

    /// The first allowed routine (used where no rotation applies: previews of a fixed state).
    public static func routine(for settings: Settings) -> Routine {
        allowed(for: settings).first ?? neckAndShoulders
    }
}
