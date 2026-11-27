import Foundation
import Testing
@testable import BreakpointCore

/// The rules every routine must meet before it ships (SPEC §2.2, §3.11), run over every routine's
/// text and timing. A routine loaded from a file later can be checked with the same function.
enum RoutineWording {
    /// Word stems that describe benefits, health or medicine, or ballistic or painful movement.
    /// A word fails when it starts with one of these (so "prevents", "healing", "relieves" fail).
    static let bannedStems = [
        "treat", "cure", "prevent", "pain", "posture", "relief", "relieve", "heal", "fix", "injur", "therap",
        "medic", "doctor", "symptom", "ache", "sore", "stiff", "tension", "strain", "cramp", "improv", "benefi",
        "boost", "reduc", "hurt", "discomfort", "bounc", "swing", "jerk",
    ]
    /// Whole words that fail ("should" is a whole word: "shoulder" is fine).
    static let bannedWords: Set<String> = ["should", "shouldn't", "must"]
    /// Phrases that fail anywhere in the text.
    static let bannedPhrases = ["look away", "good for", "helps", "!"]

    /// Every problem with `routine`, as readable lines; empty when it may ship.
    static func violations(in routine: Routine) -> [String] {
        var problems: [String] = []
        func check(_ text: String, _ field: String) {
            let lower = text.lowercased()
            for phrase in bannedPhrases where lower.contains(phrase) {
                problems.append("\(routine.id) \(field): contains \"\(phrase)\"")
            }
            let words = lower.split { !$0.isLetter && $0 != "'" }.map(String.init)
            for word in words {
                if let stem = bannedStems.first(where: { word.hasPrefix($0) }) {
                    problems.append("\(routine.id) \(field): \"\(word)\" (banned: \(stem)…)")
                } else if bannedWords.contains(word) {
                    problems.append("\(routine.id) \(field): \"\(word)\"")
                }
            }
        }
        check(routine.name, "name")
        check(routine.summary, "summary")
        if routine.summary.isEmpty { problems.append("\(routine.id): no summary") }
        if !(3...5).contains(routine.steps.count) {
            problems.append("\(routine.id): \(routine.steps.count) steps (3–5)")
        }
        if routine.totalDuration != Timing.routineLength {
            problems.append("\(routine.id): lasts \(routine.totalDuration) s, not \(Timing.routineLength) s")
        }
        for step in routine.steps {
            let where_ = "step \(step.id)"
            check(step.title, "\(where_) title")
            check(step.instruction, "\(where_) instruction")
            check(step.cue, "\(where_) cue")
            for phase in step.tempo { check(phase.label, "\(where_) tempo") }
            if !(Timing.routineStepShortest...Timing.routineStepLongest).contains(step.duration) {
                problems.append("\(routine.id) \(where_): \(step.duration) s (10–120 s)")
            }
            let titleWords = step.title.split(separator: " ").count
            if !(1...5).contains(titleWords) { problems.append("\(routine.id) \(where_): title has \(titleWords) words") }
            let instructionWords = step.instruction.split(separator: " ").count
            if instructionWords > 12 { problems.append("\(routine.id) \(where_): instruction has \(instructionWords) words (≤ 12)") }
            if !step.instruction.hasSuffix(".") { problems.append("\(routine.id) \(where_): instruction is not one sentence") }
            if step.instruction.dropLast().contains(".") { problems.append("\(routine.id) \(where_): instruction has two sentences") }
            if step.cue.isEmpty { problems.append("\(routine.id) \(where_): no cue") }
            if step.tempo.isEmpty || step.tempo.contains(where: { $0.seconds <= 0 || $0.label.isEmpty }) {
                problems.append("\(routine.id) \(where_): tempo missing or empty")
            } else {
                let reps = step.duration / step.repetitionLength
                if abs(reps - reps.rounded()) > 0.001 {
                    problems.append("\(routine.id) \(where_): \(step.duration) s is not a whole number of \(step.repetitionLength) s repetitions")
                }
            }
            // End-range neck circles are never offered.
            if step.title.lowercased().contains("neck") || step.instruction.lowercased().contains("neck") {
                let text = (step.title + " " + step.instruction + " " + step.cue).lowercased()
                if text.contains("circle") || text.contains("roll") {
                    problems.append("\(routine.id) \(where_): neck circles or rolls")
                }
            }
        }
        return problems
    }
}

@Suite("Routine wording and timing (SPEC §2.2, §3.11)")
struct RoutineWordingTests {
    @Test func everyBuiltInRoutineMayShip() {
        for routine in BuiltInRoutines.all {
            let problems = RoutineWording.violations(in: routine)
            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        }
    }

    @Test func theLibraryCoversEnough() {
        let noEquipment = BuiltInRoutines.all.filter { $0.equipment == .none }
        let band = BuiltInRoutines.all.filter { $0.equipment == .band }
        #expect((6...8).contains(noEquipment.count))
        #expect(band.count >= 1)
        #expect(noEquipment.contains { $0.id == "wrists-and-forearms" })
    }

    @Test func theCheckCatchesBadRoutines() {
        let bad = Routine(id: "bad", name: "Posture fix", summary: "Prevents pain!", steps: [
            RoutineStep(id: "a", title: "Neck circles", instruction: "You should roll your neck in full circles.",
                        cue: "Until it hurts", tempo: [TempoPhase("circle", 7)], duration: 9),
            RoutineStep(id: "b", title: "Look away", instruction: "Look away from the screen. Then relax.",
                        cue: "", tempo: [], duration: 130),
        ])
        let problems = RoutineWording.violations(in: bad).joined(separator: "\n")
        for expected in ["posture", "fix", "prevent", "pain", "\"!\"", "should", "hurt", "look away", "neck circles",
                         "2 steps", "lasts 139", "9.0 s (10–120 s)", "130.0 s (10–120 s)", "two sentences", "no cue",
                         "tempo missing", "whole number"] {
            #expect(problems.contains(expected), "missed: \(expected)")
        }
    }

    @Test func replayedStepsKeepTheirWording() {
        for routine in BuiltInRoutines.all {
            let replay = RoutineReplay.extraMinute(for: routine, plannedLength: routine.totalDuration, extension: 1)
            for step in replay {
                #expect((Timing.routineStepShortest...Timing.routineStepLongest).contains(step.duration))
                #expect(routine.steps.contains { $0.title == step.title && $0.instruction == step.instruction })
            }
        }
    }
}
