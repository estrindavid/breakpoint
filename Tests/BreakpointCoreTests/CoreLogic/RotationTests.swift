import Foundation
import Testing
@testable import BreakpointCore

/// A seeded generator so shuffle-bag tests are repeatable.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        return z ^ (z >> 33)
    }
}

@Suite("Routine rotation (SPEC §2.2)")
struct RoutineRotationTests {
    /// The routine ids of `count` successive stretch breaks.
    func sequence(_ settings: Settings, count: Int, from state: RotationState = .empty) -> (ids: [String], state: RotationState) {
        var state = state
        var ids: [String] = []
        for _ in 0..<count {
            let routine = RoutineRotation.next(for: settings, state: state)
            ids.append(routine.id)
            state = RoutineRotation.started(routine.id, in: state)
        }
        return (ids, state)
    }

    @Test func everyAllowedRoutineBeforeAnyRepeat() {
        let settings = Settings()
        let allowed = BuiltInRoutines.allowed(for: settings).map(\.id)
        let (ids, _) = sequence(settings, count: allowed.count * 3)
        // The first round is the library in order; later rounds repeat it (least recently done).
        #expect(Array(ids.prefix(allowed.count)) == allowed)
        #expect(ids == Array(repeating: allowed, count: 3).flatMap { $0 })
    }

    @Test func neverTheSameTwiceInARow() {
        var settings = Settings()
        settings.hasBand = true
        let (ids, _) = sequence(settings, count: 60)
        for (a, b) in zip(ids, ids.dropFirst()) { #expect(a != b) }

        // Two allowed: they alternate.
        settings = Settings()
        settings.excludedRoutines = BuiltInRoutines.all.map(\.id).filter { !["upper-back", "seated-legs"].contains($0) }
        #expect(sequence(settings, count: 5).ids == ["upper-back", "seated-legs", "upper-back", "seated-legs", "upper-back"])

        // One allowed: it repeats (there is nothing else).
        settings.setRoutine("seated-legs", excluded: true)
        #expect(Set(sequence(settings, count: 3).ids) == ["upper-back"])
    }

    @Test func excludedNeverAppears() {
        var settings = Settings()
        settings.setRoutine("wrists-and-forearms", excluded: true)
        settings.setRoutine("chest-opener", excluded: true)
        let (ids, _) = sequence(settings, count: 40)
        #expect(!ids.contains("wrists-and-forearms"))
        #expect(!ids.contains("chest-opener"))
        #expect(Set(ids).count == BuiltInRoutines.allowed(for: settings).count)
    }

    @Test func bandRoutinesOnlyWithABand() {
        var settings = Settings()
        #expect(!sequence(settings, count: 30).ids.contains { $0.hasPrefix("band") })
        settings.hasBand = true
        let ids = sequence(settings, count: 30).ids
        #expect(ids.contains("band-raises") && ids.contains("band-pull-aparts"))
    }

    @Test func aRoutineThatDisappearedIsForgotten() {
        // The rotation remembers an id that is no longer allowed: nothing breaks.
        var state = RotationState.empty
        state = RoutineRotation.started("retired-routine", in: state)
        let next = RoutineRotation.next(for: Settings(), state: state)
        #expect(next.id == "neck-and-shoulders")
    }

    @Test func rotationSurvivesARelaunch() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let settings = Settings()
        let (first, state) = sequence(settings, count: 3)
        try RotationState.file(dir.paths).write(state)
        let reloaded = RotationState.load(dir.paths)
        #expect(reloaded == state)
        let (after, _) = sequence(settings, count: 1, from: reloaded)
        #expect(!first.contains(after[0]))
        #expect(dir.paths.rotationFile.lastPathComponent == "rotation.json")
    }

    @Test func aDamagedFileStartsAfresh() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        try dir.paths.ensureAppSupportDirectory()
        try Data("not json".utf8).write(to: dir.paths.rotationFile)
        #expect(RotationState.load(dir.paths) == .empty)
        try Data(#"{"stretchesStarted": "x", "lastRoutineID": "upper-back"}"#.utf8).write(to: dir.paths.rotationFile)
        let partial = RotationState.load(dir.paths)
        #expect(partial.stretchesStarted == 0 && partial.lastRoutineID == "upper-back")
    }
}

@Suite("Copy rotation (SPEC §2.2)")
struct CopyRotationTests {
    @Test func aShuffleBagWithNoImmediateRepeats() {
        var generator = SeededGenerator(seed: 7)
        var state = RotationState.empty
        let count = BreakCopyLibrary.eyes.variants.count
        var drawn: [Int] = []
        for _ in 0..<(count * 20) {
            let draw = CopyRotation.draw(.eyes, count: count, state: state, using: &generator)
            drawn.append(draw.index)
            state = draw.state
        }
        for (a, b) in zip(drawn, drawn.dropFirst()) { #expect(a != b) }
        // Each round of `count` draws uses every variant once.
        for round in stride(from: 0, to: drawn.count, by: count) {
            #expect(Set(drawn[round..<round + count]) == Set(0..<count))
        }
    }

    @Test func oneBagPerKind() {
        var generator = SeededGenerator(seed: 3)
        var state = RotationState.empty
        let eyes = CopyRotation.draw(.eyes, count: 5, state: state, using: &generator)
        state = eyes.state
        let walk = CopyRotation.draw(.walk, count: 4, state: state, using: &generator)
        state = walk.state
        #expect(state.copyBags["eyes"]?.remaining.count == 4)
        #expect(state.copyBags["walk"]?.remaining.count == 3)
        #expect(state.copyBags["eyes"]?.last == eyes.index)
    }

    @Test func theFirstEyeRestAfterALaunchVaries() {
        // A fresh state (first launch) draws at random, not always variant 0.
        var firsts = Set<Int>()
        for seed in 0..<40 {
            var generator = SeededGenerator(seed: UInt64(seed))
            firsts.insert(CopyRotation.draw(.eyes, count: 5, state: .empty, using: &generator).index)
        }
        #expect(firsts.count > 1)
    }

    @Test func survivesARelaunchWithoutRepeating() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        var generator = SeededGenerator(seed: 11)
        let count = 5
        var state = RotationState.empty
        for _ in 0..<count {
            state = CopyRotation.draw(.eyes, count: count, state: state, using: &generator).state
        }
        let last = state.copyBags["eyes"]?.last
        try RotationState.file(dir.paths).write(state)
        // A new round after a relaunch never starts with the variant drawn last before it.
        for seed in 0..<30 {
            var g = SeededGenerator(seed: UInt64(seed))
            #expect(CopyRotation.draw(.eyes, count: count, state: RotationState.load(dir.paths), using: &g).index != last)
        }
    }

