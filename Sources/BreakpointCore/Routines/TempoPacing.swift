import Foundation

// The `move` ring's pacing (SPEC §3.4): where in a repetition the user is, as a pure function of
// the seconds since the step started, so the live overlay, the snapshots and the tests all draw
// the same frames. Modelled on the `breathe` ring (`BreathCycle` in the Kit): sine ease-in-out
// over each phase, the phase word cross-fading at each turn.

/// How the ring moves during one phase of a repetition.
public enum PaceMotion: String, Codable, Sendable, Equatable {
    /// The arc fills from empty to full over the phase ("up", "squeeze", "reach", "one side").
    case out
    /// The arc returns from full to empty ("down", "release", "other side").
    case back
    /// The arc stays where it is ("hold" after a movement).
    case hold
    /// A one-phase repetition ("circle", "shake", "rest"): a short arc travels once around the
    /// ring per repetition, with no jump between repetitions.
    case around
}

/// One moment of a step's pacing.
public struct PaceFrame: Equatable, Sendable {
    /// Index of the phase in the step's tempo.
    public var phaseIndex: Int
    /// The phase's word, e.g. "up".
    public var label: String
    public var motion: PaceMotion
    /// 0…1 through the current phase (linear time).
    public var phaseProgress: Double
    /// Seconds into the current phase.
    public var phaseElapsed: TimeInterval
    /// Seconds left in the current phase.
    public var phaseRemaining: TimeInterval
    /// How full the ring is, 0…1 (eased). For `.around` the arc's head position, 0…1 (linear).
    public var fullness: Double
    /// Repetitions completed before this one.
    public var repetition: Int

    public init(phaseIndex: Int, label: String, motion: PaceMotion, phaseProgress: Double, phaseElapsed: TimeInterval,
                phaseRemaining: TimeInterval, fullness: Double, repetition: Int) {
        self.phaseIndex = phaseIndex
        self.label = label
        self.motion = motion
        self.phaseProgress = phaseProgress
        self.phaseElapsed = phaseElapsed
        self.phaseRemaining = phaseRemaining
        self.fullness = fullness
        self.repetition = repetition
    }
}

public enum TempoPacing {
    /// The motion of each phase of a repetition:
    /// - one phase: `.around`;
    /// - a "hold" after a filling phase keeps the ring full (`.hold`); a hold that opens the
    ///   repetition fills it instead (`.out`), so the ring is never still at empty;
    /// - of the other phases, the first half fill (`.out`) and the rest return (`.back`).
    public static func motions(for tempo: [TempoPhase]) -> [PaceMotion] {
        guard tempo.count > 1 else { return tempo.isEmpty ? [] : [.around] }
        let moving = tempo.indices.filter { !isHold(tempo[$0]) }
        let outCount = max(1, (moving.count + 1) / 2)
        var result: [PaceMotion] = []
        var filled = false
        for (i, phase) in tempo.enumerated() {
            if isHold(phase) {
                if filled {
                    result.append(.hold)
                } else {
                    result.append(.out)
                    filled = true
                }
                continue
            }
            let rank = moving.firstIndex(of: i) ?? 0
            if rank < outCount && !(filled && moving.count == 1) {
                result.append(.out)
                filled = true
            } else {
                result.append(.back)
            }
        }
        return result
    }

    /// A phase the body holds still in.
    public static func isHold(_ phase: TempoPhase) -> Bool {
        phase.label.lowercased() == "hold"
    }

    /// Sine ease-in-out (the `breathe` ring's curve), 0…1 → 0…1.
    public static func ease(_ p: Double) -> Double {
        let x = min(max(p, 0), 1)
        return 0.5 - 0.5 * cos(.pi * x)
    }

    /// The frame `stepElapsed` seconds into a step with this tempo; `nil` without a tempo.
    /// - `stepped`: Reduce Motion. Progress moves in whole seconds of the phase (a counted beat,
    ///   no sweep): 1/3, 2/3, 3/3 for a 3 s "up"; 2/3, 1/3, 0 for a 3 s "down".
    public static func frame(tempo: [TempoPhase], at stepElapsed: TimeInterval, stepped: Bool = false) -> PaceFrame? {
        let length = tempo.reduce(0) { $0 + $1.seconds }
        guard length > 0 else { return nil }
        let motions = motions(for: tempo)
        let t = max(0, stepElapsed)
        let repetition = Int((t / length).rounded(.down))
        var inRep = t - Double(repetition) * length
        var index = 0
        while index < tempo.count - 1, inRep >= tempo[index].seconds {
            inRep -= tempo[index].seconds
            index += 1
        }
        let phase = tempo[index]
        let seconds = max(phase.seconds, 0.001)
        let linear = min(max(inRep / seconds, 0), 1)
        var progress = linear
        if stepped {
            // Whole seconds, counted from the first: a 3 s phase reads 1/3, 2/3, 3/3.
            let beats = max(1, phase.seconds.rounded())
            progress = min(beats, ((inRep / seconds) * beats).rounded(.down) + 1) / beats
        }
        let fullness: Double
        switch motions[index] {
        case .out: fullness = stepped ? progress : ease(progress)
        case .back: fullness = stepped ? 1 - progress : 1 - ease(progress)
        case .hold: fullness = 1
        case .around: fullness = progress
        }
        return PaceFrame(phaseIndex: index, label: phase.label, motion: motions[index], phaseProgress: linear,
                         phaseElapsed: inRep, phaseRemaining: max(0, phase.seconds - inRep), fullness: fullness,
                         repetition: repetition)
    }

    /// The phase word before and after a frame's phase (for the cross-fade at each turn): the
    /// previous phase's label, and the next phase's label (wrapping into the next repetition).
    public static func neighbours(tempo: [TempoPhase], phaseIndex: Int) -> (previous: String, next: String) {
        guard !tempo.isEmpty else { return ("", "") }
        let previous = tempo[(phaseIndex - 1 + tempo.count) % tempo.count].label
        let next = tempo[(phaseIndex + 1) % tempo.count].label
        return (previous, next)
    }
}
