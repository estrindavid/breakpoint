import Foundation
import Testing
@testable import BreakpointCore

@Suite("The one-minute tour: steps, skipping, interruptions, memory and words (SPEC §3.12)")
struct TourTests {
    let now = Fixture.date(14, 5)

    /// Applies `inputs` in order, failing on any that does not move the tour on.
    func run(_ state: TourState, _ inputs: [TourInput]) -> TourState {
        var state = state
        for input in inputs {
            guard case .moved(let next) = TourPolicy.apply(input, to: state) else {
                Issue.record("\(input) did not move the tour at \(state.step)")
                return state
            }
            state = next
        }
        return state
    }

    /// The tour at `step`, reached the way a user would reach it.
    func at(_ step: TourStep, origin: TourOrigin = .onboarding) -> TourState {
        let start = TourPolicy.start(origin, now: now)
        let path: [TourStep: [TourInput]] = [
            .offer: [], .mark: [.next], .nudge: [.next, .next], .declined: [.next, .next, .decline],
            .breakScreen: [.next, .next, .accept], .resumeCard: [.next, .next, .accept, .breakEnded],
            .popover: [.next, .next, .accept, .breakEnded, .next],
            .farewell: [.next, .next, .accept, .breakEnded, .next, .popoverClosed],
        ]
        var inputs = path[step]!
        if origin == .replay, !inputs.isEmpty { inputs.removeFirst() }
        return run(start, inputs)
    }

    // MARK: Steps

    @Test func onboardingOffersFirstAndAReplayStartsAtTheMark() {
        #expect(TourPolicy.start(.onboarding, now: now).step == .offer)
        let replay = TourPolicy.start(.replay, now: now)
        #expect(replay.step == .mark && replay.origin == .replay && replay.startedAt == now)
    }

    @Test func theWholeCycleInOrder() {
        var state = TourPolicy.start(.onboarding, now: now)
        var seen: [TourStep] = [state.step]
        for input: TourInput in [.next, .next, .decline, .next, .accept, .breakEnded, .cardDismissed, .next, .next, .next, .next] {
            guard case .moved(let next) = TourPolicy.apply(input, to: state) else {
                Issue.record("stuck at \(state.step) on \(input)")
                return
            }
            state = next
            if seen.last != state.step { seen.append(state.step) }
        }
        #expect(seen == [.offer, .mark, .nudge, .declined, .nudge, .breakScreen, .resumeCard, .popover, .farewell])
        #expect(state.declines == 1)
        #expect(TourPolicy.apply(.next, to: state) == .ended(.finished))
    }

    @Test func thePopoverNamesItsPartsOneAtATime() {
        var state = at(.popover)
        #expect(state.popoverPart == .status)
        var parts: [TourPopoverPart] = [state.popoverPart]
        while case .moved(let next) = TourPolicy.apply(.next, to: state), next.step == .popover {
            state = next
            parts.append(state.popoverPart)
        }
        #expect(parts == TourPopoverPart.allCases)
        guard case .moved(let last) = TourPolicy.apply(.next, to: state) else {
            Issue.record("Next on the last part did nothing")
            return
        }
        #expect(last.step == .farewell)
    }

    @Test func closingThePopoverMovesOnToTheLastCard() {
        var state = at(.popover)
        state = run(state, [.next])          // on "actions"
        guard case .moved(let next) = TourPolicy.apply(.popoverClosed, to: state) else {
            Issue.record("popover closed did nothing")
            return
        }
        #expect(next.step == .farewell)
        // The farewell closes the popover itself: that close means nothing more.
        #expect(TourPolicy.apply(.popoverClosed, to: next) == .ignored)
    }

    @Test func theResumeCardMovesOnByNextOrByClickingItAway() {
        for input: TourInput in [.next, .cardDismissed] {
            guard case .moved(let next) = TourPolicy.apply(input, to: at(.resumeCard)) else {
                Issue.record("\(input) did nothing on the resume card")
                continue
            }
            #expect(next.step == .popover && next.popoverPart == .status)
        }
    }

    // MARK: The user drives the pace

