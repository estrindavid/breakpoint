import Foundation

/// What Breakpoint reads about one audio device: its shape and state only, never its name or any
/// identifier, and never which app uses it (SPEC §2.4, decision 6).
public struct AudioDeviceState: Equatable, Hashable, Sendable {
    public enum Transport: String, Sendable, Hashable, CaseIterable {
        case builtIn, usb, bluetooth, aggregate, virtual, other

        /// "Built-in", "USB", "Bluetooth", …
        public var label: String {
            switch self {
            case .builtIn: return "Built-in"
            case .usb: return "USB"
            case .bluetooth: return "Bluetooth"
            case .aggregate: return "Aggregate"
            case .virtual: return "Virtual"
            case .other: return "Other"
            }
        }
    }

    public var transport: Transport
    public var hasInput: Bool
    public var hasOutput: Bool
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere`: some process does IO on the device (either
    /// direction; CoreAudio does not say which).
    public var runningSomewhere: Bool
    /// Hz; `nil` when it could not be read.
    public var nominalSampleRate: Double?

    public init(transport: Transport, hasInput: Bool, hasOutput: Bool, runningSomewhere: Bool,
                nominalSampleRate: Double? = nil) {
        self.transport = transport
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.runningSomewhere = runningSomewhere
        self.nominalSampleRate = nominalSampleRate
    }
}

/// Decides "microphone in use" (the call pause, SPEC §2.4) from the shape and state of audio
/// devices alone. Pure.
///
/// The rule, per device:
/// 1. Input streams and no output streams (built-in microphone, a stand-alone USB or XLR
///    microphone): in use when it is running somewhere. Playback elsewhere never runs it.
/// 2. Bluetooth with input and output streams (AirPods, wireless headsets): in use only when it is
///    running in call mode, i.e. its nominal sample rate has dropped to telephone band
///    (≤ `callModeMaxSampleRate`). Playing music runs it at 44.1 or 48 kHz, which does not count.
/// 3. Any other device with input and output streams (USB headsets, audio interfaces, aggregate
///    devices): never counted, because capture and playback cannot be told apart there.
/// Output-only devices are never microphones.
///
/// Known limitation (the deliberate trade): an audio-only call on a case-3 device is missed;
/// such calls are covered only by the camera signal and the manual pause. Missing some calls is
/// better than pausing breaks all day for someone listening to music. Case 2 assumes the headset
/// switches to a telephone-band rate when its microphone is engaged.
public enum MicrophoneUse {
    /// Highest nominal sample rate (Hz) that counts as a wireless headset's call mode.
    public static let callModeMaxSampleRate: Double = 24_000

    public enum Verdict: Equatable, Sendable {
        /// Output only: not a microphone.
        case outputOnly
        /// Case 1, running: counted.
        case microphoneRunning
        /// Case 1, idle.
        case microphoneIdle
        /// Case 2, running at a telephone-band rate: counted.
        case headsetCall
        /// Case 2, running at a music rate, or idle.
        case headsetNotInCall
        /// Case 3: never counted.
        case ambiguousIgnored
        /// No streams at all.
        case noStreams

        public var countsAsMicrophoneInUse: Bool { self == .microphoneRunning || self == .headsetCall }

        /// "counted as call", "not counted: playback and capture cannot be told apart", …
        public var explanation: String {
            switch self {
            case .outputOnly: return "output only, not a microphone"
            case .microphoneRunning: return "counted as call"
            case .microphoneIdle: return "microphone idle"
            case .headsetCall: return "counted as call"
            case .headsetNotInCall: return "not counted: headset not in call mode"
            case .ambiguousIgnored: return "not counted: playback and capture cannot be told apart"
            case .noStreams: return "no audio streams"
            }
        }
    }

    public static func verdict(for device: AudioDeviceState) -> Verdict {
        switch (device.hasInput, device.hasOutput) {
        case (false, false):
            return .noStreams
        case (false, true):
            return .outputOnly
        case (true, false):
            return device.runningSomewhere ? .microphoneRunning : .microphoneIdle
        case (true, true):
            guard device.transport == .bluetooth else { return .ambiguousIgnored }
            guard device.runningSomewhere, let rate = device.nominalSampleRate, rate > 0,
                  rate <= callModeMaxSampleRate else { return .headsetNotInCall }
            return .headsetCall
        }
    }

    /// Whether any device shows a microphone in use.
    public static func isInUse(_ devices: [AudioDeviceState]) -> Bool {
        devices.contains { verdict(for: $0).countsAsMicrophoneInUse }
    }

    /// One generic line for the diagnostic report, e.g.
    /// "Bluetooth, input+output, running, 16 kHz → counted as call". Never a name or identifier.
    public static func describe(_ device: AudioDeviceState) -> String {
        let shape: String
        switch (device.hasInput, device.hasOutput) {
        case (true, true): shape = "input+output"
        case (true, false): shape = "input only"
        case (false, true): shape = "output only"
        case (false, false): shape = "no streams"
        }
        let rate = device.nominalSampleRate.map(formatRate) ?? "rate unknown"
        let running = device.runningSomewhere ? "running" : "idle"
        return "\(device.transport.label), \(shape), \(running), \(rate) → \(verdict(for: device).explanation)"
    }

    /// "16 kHz", "44.1 kHz".
    static func formatRate(_ hz: Double) -> String {
        let khz = hz / 1000
        let text = khz.rounded() == khz ? String(Int(khz)) : String(format: "%.1f", khz)
        return "\(text) kHz"
    }
}

/// A plain-text report of every signal the activity monitor reads and the decisions reached, for
/// checking the rules on a real machine (e.g. the Bluetooth call-mode rule on a real
/// headset). Contains no device names, identifiers, app names or content. Pure.
public enum ActivityDiagnostics {
    public static func report(
        sample: InputSample,
        audioDevices: [AudioDeviceState],
        cameraInUse: Bool,
        locked: Bool,
        displaysAsleep: Bool,
        screensaverRunning: Bool,
        sessionActive: Bool,
        at date: Date
    ) -> String {
        func seconds(_ value: TimeInterval) -> String {
            value >= 1e9 ? "never" : String(format: "%.1f s", value)
        }
        var lines: [String] = []
        lines.append("Breakpoint signals at \(ISO8601.string(from: date))")
        lines.append("Idle: \(seconds(sample.secondsSinceAnyInput)) since any input, \(seconds(sample.secondsSinceKey)) since a key, \(seconds(sample.secondsSinceDrag)) since a click or drag, \(seconds(sample.secondsSinceScroll)) since a scroll")
        lines.append("Mouse button down: \(sample.mouseButtonDown ? "yes" : "no")")
        lines.append("Display sleep prevented by some process: \(sample.displaySleepPrevented ? "yes" : "no")")
        lines.append("Display mirrored: \(sample.displayMirrored ? "yes" : "no")")
        lines.append("Presenting guard: " + (sample.presentingCause.map { "on (\($0.phrase))" } ?? "off"))
        lines.append("Screen locked: \(locked ? "yes" : "no"); displays asleep: \(displaysAsleep ? "yes" : "no"); screensaver: \(screensaverRunning ? "yes" : "no"); session active: \(sessionActive ? "yes" : "no")")
        lines.append("Audio devices: \(audioDevices.count)")
        for (index, device) in audioDevices.enumerated() {
            lines.append("  \(index + 1). \(MicrophoneUse.describe(device))")
        }
        lines.append("Microphone in use: \(MicrophoneUse.isInUse(audioDevices) ? "yes" : "no") (a call once on for \(Int(Timing.microphoneCallAfter)) s)")
        lines.append("Camera in use: \(cameraInUse ? "yes" : "no")")
        return lines.joined(separator: "\n")
    }
}
