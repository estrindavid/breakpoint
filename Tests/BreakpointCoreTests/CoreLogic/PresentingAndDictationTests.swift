import Foundation
import Testing
@testable import BreakpointCore

/// The presenting guard, scrolling during an eye-rest countdown, and a short use of the
/// microphone that is not a call (SPEC §2.4, §3.1).
@Suite("Presenting, reading and dictation")
struct PresentingAndDictationTests {
    let now = Fixture.date(14)

    @Test func theGuardNamesItsCauseAndAMirroredDisplayWins() {
        var sample = InputSample.quiet(at: now)
        #expect(sample.presentingCause == nil)
        sample.displaySleepPrevented = true
        #expect(sample.presentingCause == .displayKeptAwake)
        sample.displayMirrored = true
        #expect(sample.presentingCause == .displayMirrored)
        #expect(PresentingCause.displayKeptAwake.phrase == "the display is kept awake")
        #expect(PresentingCause.displayMirrored.phrase == "a display is mirrored")
    }

    @Test func autoStartWaitsForNoGuardAndNoMicrophone() {
        var sample = InputSample.quiet(at: now)
        #expect(AutoStartRules.allows(sample, microphonePending: false))
        #expect(!AutoStartRules.allows(sample, microphonePending: true))
        sample.displaySleepPrevented = true
        #expect(!AutoStartRules.allows(sample, microphonePending: false))
    }

    @Test func aKeyAClickOrAScrollSinceTheCountdownBeganCancelsIt() {
        let quiet = InputSample(takenAt: now, secondsSinceKey: 30, secondsSinceAnyInput: 0, secondsSinceDrag: 30,
                                secondsSinceScroll: 30)
        #expect(!AutoStartRules.cancels(quiet, runningFor: 4, microphonePending: false))
        var scrolled = quiet
        scrolled.secondsSinceScroll = 1
        #expect(AutoStartRules.cancels(scrolled, runningFor: 4, microphonePending: false))
        #expect(!AutoStartRules.cancels(scrolled, runningFor: 0.5, microphonePending: false))   // before it began
        var key = quiet
        key.secondsSinceKey = 2
        #expect(AutoStartRules.cancels(key, runningFor: 4, microphonePending: false))
        var click = quiet
        click.secondsSinceDrag = 3
        #expect(AutoStartRules.cancels(click, runningFor: 4, microphonePending: false))
        var mirrored = quiet
        mirrored.displayMirrored = true
        #expect(AutoStartRules.cancels(mirrored, runningFor: 4, microphonePending: false))
        #expect(AutoStartRules.cancels(quiet, runningFor: 4, microphonePending: true))
    }

    @Test func theMicrophoneCountsAsACallOnlyAfterItsThreshold() {
        var gate = MicrophoneCallGate()
        #expect(gate.counted(.microphone, at: now) == [])           // never observed
        gate.observe(.microphone, at: now)
        #expect(gate.counted(.microphone, at: now) == [])
        #expect(gate.isPending(.microphone, at: now))
        let justBefore = now.plus(seconds: Timing.microphoneCallAfter - 1)
        gate.observe(.microphone, at: justBefore)
        #expect(gate.counted(.microphone, at: justBefore) == [])
        let at = now.plus(seconds: Timing.microphoneCallAfter)
        gate.observe(.microphone, at: at)
        #expect(gate.counted(.microphone, at: at) == .microphone)
        #expect(!gate.isPending(.microphone, at: at))
        #expect(gate.microphoneOnFor(at: at) == Timing.microphoneCallAfter)
        // Off for a moment: the count starts again.
        gate.observe([], at: at.plus(seconds: 1))
        #expect(gate.microphoneOnFor(at: at.plus(seconds: 1)) == 0)
        gate.observe(.microphone, at: at.plus(seconds: 2))
        #expect(gate.counted(.microphone, at: at.plus(seconds: 2)) == [])
    }

    @Test func theCameraCountsAtOnce() {
        var gate = MicrophoneCallGate()
        gate.observe([.microphone, .camera], at: now)
        #expect(gate.counted([.microphone, .camera], at: now) == .camera)
        #expect(gate.counted(.camera, at: now) == .camera)
        #expect(!gate.isPending([], at: now))
    }

    @Test func aShortUseLeavesNoPauseAndNoCoolDown() {
        var gate = MicrophoneCallGate()
        var pause = PauseState.none
        for second in 0..<20 {
            let t = now.plus(seconds: TimeInterval(second))
            gate.observe(.microphone, at: t)
            pause = PausePolicy.update(pause, callSignals: gate.counted(.microphone, at: t), settings: .defaults, now: t)
        }
        let end = now.plus(seconds: 20)
        gate.observe([], at: end)
        pause = PausePolicy.update(pause, callSignals: gate.counted([], at: end), settings: .defaults, now: end)
        #expect(pause == .none)
    }
}