    @Test func aShorterVariantListIsHandled() {
        var generator = SeededGenerator(seed: 1)
        let state = RotationState(copyBags: ["eyes": CopyBag(remaining: [4, 7], last: 9)])
        let draw = CopyRotation.draw(.eyes, count: 3, state: state, using: &generator)
        #expect((0..<3).contains(draw.index))
        #expect(CopyRotation.draw(.eyes, count: 0, state: state, using: &generator).index == 0)
    }
}

@Suite("1 more minute replays the routine (SPEC §3.3)")
struct RoutineReplayTests {
    let now = Fixture.date(14)

    @Test func theExtraMinuteReplaysTheRoutinesOwnSteps() {
        let routine = BuiltInRoutines.neckAndShoulders
        let first = RoutineReplay.extraMinute(for: routine, plannedLength: 120, extension: 1)
        #expect(first.map(\.title) == ["Shoulder-blade squeeze", "Arms up the wall"])
        #expect(first.map(\.duration) == [30, 30])
        #expect(first.reduce(0) { $0 + $1.duration } == Timing.extensionLength)
        // The second minute continues where the first stopped.
        let once = routine.appending(first)
        let second = RoutineReplay.extraMinute(for: once, plannedLength: 120, extension: 2)
        #expect(second.map(\.title) == ["Slow shoulder rolls", "Gentle neck side-bend"])
        #expect(second.map(\.duration) == [24, 36])
    }

    @Test func extendingAStretchAddsAMinuteOfTheSameRoutine() {
        let settings = Settings()
        var session = BreakSessionRules.makeSession(kind: .move, opportunity: nil, settings: settings, expectedRun: nil,
                                                    agentName: nil, copyRotation: 0, now: now,
                                                    routine: BuiltInRoutines.wristsAndForearms)
        #expect(session.routine?.id == "wrists-and-forearms")
        session = BreakSessionRules.extended(session)
        session = BreakSessionRules.extended(session)
        let steps = session.routine?.steps ?? []
        #expect(session.routine?.totalDuration == session.totalLength)
        #expect(!steps.contains { $0.title == "Keep moving" })
        let originalTitles = Set(BuiltInRoutines.wristsAndForearms.steps.map(\.title))
        #expect(steps.allSatisfy { originalTitles.contains($0.title) })
        #expect(Set(steps.map(\.id)).count == steps.count)
    }

    @Test func shortLeftoversJoinTheLastStep() {
        let routine = Routine(id: "r", name: "R", steps: [
            RoutineStep(id: "a", title: "A", instruction: "A.", cue: "a", duration: 55),
            RoutineStep(id: "b", title: "B", instruction: "B.", cue: "b", duration: 65),
        ])
        let replay = RoutineReplay.extraMinute(for: routine, plannedLength: 120, extension: 1)
        #expect(replay.map(\.duration) == [60])
        let long = Routine(id: "l", name: "L", steps: [
            RoutineStep(id: "a", title: "A", instruction: "A.", cue: "a", duration: 120),
        ])
        #expect(RoutineReplay.extraMinute(for: long, plannedLength: 120, extension: 1).map(\.duration) == [60])
        #expect(RoutineReplay.extraMinute(for: Routine(id: "e", name: "E", steps: []), plannedLength: 0, extension: 1).isEmpty)
    }
}

@Suite("Routine settings and model (SPEC §3.9)")
struct RoutineSettingsTests {
    @Test func excludeRoundTrip() throws {
        var s = Settings()
        s.setRoutine("upper-back", excluded: true)
        s.setRoutine("upper-back", excluded: true)
        #expect(s.excludedRoutines == ["upper-back"])
        s.setRoutine("upper-back", excluded: false)
        #expect(s.excludedRoutines.isEmpty)
        s.excludedRoutines = ["b", "a", "b"]
        #expect(s.normalized().excludedRoutines == ["a", "b"])
        #expect(try Fixture.jsonRoundTrip(s) == s)
        // An older file without the key loads with nothing left out.
        let old = try JSONFile<Settings>.decoder.decode(Settings.self, from: Data(#"{"version":1,"hasBand":true}"#.utf8))
        #expect(old.excludedRoutines.isEmpty && old.hasBand)
    }

    @Test func routinesAreCodableAndTolerant() throws {
        for routine in BuiltInRoutines.all {
            #expect(try Fixture.jsonRoundTrip(routine) == routine)
        }
        // A routine written by hand without summary, equipment, cue or tempo still loads.
        let json = #"{"id":"x","name":"X","steps":[{"id":"s","title":"S","instruction":"Do it.","duration":30}]}"#
        let routine = try JSONFile<Routine>.decoder.decode(Routine.self, from: Data(json.utf8))
        #expect(routine.equipment == .none && routine.summary.isEmpty && routine.steps[0].tempo.isEmpty)
    }
}
