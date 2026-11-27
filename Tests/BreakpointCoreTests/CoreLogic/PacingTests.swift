import Foundation
import Testing
@testable import BreakpointCore

@Suite("Ring pacing (SPEC §3.4 move)")
struct TempoPacingTests {
    let upDown = [TempoPhase("up", 3), TempoPhase("down", 3)]

    @Test func motionsForEveryShapeOfTempo() {
        #expect(TempoPacing.motions(for: upDown) == [.out, .back])
        #expect(TempoPacing.motions(for: [TempoPhase("up", 2), TempoPhase("hold", 2), TempoPhase("down", 2)]) == [.out, .hold, .back])
        // A hold that opens the repetition fills the ring, so it is never still at empty.
        #expect(TempoPacing.motions(for: [TempoPhase("hold", 5), TempoPhase("release", 3)]) == [.out, .back])
        #expect(TempoPacing.motions(for: [TempoPhase("circle", 4)]) == [.around])
        #expect(TempoPacing.motions(for: [TempoPhase("one side", 5), TempoPhase("other side", 5)]) == [.out, .back])
        #expect(TempoPacing.motions(for: []) == [])
    }

    @Test func everyBuiltInStepHasAPaceThatFillsAndReturns() {
        for routine in BuiltInRoutines.all {
            for step in routine.steps {
                let motions = TempoPacing.motions(for: step.tempo)
                #expect(motions.count == step.tempo.count, "\(step.id)")
                if step.tempo.count > 1 {
                    // Every repetition goes out and comes back, so the ring is empty at its end.
                    #expect(motions.contains(.out) && motions.last == .back, "\(step.id): \(motions)")
                    let end = TempoPacing.frame(tempo: step.tempo, at: step.repetitionLength - 0.0001)
                    #expect((end?.fullness ?? 1) < 0.01, "\(step.id)")
                }
            }
        }
    }

    @Test func theRingFillsForUpAndReturnsForDown() throws {
        let start = try #require(TempoPacing.frame(tempo: upDown, at: 0))
        #expect(start.label == "up" && start.motion == .out && start.fullness == 0)
        let midUp = try #require(TempoPacing.frame(tempo: upDown, at: 1.5))
        #expect(abs(midUp.fullness - 0.5) < 1e-9)
        let top = try #require(TempoPacing.frame(tempo: upDown, at: 3))
        #expect(top.label == "down" && abs(top.fullness - 1) < 1e-9)
        let midDown = try #require(TempoPacing.frame(tempo: upDown, at: 4.5))
        #expect(abs(midDown.fullness - 0.5) < 1e-9 && midDown.phaseRemaining == 1.5)
        let nextRep = try #require(TempoPacing.frame(tempo: upDown, at: 6.75))
        #expect(nextRep.repetition == 1 && nextRep.label == "up" && nextRep.fullness < 0.2)
    }

    @Test func aHoldKeepsTheRingFull() throws {
        let tempo = [TempoPhase("up", 2), TempoPhase("hold", 2), TempoPhase("down", 2)]
        for t in [2.0, 2.5, 3.9] {
            let frame = try #require(TempoPacing.frame(tempo: tempo, at: t))
            #expect(frame.label == "hold" && frame.fullness == 1)
        }
    }

    @Test func aOnePhaseRepetitionTravelsAroundWithoutAJump() throws {
        let tempo = [TempoPhase("circle", 4)]
        let a = try #require(TempoPacing.frame(tempo: tempo, at: 3.99))
        let b = try #require(TempoPacing.frame(tempo: tempo, at: 4.01))
        #expect(a.motion == .around && a.fullness > 0.99 && b.fullness < 0.01)
    }

