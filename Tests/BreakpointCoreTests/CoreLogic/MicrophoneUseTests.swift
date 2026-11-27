import Foundation
import Testing
@testable import BreakpointCore

/// Fake devices for the microphone decision.
private enum Device {
    static func builtInMic(running: Bool = false) -> AudioDeviceState {
        AudioDeviceState(transport: .builtIn, hasInput: true, hasOutput: false, runningSomewhere: running, nominalSampleRate: 48_000)
    }
    static func builtInSpeakers(running: Bool = false) -> AudioDeviceState {
        AudioDeviceState(transport: .builtIn, hasInput: false, hasOutput: true, runningSomewhere: running, nominalSampleRate: 48_000)
    }
    static func usbMic(running: Bool) -> AudioDeviceState {
        AudioDeviceState(transport: .usb, hasInput: true, hasOutput: false, runningSomewhere: running, nominalSampleRate: 44_100)
    }
    static func airPods(running: Bool, rate: Double?) -> AudioDeviceState {
        AudioDeviceState(transport: .bluetooth, hasInput: true, hasOutput: true, runningSomewhere: running, nominalSampleRate: rate)
    }
    static func usbHeadset(running: Bool, rate: Double = 48_000) -> AudioDeviceState {
        AudioDeviceState(transport: .usb, hasInput: true, hasOutput: true, runningSomewhere: running, nominalSampleRate: rate)
    }
}

