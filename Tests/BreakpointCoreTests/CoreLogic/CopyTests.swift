import Foundation
import Testing
@testable import BreakpointCore

@Suite("Copy (SPEC §3.11)")
struct CopyTests {
    func offer(_ kind: BreakKind, _ length: TimeInterval, _ opportunity: Opportunity, overdue: TimeInterval = 0,
               timer: TimeInterval = 0, run: TimeInterval? = nil) -> BreakOffer {
        BreakOffer(kind: kind, length: length, opportunity: opportunity, overdueBy: overdue, timerValue: timer,
                   expectedRunLength: run)
    }

    @Test func nudgeTitlesStateKindAndLength() {
        #expect(Copy.nudgeTitle(kind: .eyes, length: 20) == "20-sec eye rest?")
        #expect(Copy.nudgeTitle(kind: .move, length: 120) == "2-min stretch?")
        #expect(Copy.nudgeTitle(kind: .walk, length: 360) == "6-min walk?")
        #expect(Copy.nudgeTitle(kind: .breathe, length: 60) == "1-min breather?")
        #expect(Copy.autoStartTitle(kind: .eyes, length: 20, remaining: 9.2) == "20-sec eye rest in 10")
        #expect(Copy.countdownChip(kind: .eyes, remaining: 5) == "Eye rest in 5")
    }

    @Test func nudgeSubtitlesAndWhyNow() {
        let now = Fixture.date(14)
        let agent = Opportunity(kind: .agentStarted, source: .claudeCode, sessionID: "a", createdAt: now)
        let command = Opportunity(kind: .longCommand, source: .shell, sessionID: "12", commandName: "swift", createdAt: now)
        let typing = Opportunity(kind: .typingPause, createdAt: now)
        #expect(Copy.nudgeSubtitle(for: offer(.move, 120, agent)) == "Claude is working")
        #expect(Copy.nudgeSubtitle(for: offer(.move, 120, command)) == "swift is running")
        #expect(Copy.nudgeSubtitle(for: offer(.eyes, 20, typing, timer: 52 * 60)) == "52 min at the screen")
        #expect(Copy.whyNow(for: offer(.move, 120, agent, overdue: 18 * 60, run: 4 * 60))
                == "18 min overdue · Claude usually takes 4 min")
        #expect(Copy.whyNow(for: offer(.eyes, 20, typing)) == "Due now")
        #expect(Copy.nudgeSubtitle(for: offer(.move, 120, typing, timer: 55 * 60)) == "55 min since you moved")
        #expect(Copy.nudgeAnnouncement(kind: .move, length: 120, hotkeysOn: true)
                == "Break offer: 2-minute stretch. Control-Option-Command-B to start.")
    }

    @Test func pauseSentencesNameTheSignal() {
        let now = Fixture.date(14)
        #expect(Copy.pauseSentence(.call(.microphone), now: now) == "Paused: microphone is on")
        #expect(Copy.pauseSentence(.call(.camera), now: now) == "Paused: camera is on")
        #expect(Copy.pauseSentence(.call([.microphone, .camera]), now: now) == "Paused: microphone and camera are on")
        #expect(Copy.pauseSentence(.manual(until: Fixture.date(15, 30)), now: now, locale: Fixture.posix,
                                   timeZone: Fixture.utc) == "Paused until 15:30")
        #expect(Copy.pauseSentence(.manual(until: Fixture.date(5, day: 23)), now: now) == "Paused until tomorrow")
        #expect(Copy.callPauseToast(.microphone) == "Breaks paused: microphone is on")
    }

    @Test func decisionsAndAgents() {
        #expect(Copy.creditedAway(duration: 6 * 60) == "Counted your 6 min away as a break")
        #expect(Copy.timersReset(duration: 4 * 60) == "Reset timers after 4 min away")
        let decision = AutoDecision(kind: .creditedAway([.eyes, .move], duration: 6 * 60), madeAt: Fixture.date(14),
                                    sentence: "x", previous: .zero)
        #expect(Copy.decisionLine(decision) == "Counted 6 min away as a break")
        #expect(Copy.chipWorking(agent: "Claude", elapsed: 102) == "Claude is still working · 1:42")
        #expect(Copy.chipDone(agent: "Claude") == "Claude is done. No rush.")
        #expect(Copy.resumeTitle(agent: "Claude", ending: .finished(duration: 6 * 60)) == "Claude finished · ran 6 min")
        #expect(Copy.resumeTitle(agent: "Claude", ending: .failed) == "Claude stopped with an error")
        #expect(Copy.resumeTitle(agent: "Claude", ending: .cancelled) == nil)
        #expect(Copy.menuBarCountdown(0) == "due")
        #expect(Copy.menuBarCountdown(5 * 60 + 10) == "6m")
        #expect(Copy.menuBarAgent("Claude", elapsed: 200) == "Claude 3m")
    }

    @Test func windDown() {
        #expect(Copy.windDownTitle(now: Fixture.date(23, 20), locale: Fixture.posix, timeZone: Fixture.utc) == "It's 23:20.")
        #expect(Copy.windDownBody(stopTime: TimeOfDay(hour: 23, minute: 0), on: Fixture.date(23, 20), locale: Fixture.posix,
                                  timeZone: Fixture.utc) == "You planned to stop at 23:00.")
        #expect(Copy.windDownHold(6) == "Hold 6 s")
        #expect(Copy.wrapUpLine(folder: "breakpoint", snippet: "fix the login redirect") == "breakpoint — fix the login redirect")
    }

    @Test func allBreakCopyFollowsTheWordingRules() {
        for kind in BreakKind.allCases {
            let copy = BreakCopyLibrary.copy(for: kind)
            #expect((4...6).contains(copy.variants.count), "\(kind) has \(copy.variants.count) variants")
            for v in copy.variants {
                for text in [v.title, v.instruction] {
                    #expect(!text.contains("!"))
                    let words = text.lowercased().split { !$0.isLetter }
                    #expect(!words.contains("should"))
                    #expect(!text.lowercased().contains("look away"))
                }
                #expect(v.instruction.split(separator: " ").count <= 12, "\(v.instruction)")
            }
        }
        let walk = BreakCopyLibrary.variant(for: .walk, rotation: 0, agentName: "Claude")
        #expect(walk.instruction == "We'll chime when Claude needs you.")
        #expect(BreakCopyLibrary.variant(for: .walk, rotation: 2, agentName: nil).instruction == "Come back whenever you're ready.")
        // Once the agent needs you, the walk no longer promises a chime: it has sounded.
        let needsYou = Copy.walkNeedsYouInstruction(agent: "Claude")
        #expect(needsYou == "Claude needs you. Head back when you're ready.")
        #expect(!needsYou.contains("chime") && !needsYou.contains("!") && needsYou.split(separator: " ").count <= 12)
    }
}