    @Test func reduceMotionStepsByWholeSeconds() throws {
        let values = try [0.2, 1.2, 2.2, 3.2, 4.2, 5.2].map { t in
            try #require(TempoPacing.frame(tempo: upDown, at: t, stepped: true)).fullness
        }
        let expected = [1.0 / 3, 2.0 / 3, 1, 2.0 / 3, 1.0 / 3, 0]
        for (value, want) in zip(values, expected) { #expect(abs(value - want) < 1e-9) }
        // Within a second nothing moves.
        let a = try #require(TempoPacing.frame(tempo: upDown, at: 1.05, stepped: true))
        let b = try #require(TempoPacing.frame(tempo: upDown, at: 1.95, stepped: true))
        #expect(a.fullness == b.fullness)
    }

    @Test func noTempoNoPace() {
        #expect(TempoPacing.frame(tempo: [], at: 3) == nil)
        #expect(TempoPacing.neighbours(tempo: upDown, phaseIndex: 0) == ("down", "down"))
    }
}

@Suite("Step tick (SPEC §4.7)")
struct StepTickTests {
    func stretch() -> BreakSession {
        BreakSessionRules.makeSession(kind: .move, opportunity: nil, settings: .defaults, expectedRun: nil, agentName: nil,
                                      copyRotation: 0, now: Fixture.date(14), routine: BuiltInRoutines.neckAndShoulders)
    }

    @Test func ticksWhenTimeMovesToTheNextStep() {
        let session = stretch()
        let first = BuiltInRoutines.neckAndShoulders.steps[0].duration
        let next = BreakSessionRules.advanced(session, now: session.startedAt.addingTimeInterval(first))
        #expect(next.stepIndex == 1)
        #expect(BreakSessionRules.playsStepTick(from: session, to: next, settings: .defaults, callSignals: []))
        // Not while the step continues, not during a call, not with the setting off or volume 0.
        #expect(!BreakSessionRules.playsStepTick(from: session, to: session, settings: .defaults, callSignals: []))
        #expect(!BreakSessionRules.playsStepTick(from: session, to: next, settings: .defaults, callSignals: .microphone))
        #expect(!BreakSessionRules.playsStepTick(from: session, to: next, settings: .defaults, callSignals: .camera))
        var off = Settings.defaults
        off.stepTick = false
        #expect(!BreakSessionRules.playsStepTick(from: session, to: next, settings: off, callSignals: []))
        var silent = Settings.defaults
        silent.volume = 0
        #expect(!BreakSessionRules.playsStepTick(from: session, to: next, settings: silent, callSignals: []))
    }

    @Test func neverForPreviewsOrOtherKinds() {
        var preview = stretch()
        preview.isPreview = true
        var moved = preview
        moved.stepIndex = 1
        #expect(!BreakSessionRules.playsStepTick(from: preview, to: moved, settings: .defaults, callSignals: []))
        let eyes = BreakSessionRules.makeSession(kind: .eyes, opportunity: nil, settings: .defaults, expectedRun: nil,
                                                 agentName: nil, copyRotation: 0, now: Fixture.date(14))
        #expect(!BreakSessionRules.playsStepTick(from: eyes, to: eyes, settings: .defaults, callSignals: []))
    }