    @Test func nothingMovesPastAStepTheUserHasNotAnswered() {
        // The sample nudge waits for Start or Not now; Next does nothing there.
        #expect(TourPolicy.apply(.next, to: at(.nudge)) == .ignored)
        // The sample break only moves on when it ends.
        for input: TourInput in [.next, .accept, .decline, .cardDismissed, .popoverClosed] {
            #expect(TourPolicy.apply(input, to: at(.breakScreen)) == .ignored, "\(input)")
        }
        // Inputs that belong to other steps do nothing.
        #expect(TourPolicy.apply(.accept, to: at(.mark)) == .ignored)
        #expect(TourPolicy.apply(.accept, to: at(.declined)) == .ignored)
        #expect(TourPolicy.apply(.breakEnded, to: at(.nudge)) == .ignored)
        #expect(TourPolicy.apply(.popoverClosed, to: at(.mark)) == .ignored)
        #expect(TourPolicy.apply(.cardDismissed, to: at(.popover)) == .ignored)
    }

    // MARK: Skipping and interruptions

    @Test func skipEndsTheTourAtEveryStep() {
        #expect(TourPolicy.apply(.skip, to: at(.offer)) == .ended(.declined))
        for step in TourStep.allCases where step != .offer {
            #expect(TourPolicy.apply(.skip, to: at(step)) == .ended(.skipped), "\(step)")
        }
    }

    @Test func anyRealEventEndsTheTourAtEveryStep() {
        for step in TourStep.allCases {
            for reason in TourInterruption.allCases {
                #expect(TourPolicy.apply(.interrupted(reason), to: at(step)) == .ended(.interrupted(reason)), "\(step) \(reason)")
            }
        }
    }

    // MARK: Memory: offered once, never forced

    @Test func onlyANeverOfferedTourIsOfferedAfterOnboarding() {
        for status in TourStatus.allCases {
            #expect(TourPolicy.offersAfterOnboarding(status) == (status == .notOffered), "\(status)")
        }
    }

    @Test func whatIsRememberedAtEachMoment() {
        #expect(TourPolicy.status(during: at(.offer)) == .offered)
        for step in TourStep.allCases where step != .offer {
            #expect(TourPolicy.status(during: at(step)) == .started)
        }
        #expect(TourPolicy.status(after: .declined) == .declined)
        #expect(TourPolicy.status(after: .skipped) == .skipped)
        #expect(TourPolicy.status(after: .finished) == .finished)
        #expect(TourPolicy.status(after: .interrupted(.call)) == .interrupted)
        // Quit halfway (the status stays `started`) or interrupted: never offered again by itself.
        #expect(!TourPolicy.offersAfterOnboarding(.started))
        #expect(!TourPolicy.offersAfterOnboarding(.interrupted))
    }

    @Test func decliningTheOfferOpensThePopoverOnceAsOnboardingDidBefore() {
        #expect(TourPolicy.opensPopoverAfter(.declined, origin: .onboarding))
        #expect(!TourPolicy.opensPopoverAfter(.skipped, origin: .onboarding))
        #expect(!TourPolicy.opensPopoverAfter(.finished, origin: .onboarding))
        #expect(!TourPolicy.opensPopoverAfter(.declined, origin: .replay))
    }

    @Test func aReplayNeverStartsOverARealBreak() {
        #expect(TourPolicy.canReplay(realBreakShowing: false))
        #expect(!TourPolicy.canReplay(realBreakShowing: true))
    }