@Suite("Microphone in use from device shape and state (SPEC §2.4, coordinator decision)")
struct MicrophoneUseTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let device: AudioDeviceState
        let verdict: MicrophoneUse.Verdict
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // 1. Input only: running means in use.
        Case(name: "built-in mic idle", device: Device.builtInMic(), verdict: .microphoneIdle),
        Case(name: "built-in mic running", device: Device.builtInMic(running: true), verdict: .microphoneRunning),
        Case(name: "USB microphone running", device: Device.usbMic(running: true), verdict: .microphoneRunning),
        Case(name: "Bluetooth input-only running", device: AudioDeviceState(transport: .bluetooth, hasInput: true, hasOutput: false,
                                                                             runningSomewhere: true, nominalSampleRate: 48_000),
             verdict: .microphoneRunning),
        // Output only: never a microphone, even while playing.
        Case(name: "speakers playing", device: Device.builtInSpeakers(running: true), verdict: .outputOnly),
        // 2. Bluetooth input+output: only in call mode.
        Case(name: "AirPods playing music at 48 kHz", device: Device.airPods(running: true, rate: 48_000), verdict: .headsetNotInCall),
        Case(name: "AirPods playing music at 44.1 kHz", device: Device.airPods(running: true, rate: 44_100), verdict: .headsetNotInCall),
        Case(name: "AirPods in a call at 16 kHz", device: Device.airPods(running: true, rate: 16_000), verdict: .headsetCall),
        Case(name: "AirPods in a call at 24 kHz (boundary)", device: Device.airPods(running: true, rate: 24_000), verdict: .headsetCall),
        Case(name: "AirPods at 24.001 kHz", device: Device.airPods(running: true, rate: 24_001), verdict: .headsetNotInCall),
        Case(name: "AirPods idle in call mode", device: Device.airPods(running: false, rate: 16_000), verdict: .headsetNotInCall),
        Case(name: "AirPods running, rate unreadable", device: Device.airPods(running: true, rate: nil), verdict: .headsetNotInCall),
        // 3. Any other input+output device: never counted.
        Case(name: "USB headset playing", device: Device.usbHeadset(running: true), verdict: .ambiguousIgnored),
        Case(name: "USB headset at 16 kHz", device: Device.usbHeadset(running: true, rate: 16_000), verdict: .ambiguousIgnored),
        Case(name: "aggregate device running", device: AudioDeviceState(transport: .aggregate, hasInput: true, hasOutput: true,
                                                                         runningSomewhere: true, nominalSampleRate: 48_000),
             verdict: .ambiguousIgnored),
        Case(name: "built-in input+output running", device: AudioDeviceState(transport: .builtIn, hasInput: true, hasOutput: true,
                                                                              runningSomewhere: true, nominalSampleRate: 48_000),
             verdict: .ambiguousIgnored),
        Case(name: "no streams", device: AudioDeviceState(transport: .virtual, hasInput: false, hasOutput: false,
                                                           runningSomewhere: true), verdict: .noStreams),
    ]

    @Test(arguments: cases)
    func verdictPerDevice(_ row: Case) {
        #expect(MicrophoneUse.verdict(for: row.device) == row.verdict)
        #expect(MicrophoneUse.isInUse([row.device]) == (row.verdict == .microphoneRunning || row.verdict == .headsetCall))
    }

    @Test func mixedSetUps() {
        // Built-in mic idle while AirPods play music (and the speakers sit idle): no call.
        #expect(!MicrophoneUse.isInUse([Device.builtInMic(), Device.builtInSpeakers(), Device.airPods(running: true, rate: 48_000)]))
        // AirPods switched to call mode: a call.
        #expect(MicrophoneUse.isInUse([Device.builtInMic(), Device.builtInSpeakers(), Device.airPods(running: true, rate: 16_000)]))
        // A USB headset playing, built-in mic idle: no call (the deliberate trade).
        #expect(!MicrophoneUse.isInUse([Device.builtInMic(), Device.usbHeadset(running: true)]))
        // A call on the built-in mic while music plays through a USB headset: a call.
        #expect(MicrophoneUse.isInUse([Device.builtInMic(running: true), Device.usbHeadset(running: true)]))
        // Sound through the speakers only: no call.
        #expect(!MicrophoneUse.isInUse([Device.builtInMic(), Device.builtInSpeakers(running: true)]))
        // Nothing connected.
        #expect(!MicrophoneUse.isInUse([]))
    }

    @Test func devicesAppearingAndDisappearingBetweenReads() {
        // Reads over time; each is a fresh list, as the reader returns it.
        let reads: [[AudioDeviceState]] = [
            [Device.builtInMic(), Device.builtInSpeakers()],                                     // desk
            [Device.builtInMic(), Device.builtInSpeakers(), Device.airPods(running: false, rate: 48_000)],  // AirPods connect
            [Device.builtInMic(), Device.builtInSpeakers(), Device.airPods(running: true, rate: 48_000)],   // music
            [Device.builtInMic(), Device.builtInSpeakers(), Device.airPods(running: true, rate: 16_000)],   // call starts
            [Device.builtInMic(), Device.builtInSpeakers()],                                     // AirPods gone mid-call (left out when unreadable)
            [Device.builtInMic(running: true), Device.builtInSpeakers(running: true)],           // call moves to the built-in mic
            [Device.builtInMic(), Device.builtInSpeakers()],                                     // call over
        ]
        #expect(reads.map(MicrophoneUse.isInUse) == [false, false, false, true, false, true, false])
    }

    @Test func describesDevicesWithoutNames() {
        #expect(MicrophoneUse.describe(Device.airPods(running: true, rate: 16_000))
                == "Bluetooth, input+output, running, 16 kHz → counted as call")
        #expect(MicrophoneUse.describe(Device.airPods(running: true, rate: 44_100))
                == "Bluetooth, input+output, running, 44.1 kHz → not counted: headset not in call mode")
        #expect(MicrophoneUse.describe(Device.builtInMic())
                == "Built-in, input only, idle, 48 kHz → microphone idle")
        #expect(MicrophoneUse.describe(Device.builtInSpeakers(running: true))
                == "Built-in, output only, running, 48 kHz → output only, not a microphone")
        #expect(MicrophoneUse.describe(Device.usbHeadset(running: true))
                == "USB, input+output, running, 48 kHz → not counted: playback and capture cannot be told apart")
        #expect(MicrophoneUse.describe(Device.airPods(running: false, rate: nil))
                == "Bluetooth, input+output, idle, rate unknown → not counted: headset not in call mode")
    }

    @Test func diagnosticReportListsEverySignal() {
        let now = Fixture.date(14)
        let sample = InputSample(takenAt: now, secondsSinceKey: 12, secondsSinceAnyInput: 3.3, secondsSinceDrag: .greatestFiniteMagnitude,
                                 mouseButtonDown: false, displaySleepPrevented: true)
        let report = ActivityDiagnostics.report(
            sample: sample, audioDevices: [Device.builtInMic(), Device.airPods(running: true, rate: 16_000)],
            cameraInUse: false, locked: false, displaysAsleep: false, screensaverRunning: false, sessionActive: true, at: now)
        #expect(report == """
            Breakpoint signals at 2026-11-22T14:00:00.000Z
            Idle: 3.3 s since any input, 12.0 s since a key, never since a click or drag, 600.0 s since a scroll
            Mouse button down: no
            Display sleep prevented by some process: yes
            Display mirrored: no
            Presenting guard: on (the display is kept awake)
            Screen locked: no; displays asleep: no; screensaver: no; session active: yes
            Audio devices: 2
              1. Built-in, input only, idle, 48 kHz → microphone idle
              2. Bluetooth, input+output, running, 16 kHz → counted as call
            Microphone in use: yes (a call once on for 60 s)
            Camera in use: no
            """)
    }
}