    @Test func onByDefault() {
        #expect(Settings.defaults.stepTick)
        let decoded = try? JSONFile<Settings>.decoder.decode(Settings.self, from: Data(#"{"version":1}"#.utf8))
        #expect(decoded?.stepTick == true)
        let off = try? JSONFile<Settings>.decoder.decode(Settings.self, from: Data(#"{"version":1,"stepTick":false}"#.utf8))
        #expect(off?.stepTick == false)
    }
}

@Suite("Closing lines, eye-rest tasks and walk ideas (SPEC §3.4, §3.11)")
struct BreakEndingCopyTests {
    static let praise = ["great", "well done", "nice", "good job", "awesome", "proud", "amazing", "streak", "keep it up"]

    func followsTheRules(_ text: String) {
        let lower = text.lowercased()
        #expect(!text.contains("!"), "\(text)")
        #expect(!lower.split { !$0.isLetter }.contains("should"), "\(text)")
        #expect(!lower.contains("look away"), "\(text)")
        for word in Self.praise { #expect(!lower.contains(word), "\(text) praises") }
        // Never a count of breaks ("3rd", "#2", "5 today").
        #expect(!lower.contains("today") && !lower.contains("#"), "\(text)")
    }

    @Test func closingLinesNameTheTimeOrTheRoutine() {
        #expect(BreakCopyLibrary.closingLine(kind: .move, rotation: 0, elapsed: 120, routine: BuiltInRoutines.neckAndShoulders)
                == "That's two minutes.")
        #expect(BreakCopyLibrary.closingLine(kind: .move, rotation: 1, elapsed: 120, routine: BuiltInRoutines.neckAndShoulders)
                == "Shoulders done.")
        #expect(BreakCopyLibrary.closingLine(kind: .move, rotation: 2, elapsed: 180, routine: nil) == "Three minutes, done.")
        #expect(BreakCopyLibrary.closingLine(kind: .eyes, rotation: 0, elapsed: 20.4, routine: nil) == "That's twenty seconds.")
        #expect(BreakCopyLibrary.closingLine(kind: .walk, rotation: 2, elapsed: 372, routine: nil) == "Six minutes on your feet.")
        #expect(BreakCopyLibrary.closingLine(kind: .breathe, rotation: 0, elapsed: 60, routine: nil) == "That's one minute.")
        // Done at 80% says the time actually spent, rounded.
        #expect(BreakCopyLibrary.closingLine(kind: .eyes, rotation: 1, elapsed: 16.5, routine: nil) == "Twenty seconds, done.")
        #expect(BreakCopyLibrary.spokenLength(16 * 60) == "16 minutes")
    }

    @Test func everyClosingLineFollowsTheRules() {
        for kind in BreakKind.allCases {
            #expect(BreakCopyLibrary.closingTemplates(kind).count >= 3, "\(kind) needs a few lines to rotate")
            for rotation in 0..<BreakCopyLibrary.closingTemplates(kind).count {
                for routine in BuiltInRoutines.all + [nil] as [Routine?] {
                    let line = BreakCopyLibrary.closingLine(kind: kind, rotation: rotation, elapsed: kind.defaultLength,
                                                            routine: routine)
                    followsTheRules(line)
                    #expect(line.split(separator: " ").count <= 5, "\(line)")
                    #expect(!line.contains("{"), "\(line)")
                }
            }
        }
        for routine in BuiltInRoutines.all {
            #expect(BreakCopyLibrary.routineClosingNames[routine.id] != nil, "\(routine.id) has no short name")
        }
    }

    @Test func eyeRestsGiveATinyTask() {
        let eyes = BreakCopyLibrary.eyes.variants
        #expect(eyes.count >= 4)
        for v in eyes {
            followsTheRules(v.title)
            followsTheRules(v.instruction)
            // A task: each title starts with a verb from this list.
            let verb = v.title.split(separator: " ").first.map(String.init) ?? ""
            #expect(["Find", "Count", "Trace", "Pick", "Watch"].contains(verb), "\(v.title)")
        }
        #expect(eyes.contains { $0.title == "Find something green far away" })
    }

    @Test func walkIdeas() {
        #expect(BreakCopyLibrary.walkIdeas.count >= 4)
        #expect(Set(BreakCopyLibrary.walkIdeas).count == BreakCopyLibrary.walkIdeas.count)
        for idea in BreakCopyLibrary.walkIdeas {
            followsTheRules(idea)
            #expect(idea.split(separator: " ").count <= 6, "\(idea)")
            #expect(!idea.hasSuffix("."), "\(idea): a chip, not a sentence")
        }
    }

    @Test func namedBagsRotateWithoutImmediateRepeatsAndKeepKindBagsApart() {
        var generator = SeededGenerator(seed: 11)
        var state = RotationState.empty
        let count = BreakCopyLibrary.walkIdeas.count
        var drawn: [Int] = []
        for _ in 0..<(count * 10) {
            let draw = CopyRotation.draw(bag: BreakCopyLibrary.walkIdeaBag, count: count, state: state, using: &generator)
            drawn.append(draw.index)
            state = draw.state
        }
        for (a, b) in zip(drawn, drawn.dropFirst()) { #expect(a != b) }
        #expect(state.copyBags["walk"] == nil, "the walk's title bag is separate")
        let saved = try? JSONFile<RotationState>.decoder.decode(RotationState.self,
                                                                from: JSONFile<RotationState>.encoder.encode(state))
        #expect(saved?.copyBags[BreakCopyLibrary.walkIdeaBag] == state.copyBags[BreakCopyLibrary.walkIdeaBag])
    }
}
