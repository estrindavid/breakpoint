import AVFoundation
import AppKit
import BreakpointCore

/// Synthesised sounds (SPEC §4.7): the chimes are two sine partials, ≥ 30 ms attack, ~1.5 s
/// exponential decay, no transient spike, ≤ −18 LUFS at full volume, via `AVAudioEngine`; the
/// step tick is a short, quieter cue of the same family.
///
/// Contract: `play` returns immediately; `volume` is 0…1 (`Settings.volume`). The coordinator never
/// calls it while a call signal is active. No bundled audio files.
@MainActor
public protocol SoundPlaying: AnyObject {
    func play(_ sound: SoundID, volume: Double)
}

/// The cues, synthesised once and played through an `AVAudioEngine` that runs only while a
/// cue is sounding (so the audio hardware is not kept awake between cues). Output only: no
/// permission is involved.
@MainActor
public final class SoundPlayer: SoundPlaying {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffers: [SoundID: AVAudioPCMBuffer] = [:]
    private var stopWork: DispatchWorkItem?
    private let format = AVAudioFormat(standardFormatWithSampleRate: ChimeSynth.sampleRate, channels: 1)!

    public init() {}

    public func play(_ sound: SoundID, volume: Double) {
        let level = Float(min(max(volume, 0), 1))
        guard level > 0, let buffer = buffer(for: sound) else { return }
        do {
            let (engine, player) = try running()
            player.volume = level
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            player.play()
            _ = engine
            scheduleStop(after: Double(buffer.frameLength) / ChimeSynth.sampleRate + 0.3)
        } catch {
            // Sound is a courtesy; failing silently is right.
        }
    }

    private func running() throws -> (AVAudioEngine, AVAudioPlayerNode) {
        if let engine, let player {
            if !engine.isRunning { try engine.start() }
            return (engine, player)
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.player = player
        return (engine, player)
    }

    private func scheduleStop(after delay: TimeInterval) {
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.player?.stop()
                self?.engine?.stop()
            }
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func buffer(for sound: SoundID) -> AVAudioPCMBuffer? {
        if let cached = buffers[sound] { return cached }
        let samples = ChimeSynth.samples(for: sound)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffers[sound] = buffer
        return buffer
    }
}

/// The cue synthesiser (pure, so its level can be measured without playing anything).
///
/// The chimes: two sine partials a perfect fifth apart (the upper one quieter), a 40 ms
/// raised-cosine attack (no click), an exponential decay with a 0.33 s time constant (≈ −40 dB at
/// 1.5 s), and a 60 ms fade to silence at 1.8 s, normalised so their integrated loudness at full
/// volume is `targetLUFS` (BS.1770 gating; K-weighting is within ±1 dB of flat at these pitches,
/// covered by the 2 dB margin to the −18 LUFS limit).
///
/// The step tick is the same family made small: the same fifth an octave above the break-end
/// chime, the same 40 ms attack, a 0.07 s decay and a 0.45 s length, 10 dB quieter (`tickLUFS`).
public enum ChimeSynth {
    public static let sampleRate: Double = 44_100
    public static let targetLUFS: Double = -20
    /// The step tick's level at full volume: 10 dB under the chimes.
    public static let tickLUFS: Double = -30
    static let tailFade: Double = 0.06

    /// Envelope and level of one cue.
    struct Shape {
        var attack: Double
        var decay: Double
        var length: Double
        var lufs: Double
    }

    static func shape(for sound: SoundID) -> Shape {
        switch sound {
        case .needsYouChime, .breakEndChime: return Shape(attack: 0.04, decay: 0.33, length: 1.8, lufs: targetLUFS)
        case .stepTick: return Shape(attack: 0.04, decay: 0.07, length: 0.45, lufs: tickLUFS)
        }
    }

    /// Partials (Hz, relative amplitude) for each cue: needs-you is brighter (A5 + E6); break-end
    /// is lower and gentler (E5 + B5); the tick is the break-end fifth an octave up (E6 + B6),
    /// its upper partial faint.
    static func partials(for sound: SoundID) -> [(Double, Double)] {
        switch sound {
        case .needsYouChime: return [(880.0, 1.0), (1318.5, 0.45)]
        case .breakEndChime: return [(659.25, 1.0), (987.77, 0.35)]
        case .stepTick: return [(1318.5, 1.0), (1975.5, 0.2)]
        }
    }

    public static func samples(for sound: SoundID) -> [Float] {
        let shape = shape(for: sound)
        let count = Int(shape.length * sampleRate)
        var out = [Double](repeating: 0, count: count)
        let parts = partials(for: sound)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var value = 0.0
            for (frequency, amplitude) in parts { value += amplitude * sin(2 * .pi * frequency * t) }
            out[i] = value * envelope(t, shape)
        }
        let loudness = integratedLoudness(out)
        let gain = loudness.isFinite ? pow(10, (shape.lufs - loudness) / 20) : 0
        return out.map { Float($0 * gain) }
    }

    static func envelope(_ t: Double, _ shape: Shape) -> Double {
        let rise = t < shape.attack ? 0.5 - 0.5 * cos(.pi * t / shape.attack) : 1
        let fall = exp(-max(0, t - shape.attack) / shape.decay)
        let tail = t > shape.length - tailFade ? max(0, (shape.length - t) / tailFade) : 1
        return rise * fall * tail
    }

    /// BS.1770-style integrated loudness (unweighted): 400 ms blocks, 75% overlap, absolute gate
    /// −70 LUFS, relative gate −10 LU.
    public static func integratedLoudness(_ samples: [Double]) -> Double {
        let block = Int(0.4 * sampleRate), hop = block / 4
        guard samples.count >= block else { return -.infinity }
        var powers: [Double] = []
        var start = 0
        while start + block <= samples.count {
            var sum = 0.0
            for i in start..<(start + block) { sum += samples[i] * samples[i] }
            powers.append(sum / Double(block))
            start += hop
        }
        func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
        let absolute = powers.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let relativeGate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relativeGate }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Measured loudness of a cue at full volume (diagnostics).
    public static func measuredLUFS(for sound: SoundID) -> Double {
        integratedLoudness(samples(for: sound).map(Double.init))
    }

    /// Peak sample of a cue at full volume, in dBFS (diagnostics: no spike).
    public static func peakDBFS(for sound: SoundID) -> Double {
        20 * log10(samples(for: sound).map { Double(abs($0)) }.max() ?? 0)
    }
}
