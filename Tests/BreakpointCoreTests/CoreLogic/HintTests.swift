import Foundation
import Testing
@testable import BreakpointCore

@Suite("First-use hints, alone and after the tour (SPEC §3.12)")
struct HintTests {
    let now = Fixture.date(14, 5)

    /// Someone who has just finished onboarding on this version.
    func newUser() -> Settings {
        var s = Settings()
        s.hasCompletedOnboarding = true
        return s
    }

    func shows(_ lesson: HintLesson, _ settings: Settings, _ context: HintPolicy.Context = .init()) -> Bool {
        HintPolicy.shows(lesson, settings: settings, context: context)
    }

    /// Plays the tour with `inputs` as the coordinator does: the status at each step, and what the
    /// user answered marked as taught when the tour moves on.
    func tour(_ inputs: [TourInput], origin: TourOrigin = .onboarding, from settings: Settings) -> Settings {
        var s = settings
        var state = TourPolicy.start(origin, now: now)
        s.tourStatus = TourPolicy.status(during: state)
        for input in inputs {
            switch TourPolicy.apply(input, to: state) {
            case .moved(let next):
                if next.step != state.step {
                    s.tourStatus = TourPolicy.status(during: next)
                    s = HintPolicy.markingTaught(HintPolicy.taught(leaving: state.step, for: next.step), in: s)
                }
                state = next
            case .ended(let ending):
                s.tourStatus = TourPolicy.status(after: ending)
                return s
            case .ignored:
                Issue.record("\(input) did nothing at \(state.step)")
            }
        }
        return s
    }

    static let wholeTour: [TourInput] = [.next, .next, .accept, .breakEnded, .next, .next, .next, .next, .next, .next]

    // MARK: Alone

    @Test func eachSurfaceCarriesOneHintOnce() {
        var s = newUser()
        for surface in HintSurface.allCases {
            let lessons = HintLesson.allCases.filter { $0.surface == surface }
            #expect(lessons.allSatisfy { shows($0, s) }, "\(surface)")
            s = HintPolicy.markingShown(lessons[0], in: s)
            // Showing one of a surface's lessons settles the surface: never a second hint on it.
            #expect(lessons.allSatisfy { !shows($0, s) }, "\(surface)")
        }
        #expect(HintPolicy.pending(s).isEmpty)
        #expect(HintPolicy.markingShown(.nudge, in: s) == s)
    }

    @Test func eachSurfacePicksTheLessonForWhatItIs() {
        #expect(HintPolicy.nudgeLesson(autoStart: false) == .nudge)
        #expect(HintPolicy.nudgeLesson(autoStart: true) == .autoStart)
        #expect(HintPolicy.resumeLesson(needsYou: false) == .resumeCard)
        #expect(HintPolicy.resumeLesson(needsYou: true) == .resumeNeedsYou)
        #expect(Set(HintLesson.allCases.map(\.surface)) == Set(HintSurface.allCases))
    }

    @Test func neverStackedNeverOnASampleOrPreviewNeverDuringTheTourOrOnboarding() {
        let s = newUser()
        #expect(!shows(.nudge, s, .init(hintOnScreen: true)))
        #expect(!shows(.breakScreen, s, .init(isPreview: true)))
        #expect(!shows(.resumeCard, s, .init(tourRunning: true)))
        #expect(!shows(.popover, s, .init(onboardingOpen: true)))
        var setup = s
        setup.hasCompletedOnboarding = false
        #expect(HintLesson.allCases.allSatisfy { !shows($0, setup) })
    }

    @Test func showHintsOffShowsNone() {
        var off = newUser()
        off.showHints = false
        #expect(HintLesson.allCases.allSatisfy { !shows($0, off) })
    }

    @Test func theCallPauseToastAppearsOnceMoreToCarryItsHint() {
        #expect(!HintPolicy.showsCallPauseToast(nudgeWasVisible: false, breakDue: false, hintShows: false))
        #expect(HintPolicy.showsCallPauseToast(nudgeWasVisible: false, breakDue: false, hintShows: true))
        #expect(HintPolicy.showsCallPauseToast(nudgeWasVisible: true, breakDue: false, hintShows: false))
        #expect(HintPolicy.showsCallPauseToast(nudgeWasVisible: false, breakDue: true, hintShows: false))
    }

    // MARK: With the tour

    @Test func theTourTeachesWhatTheUserAnsweredAndNothingElse() {
        #expect(HintPolicy.taught(leaving: .nudge, for: .breakScreen) == [.nudge])
        #expect(HintPolicy.taught(leaving: .nudge, for: .declined) == [.nudge])
        #expect(HintPolicy.taught(leaving: .breakScreen, for: .resumeCard) == [.breakScreen])
        #expect(HintPolicy.taught(leaving: .resumeCard, for: .popover) == [.resumeCard])
        for step in [TourStep.offer, .mark, .declined, .popover, .farewell] {
            for next in TourStep.allCases where next != step {
                #expect(HintPolicy.taught(leaving: step, for: next).isEmpty, "\(step) → \(next)")
            }
        }
        // Moving between the popover's parts, or staying put, teaches nothing.
        #expect(HintPolicy.taught(leaving: .nudge, for: .nudge).isEmpty)
    }

    @Test func afterTheWholeTourOnlyWhatItCouldNotTeachIsLeft() {
        let s = tour(Self.wholeTour, from: newUser())
        #expect(s.tourStatus == .finished)
        // Taught: the ordinary nudge, the break screen, the resume card that goes by itself.
        #expect(!shows(.nudge, s))
        #expect(!shows(.breakScreen, s))
        #expect(!shows(.resumeCard, s))
        // Not taught: the sample never starts by itself, is never a needs-you card, and the tour
        // does not show Option-click or a call.
        #expect(shows(.autoStart, s))
        #expect(shows(.resumeNeedsYou, s))
        #expect(shows(.popover, s))
        #expect(shows(.callPause, s))
        #expect(HintPolicy.pending(s) == [.autoStart, .resumeNeedsYou, .popover, .callPause])
    }

