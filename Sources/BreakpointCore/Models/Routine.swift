import Foundation

/// One phase of a step's repeating tempo, e.g. "up" for 3 s (SPEC §2.2).
public struct TempoPhase: Codable, Equatable, Hashable, Sendable {
    /// What the body does in this phase: "up", "hold", "release", "one side".
    public var label: String
    public var seconds: TimeInterval

    public init(_ label: String, _ seconds: TimeInterval) {
        self.label = label
        self.seconds = seconds
    }
}

/// One step of a guided routine (SPEC §2.2): title, one instruction line, a cue, a structured
/// tempo and a duration.
public struct RoutineStep: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Stable identifier, unique within its routine, e.g. "shoulder-blade-squeeze".
    public var id: String
    /// "Shoulder-blade squeeze".
    public var title: String
    /// One sentence, ≤ 12 words (SPEC §3.11).
    public var instruction: String
    /// Rep or tempo cue shown in the cue chip, e.g. "3 s squeeze · 3 s release".
    public var cue: String
    /// One repetition, played over and over for the whole step: e.g. squeeze 3 s, release 3 s.
    /// The step's duration is a whole number of repetitions.
    public var tempo: [TempoPhase]
    public var duration: TimeInterval

    public init(id: String, title: String, instruction: String, cue: String, tempo: [TempoPhase] = [],
                duration: TimeInterval) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.cue = cue
        self.tempo = tempo
        self.duration = duration
    }

    /// Seconds in one repetition of the tempo (0 when the step has none).
    public var repetitionLength: TimeInterval { tempo.reduce(0) { $0 + $1.seconds } }

    enum CodingKeys: String, CodingKey { case id, title, instruction, cue, tempo, duration }

    /// Tolerant: a step written without a tempo still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        instruction = try c.decode(String.self, forKey: .instruction)
        cue = (try? c.decodeIfPresent(String.self, forKey: .cue)) ?? ""
        tempo = (try? c.decodeIfPresent([TempoPhase].self, forKey: .tempo)) ?? []
        duration = try c.decode(TimeInterval.self, forKey: .duration)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(instruction, forKey: .instruction)
        try c.encode(cue, forKey: .cue)
        try c.encode(tempo, forKey: .tempo)
        try c.encode(duration, forKey: .duration)
    }
}

/// What a routine needs besides a desk and a little room.
public enum RoutineEquipment: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    /// Offered only with "I have a resistance band" on.
    case band
}

/// A sequence of steps played during `move` (SPEC §2.2).
public struct Routine: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Stable identifier, e.g. "wrists-and-forearms". Settings and rotation refer to routines by it.
    public var id: String
    public var name: String
    /// One line for Settings, e.g. "Circles, spreads and gentle palm stretches."
    public var summary: String
    public var equipment: RoutineEquipment
    public var steps: [RoutineStep]

    public init(id: String, name: String, summary: String = "", equipment: RoutineEquipment = .none,
                steps: [RoutineStep]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.equipment = equipment
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey { case id, name, summary, equipment, steps }

    /// Tolerant: a routine written without a summary or equipment still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        equipment = (try? c.decodeIfPresent(RoutineEquipment.self, forKey: .equipment)) ?? RoutineEquipment.none
        steps = try c.decode([RoutineStep].self, forKey: .steps)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(summary, forKey: .summary)
        try c.encode(equipment, forKey: .equipment)
        try c.encode(steps, forKey: .steps)
    }

    public var totalDuration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }

    /// Start offset of each step from the beginning of the routine.
    public var stepOffsets: [TimeInterval] {
        var offsets: [TimeInterval] = []
        var t: TimeInterval = 0
        for step in steps { offsets.append(t); t += step.duration }
        return offsets
    }

    /// The step index playing at `elapsed` seconds into the routine (last step when past the end).
    public func stepIndex(at elapsed: TimeInterval) -> Int {
        guard !steps.isEmpty else { return 0 }
        var t: TimeInterval = 0
        for (index, step) in steps.enumerated() {
            t += step.duration
            if elapsed < t { return index }
        }
        return steps.count - 1
    }

    /// This routine with `steps` appended (used by "1 more minute" on `move`).
    public func appending(_ more: [RoutineStep]) -> Routine {
        var copy = self
        copy.steps += more
        return copy
    }

    /// This routine with `step` appended.
    public func appending(_ step: RoutineStep) -> Routine { appending([step]) }
}

/// The rotating copy for one break kind (SPEC §2.2: 4–6 title/instruction variants per kind).
public struct BreakCopy: Codable, Equatable, Hashable, Sendable {
    public struct Variant: Codable, Equatable, Hashable, Sendable {
        /// Overlay title, 2–5 words.
        public var title: String
        /// One sentence, ≤ 12 words.
        public var instruction: String

        public init(title: String, instruction: String) {
            self.title = title
            self.instruction = instruction
        }
    }

    public var kind: BreakKind
    public var variants: [Variant]

    public init(kind: BreakKind, variants: [Variant]) {
        self.kind = kind
        self.variants = variants
    }

    /// The variant for a rotation counter (wraps around).
    public func variant(rotation: Int) -> Variant {
        guard !variants.isEmpty else { return Variant(title: "", instruction: "") }
        let i = ((rotation % variants.count) + variants.count) % variants.count
        return variants[i]
    }
}
