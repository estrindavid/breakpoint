import AVFoundation
import AppKit
import BreakpointCore
import BreakpointRuntime

// `SoundPlaying` is declared in BreakpointRuntime (Platform/PlatformServices.swift).

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

// `ChimeSynth`, the cue synthesiser, is shared with the Windows app (BreakpointRuntime,
// Platform/ChimeSynth.swift).