    @Test func declinedOrSkippedBeforeAnsweringAnythingLeavesEveryHint() {
        let declined = tour([.skip], from: newUser())
        #expect(declined.tourStatus == .declined)
        #expect(HintPolicy.pending(declined) == HintLesson.allCases)
        // Skipped while the sample nudge waited: Start or Not now was never pressed.
        let skipped = tour([.next, .next, .skip], from: newUser())
        #expect(skipped.tourStatus == .skipped)
        #expect(HintPolicy.pending(skipped) == HintLesson.allCases)
    }

    @Test func interruptedHalfwayKeepsWhatWasAlreadyTaught() {
        // A call starts during the sample break: the nudge was answered, the break never ended.
        let s = tour([.next, .next, .accept, .interrupted(.call)], from: newUser())
        #expect(s.tourStatus == .interrupted)
        #expect(!shows(.nudge, s))
        #expect(shows(.breakScreen, s))
        #expect(shows(.resumeCard, s))
        // Not now on the sample nudge teaches the nudge too.
        let declinedNudge = tour([.next, .next, .decline, .skip], from: newUser())
        #expect(!shows(.nudge, declinedNudge) && shows(.breakScreen, declinedNudge))
    }

    @Test func aReplayChangesNothingTheHintsAlreadyDid() {
        var s = newUser()
        s = HintPolicy.markingShown(.autoStart, in: s)
        s = HintPolicy.markingShown(.breakScreen, in: s)
        let replayed = tour(Array(Self.wholeTour.dropFirst()), origin: .replay, from: s)
        #expect(replayed.tourStatus == .finished)
        #expect(HintPolicy.pending(replayed) == [.resumeNeedsYou, .popover, .callPause])
    }

    @Test func theTourTeachesEvenWithHintsOffSoTurningThemOnLaterNeverRepeatsIt() {
        var off = newUser()
        off.showHints = false
        var s = tour(Self.wholeTour, from: off)
        #expect(HintLesson.allCases.allSatisfy { !shows($0, s) })
        s.showHints = true
        #expect(!shows(.breakScreen, s))
        #expect(shows(.callPause, s))
    }

    // MARK: Upgrades and memory

    @Test func anUpdateFromAVersionWithoutEitherBringsNoTourAndNoHints() throws {
        // settings.json as 0.2.0 wrote it, for someone who finished onboarding.
        let old = Data(#"{"version":1,"hasCompletedOnboarding":true,"eyesEveryMinutes":25}"#.utf8)
        let decoded = try JSONFile<Settings>.decoder.decode(Settings.self, from: old)
        #expect(decoded.showHints == false)
        #expect(decoded.hintsSeen.isEmpty)
        #expect(decoded.tourStatus == .notOffered)
        #expect(HintLesson.allCases.allSatisfy { !shows($0, decoded) })
        // Onboarding is the only door to the offer, and it is done.
        #expect(decoded.hasCompletedOnboarding)
        // Turning Show hints on is asking for them: each surface then shows one, once.
        var asked = decoded
        asked.showHints = true
        #expect(HintLesson.allCases.allSatisfy { shows($0, asked) })
    }

    @Test func aFreshInstallAndOneStillInOnboardingGetHints() throws {
        #expect(Settings.defaults.showHints)
        let midOnboarding = Data(#"{"version":1,"hasCompletedOnboarding":false,"preset":"gentle"}"#.utf8)
        #expect(try JSONFile<Settings>.decoder.decode(Settings.self, from: midOnboarding).showHints)
    }

    @Test func knownLessonsSurviveASaveAndUnknownOnesAreSkipped() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let store = SettingsStore(paths: dir.paths)
        var s = newUser()
        s = HintPolicy.markingShown(.popover, in: s)
        s = HintPolicy.markingTaught([.nudge], in: s)
        try store.save(s)
        let loaded = store.load()
        #expect(loaded.showHints)
        #expect(loaded.hintsSeen == [.nudge, .popover])
        let newer = Data(#"{"version":1,"hasCompletedOnboarding":true,"showHints":true,"hintsSeen":["nudge","someFutureHint"]}"#.utf8)
        #expect(try JSONFile<Settings>.decoder.decode(Settings.self, from: newer).hintsSeen == [.nudge])
    }

    // MARK: Words

    @Test func everyHintFollowsTheWordingRules() {
        let banned = ["should", "posture", "pain", "health", "healthy", "prevent", "prevents", "treat", "treats",
                      "strain", "fix", "fixes", "burnout", "stress", "streak", "score", "missed"]
        for line in HintCopy.allLines {
            #expect(!line.contains("!"), "\(line)")
            #expect(!line.lowercased().contains("look away"), "\(line)")
            let words = line.lowercased().split { !$0.isLetter }.map(String.init)
            for word in banned { #expect(!words.contains(word), "\(line) says \(word)") }
            // One short line.
            #expect(line.split(separator: " ").count <= 14, "\(line)")
        }
        #expect(HintCopy.resumeNeedsYou(dismissKey: "⌃⌥⌘.") == "It stays until you press ⌃⌥⌘. or click it.")
        #expect(HintCopy.breakChip(agent: "Codex").contains("Codex"))
        #expect(HintCopy.nudge(.autoStart) == HintCopy.autoStart)
    }
}