    @Test func theStatusIsSavedAndReadBack() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        let store = SettingsStore(paths: dir.paths)
        var settings = store.load()
        #expect(settings.tourStatus == .notOffered)
        settings.tourStatus = .finished
        try store.save(settings)
        #expect(SettingsStore(paths: dir.paths).load().tourStatus == .finished)
    }

    @Test func anUpdateFromAVersionWithoutTheTourNeverOffersIt() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        try dir.paths.ensureAppSupportDirectory()
        // A settings file written by 0.2.0: onboarding done, no tour key.
        try Data(#"{"version":1,"hasCompletedOnboarding":true,"preset":"balanced"}"#.utf8).write(to: dir.paths.settingsFile)
        let settings = SettingsStore(paths: dir.paths).load()
        #expect(settings.tourStatus == .notOffered)
        // Onboarding, the only door to the offer, is not shown again, so nothing offers the tour.
        #expect(settings.hasCompletedOnboarding)
        // A value from a newer version that this one does not know reads as never offered too,
        // which is still safe for the same reason.
        try Data(#"{"version":1,"hasCompletedOnboarding":true,"tourStatus":"somethingNew"}"#.utf8).write(to: dir.paths.settingsFile)
        #expect(SettingsStore(paths: dir.paths).load().tourStatus == .notOffered)
    }

    // MARK: Sample data

    @Test func theSampleIsAboutTheUsersOwnAgent() {
        #expect(TourPolicy.sampleAgent(connected: []) == "Claude")
        #expect(TourPolicy.sampleAgent(connected: [.codex, .claudeCode]) == "Codex")
        #expect(TourPolicy.sampleAgent(connected: [.shell, .gemini]) == "Gemini")
    }

    @Test func theSampleAgentFinishesDuringTheSampleBreak() {
        #expect(Timing.tourAgentFinishesAfter < Timing.tourBreakLength)
        // Skip is enabled before the agent finishes, so the user can see both moments or leave early.
        #expect(Timing.skipGuard < Timing.tourAgentFinishesAfter)
        #expect(TourPolicy.sampleAgentWorking(breakElapsed: 0))
        #expect(!TourPolicy.sampleAgentWorking(breakElapsed: Timing.tourAgentFinishesAfter))
        #expect(TourPolicy.sampleRunElapsed(breakElapsed: 3) == TourPolicy.sampleRunBeforeBreak + 3)
        let facts = TourPolicy.sampleResume(agent: "Claude")
        #expect(facts.headline == "Claude finished · ran 6 min")
        #expect(facts.detail?.plain == TourCopy.sampleAgentMessage)
        #expect(facts.folder == "my-app")
    }

    // MARK: Words

    @Test func everyCoachLineFollowsTheWordingRules() {
        let banned = ["should", "posture", "pain", "health", "healthy", "prevent", "prevents", "treat", "treats",
                      "strain", "fix", "fixes", "burnout", "stress", "streak", "score", "missed"]
        for line in TourCopy.allLines {
            #expect(!line.contains("!"), "\(line)")
            #expect(!line.lowercased().contains("look away"), "\(line)")
            let words = line.lowercased().split { !$0.isLetter }.map(String.init)
            for word in banned { #expect(!words.contains(word), "\(line) says \(word)") }
        }
        for step in TourStep.allCases {
            let coach = TourCopy.coach(step)
            if let title = coach.title { #expect(title.split(separator: " ").count <= 5, "\(title)") }
            // One or two short sentences.
            let sentences = coach.text.split { ".?".contains($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect(sentences.count <= 2, "\(coach.text)")
            #expect(coach.text.split(separator: " ").count <= 24, "\(coach.text)")
        }
        // Every step with no control of its own moves on by a button.
        for step in [TourStep.offer, .mark, .declined, .resumeCard, .popover, .farewell] {
            #expect(TourCopy.coach(step).primary != nil, "\(step)")
        }
        // The nudge and the break move on by their own controls only.
        #expect(TourCopy.coach(.nudge).primary == nil)
        #expect(TourCopy.coach(.breakScreen).primary == nil)
        #expect(TourCopy.coach(.offer).secondary == "Not now")
        #expect(TourCopy.coach(.farewell, agent: "Codex").text.contains("Codex"))
        // The sample nudge's buttons carry their keycaps when the hotkeys are on: the line names
        // them; with the hotkeys off it does not mention keys at all.
        #expect(TourCopy.coach(.nudge, hotkeys: true).text.contains("keys"))
        #expect(!TourCopy.coach(.nudge, hotkeys: false).text.contains("keys"))
    }

    @Test func progressCountsSixStepsAndNotNowSharesTheNudgesPlace() {
        #expect(TourStep.offer.progressIndex == nil)
        #expect(TourStep.declined.progressIndex == TourStep.nudge.progressIndex)
        let indices = TourStep.allCases.compactMap(\.progressIndex)
        #expect(Set(indices) == Set(1...TourStep.progressCount))
        #expect(TourCopy.progress(2, of: 6) == "Tour, step 2 of 6")
    }
}
