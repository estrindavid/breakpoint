import Foundation

// The menu-bar mark's one-shot movements (SPEC §3.7, §4.1, §4.6). Pure values: which movement a
// change of state earns, and the mark's pose at each moment of it. The menu bar draws the poses;
// nothing here knows about AppKit or time.
//
// Limits (SPEC §4.1, identity guardrails): each movement plays once, at the moment it means
// something, and never loops. The mark gains no features: no blinking, no closed eyes, no mouth or
// limbs, and nothing reacts to whether the person took a break.

/// A one-shot movement of the menu-bar mark.
public enum MarkCue: String, Codable, Sendable, Hashable, CaseIterable {
    /// An agent finished its run: the working dot slides into the notch and disappears.
    case settle
    /// An agent needs you: the two eyes grow about a point taller (they widen) and settle back.
    case lift
    /// The day is wrapped up: the two eyes fold into the single rest bar.
    case fold
}

/// A cue raised by the coordinator. `id` increases with every cue, so the menu bar plays each one
/// exactly once.
public struct MarkCueEvent: Codable, Equatable, Hashable, Sendable {
    public var cue: MarkCue
    public var id: Int
    public var at: Date

    public init(cue: MarkCue, id: Int, at: Date) {
        self.cue = cue
        self.id = id
        self.at = at
    }
}

/// How the mark is bent at one moment of a movement, in the mark's 24-unit grid. `rest` is the
/// mark as drawn for its state.
public struct MarkPose: Equatable, Hashable, Sendable {
    /// Extra height of each eye, centred (grid units).
    public var barLift: Double
    /// 0 = the two eyes, 1 = the single rest bar of the paused state.
    public var fold: Double
    /// The working dot's way from its badge spot (0) to the centre of the notch (1).
    public var dotTravel: Double
    /// The working dot's size, 1 = as drawn, 0 = gone.
    public var dotScale: Double

    public init(barLift: Double = 0, fold: Double = 0, dotTravel: Double = 0, dotScale: Double = 1) {
        self.barLift = barLift
        self.fold = fold
        self.dotTravel = dotTravel
        self.dotScale = dotScale
    }

    public static let rest = MarkPose()
}

public enum MarkMotion {
    /// How much taller each bar grows at the top of `lift` (grid units). The menu-bar mark is drawn
    /// at about 0.96 pt per unit, so this is about one point.
    public static let liftHeight: Double = 1.1
    /// How high the ✓ hops on onboarding's Connect step when an install is verified (points).
    public static let hopHeight: Double = 4
    /// Where the lift peaks, as a fraction of its length.
    static let liftPeak: Double = 0.35
    /// The settling dot keeps its size until this fraction, then shrinks to nothing.
    static let settleShrinkFrom: Double = 0.2

    /// The pose at `progress` (0…1, clamped) through `cue`. Starts and ends at rest, except that a
    /// settled dot ends gone (`dotScale` 0) and a fold ends folded (`fold` 1).
    public static func pose(_ cue: MarkCue, progress: Double) -> MarkPose {
        let t = clamp(progress)
        switch cue {
        case .settle:
            return MarkPose(dotTravel: easeInOut(t),
                            dotScale: 1 - easeIn(clamp((t - settleShrinkFrom) / (1 - settleShrinkFrom))))
        case .lift:
            let height = t < liftPeak
                ? easeOut(t / liftPeak)
                : 1 - easeInOut((t - liftPeak) / (1 - liftPeak))
            return MarkPose(barLift: liftHeight * height)
        case .fold:
            return MarkPose(fold: easeInOut(t))
        }
    }

    /// The onboarding hop's vertical offset at `progress` (0…1): up `hopHeight` points (negative
    /// is up) and back down, once.
    public static func hopOffset(progress: Double) -> Double {
        let t = clamp(progress)
        let up = 0.4
        let height = t < up ? easeOut(t / up) : 1 - easeIn((t - up) / (1 - up))
        return -hopHeight * height
    }

    /// Key frames of a movement for a strip (snapshots): `count` evenly spaced poses from start to end.
    public static func keyFrames(_ cue: MarkCue, count: Int) -> [MarkPose] {
        guard count > 1 else { return [pose(cue, progress: 1)] }
        return (0..<count).map { pose(cue, progress: Double($0) / Double(count - 1)) }
    }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func easeIn(_ t: Double) -> Double { t * t }
    static func easeOut(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }
    static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
}

/// The facts about the menu bar that decide a cue, in Core terms.
public struct MarkFacts: Equatable, Sendable {
    public enum Agent: Sendable { case none, working, needsYou }

    /// The paused shape (a single bar) is showing.
    public var paused: Bool
    /// The wrap-up pause is one of the active pause reasons.
    public var wrappedUp: Bool
    public var agent: Agent

    public init(paused: Bool = false, wrappedUp: Bool = false, agent: Agent = .none) {
        self.paused = paused
        self.wrappedUp = wrappedUp
        self.agent = agent
    }
}

/// Which movement, if any, a change of the menu bar earns (SPEC §3.7). At most one at a time, in
/// this order: an agent needing you, an agent finishing, the day wrapped up.
public enum MarkCuePolicy {
    /// - `lift` when an agent starts needing you (the badge becomes the ring).
    /// - `settle` when a run finished normally (`runFinished`) and with it the last working agent
    ///   (the badge goes from the dot to nothing). An interrupted, cancelled or failed run, a
    ///   session that ended, or a stale run is not "finished": the dot just goes.
    /// - `fold` when Wrap up starts the wrap-up pause while the eyes were showing.
    public static func cue(from old: MarkFacts, to new: MarkFacts, runFinished: Bool) -> MarkCue? {
        if new.agent == .needsYou, old.agent != .needsYou { return .lift }
        if runFinished, old.agent == .working, new.agent == .none { return .settle }
        if new.wrappedUp, !old.wrappedUp, new.paused, !old.paused { return .fold }
        return nil
    }
}
