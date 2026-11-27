import Foundation
import Testing
@testable import BreakpointCore

@Suite("CardCountdown (SPEC §3.0 Auto-hide, §3.5 time rim)")
struct CardCountdownTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let full = Timing.cardAutoHide

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func runsFromFullToZero() {
        let countdown = CardCountdown(full: full, start: start)
        #expect(countdown.fraction(at: start) == 1)
        #expect(abs(countdown.fraction(at: at(full * 0.25)) - 0.75) < 1e-9)
        #expect(countdown.remaining(at: at(full + 5)) == 0)
        #expect(countdown.fraction(at: at(full + 5)) == 0)
        #expect(countdown.deadline == at(full))
        #expect(!countdown.isExpired(at: at(full - 0.01)))
        #expect(countdown.isExpired(at: at(full)))
        // A date before the start never adds time.
        #expect(countdown.remaining(at: at(-3)) == full)
    }

    @Test func holdingFreezesWhatIsLeft() {
        let held = CardCountdown(full: full, start: start).held(at: at(3))
        #expect(held.isHeld)
        #expect(held.deadline == nil)
        #expect(held.remaining(at: at(3)) == full - 3)
        #expect(held.remaining(at: at(300)) == full - 3)
        #expect(!held.isExpired(at: at(300)))
        #expect(held.held(at: at(9)) == held)
    }

    @Test func resumingKeepsWhatWasLeftWhenThatIsMoreThanTheFloor() {
        // Hovered after 2 s (8 s left): leaving must not cut it to 5 s.
        let resumed = CardCountdown(full: full, start: start).held(at: at(2)).resumed(at: at(20))
        #expect(!resumed.isHeld)
        #expect(resumed.remaining(at: at(20)) == full - 2)
        #expect(resumed.deadline == at(20 + full - 2))
    }

    @Test func resumingTopsUpToTheFloor() {
        // Hovered with 1 s left: leaving gives back half the full time.
        let resumed = CardCountdown(full: full, start: start).held(at: at(9)).resumed(at: at(12))
        let floor = full * Timing.cardHoverResumeFloor
        #expect(resumed.remaining(at: at(12)) == floor)
        #expect(resumed.fraction(at: at(12)) == Timing.cardHoverResumeFloor)
        #expect(resumed.deadline == at(12 + floor))
    }

    @Test func resumingARunningCountdownChangesNothing() {
        let countdown = CardCountdown(full: full, start: start)
        #expect(countdown.resumed(at: at(4)) == countdown)
    }

    @Test func toastsUseTheSameRules() {
        let toast = CardCountdown(full: Timing.toastAutoHide, start: start)
        let resumed = toast.held(at: at(2.5)).resumed(at: at(4))
        #expect(resumed.remaining(at: at(4)) == Timing.toastAutoHide * Timing.cardHoverResumeFloor)
    }

    @Test func clampsOddInputs() {
        let zero = CardCountdown(full: 0, start: start)
        #expect(zero.fraction(at: start) == 0)
        #expect(zero.isExpired(at: start))
        let over = CardCountdown(full: 3, remaining: 9, runningSince: nil)
        #expect(over.remaining(at: start) == 3)
        let negative = CardCountdown(full: 3, remaining: -1, runningSince: start)
        #expect(negative.remaining(at: start) == 0)
    }
}
