import Foundation

// Which routine a stretch uses and which copy variant each break
// shows (SPEC §2.2). Pure: the coordinator owns the state and saves it in `rotation.json`.

/// A shuffle bag of copy variant indices for one break kind: every variant once, in random order,
/// before any repeats, and never the same variant twice in a row.
public struct CopyBag: Codable, Equatable, Hashable, Sendable {
    /// Variant indices not drawn yet in this round.
    public var remaining: [Int]
    /// The variant drawn last (never drawn again next).
    public var last: Int?

    public init(remaining: [Int] = [], last: Int? = nil) {
        self.remaining = remaining
        self.last = last
    }
}

/// What rotation needs to remember across launches (`rotation.json`, SPEC §8).
public struct RotationState: Codable, Equatable, Hashable, Sendable {
    /// Stretch breaks started so far (a counter, not a clock, so clock changes do not matter).
    public var stretchesStarted: Int
    /// Routine id → the value of `stretchesStarted` when that routine was last started.
    public var routineLastStarted: [String: Int]
    /// The routine of the last stretch break.
    public var lastRoutineID: String?
    /// Break kind (raw value) → its copy bag.
    public var copyBags: [String: CopyBag]

    public init(stretchesStarted: Int = 0, routineLastStarted: [String: Int] = [:], lastRoutineID: String? = nil,
                copyBags: [String: CopyBag] = [:]) {
        self.stretchesStarted = stretchesStarted
        self.routineLastStarted = routineLastStarted
        self.lastRoutineID = lastRoutineID
        self.copyBags = copyBags
    }

    public static let empty = RotationState()

    enum CodingKeys: String, CodingKey { case stretchesStarted, routineLastStarted, lastRoutineID, copyBags }

    /// Tolerant: a missing or wrong key starts that part afresh instead of losing the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stretchesStarted = (try? c.decodeIfPresent(Int.self, forKey: .stretchesStarted)) ?? 0
        routineLastStarted = (try? c.decodeIfPresent([String: Int].self, forKey: .routineLastStarted)) ?? [:]
        lastRoutineID = (try? c.decodeIfPresent(String.self, forKey: .lastRoutineID)) ?? nil
        copyBags = (try? c.decodeIfPresent([String: CopyBag].self, forKey: .copyBags)) ?? [:]
    }

    public static func file(_ paths: BreakpointPaths) -> JSONFile<RotationState> {
        JSONFile(url: paths.rotationFile)
    }

    /// The saved state, or an empty one when the file is missing or unreadable.
    public static func load(_ paths: BreakpointPaths) -> RotationState {
        (try? file(paths).read()) ?? .empty
    }
}

/// Picks the routine for the next stretch break (SPEC §2.2).
public enum RoutineRotation {
    /// The allowed routine started least recently; never the last one again when more than one
    /// is allowed. Routines never done come first; ties go to library order.
    public static func next(from allowed: [Routine], state: RotationState) -> Routine? {
        guard !allowed.isEmpty else { return nil }
        let candidates = allowed.count > 1 ? allowed.filter { $0.id != state.lastRoutineID } : allowed
        // Never started counts as oldest; `min(by:)` keeps the first of equals (library order).
        return candidates.min { (state.routineLastStarted[$0.id] ?? Int.min) < (state.routineLastStarted[$1.id] ?? Int.min) }
    }

    /// The routine for the next stretch with these settings.
    public static func next(for settings: Settings, state: RotationState) -> Routine {
        next(from: BuiltInRoutines.allowed(for: settings), state: state)
            ?? BuiltInRoutines.neckAndShoulders
    }

    /// `state` after a stretch break started with `routineID`.
    public static func started(_ routineID: String, in state: RotationState) -> RotationState {
        var s = state
        s.stretchesStarted += 1
        s.routineLastStarted[routineID] = s.stretchesStarted
        s.lastRoutineID = routineID
        return s
    }
}

/// Draws copy variants from each kind's shuffle bag (SPEC §2.2).
public enum CopyRotation {
    /// The variant index for `kind` (out of `count`) and the state after drawing it. A new round
    /// refills the bag with every index; the first draw of a round avoids the last variant drawn.
    public static func draw<G: RandomNumberGenerator>(
        _ kind: BreakKind, count: Int, state: RotationState, using generator: inout G
    ) -> (index: Int, state: RotationState) {
        draw(bag: kind.rawValue, count: count, state: state, using: &generator)
    }

    /// The same draw from any named bag (e.g. the walk ideas, a kind's closing lines).
    public static func draw<G: RandomNumberGenerator>(
        bag key: String, count: Int, state: RotationState, using generator: inout G
    ) -> (index: Int, state: RotationState) {
        guard count > 0 else { return (0, state) }
        var bag = state.copyBags[key] ?? CopyBag()
        // A variant list that shrank leaves stale indices behind; drop them.
        bag.remaining = bag.remaining.filter { (0..<count).contains($0) }
        if let last = bag.last, !(0..<count).contains(last) { bag.last = nil }
        if bag.remaining.isEmpty { bag.remaining = Array(0..<count) }
        var choices = bag.remaining
        if choices.count > 1, let last = bag.last { choices.removeAll { $0 == last } }
        let index = choices.randomElement(using: &generator) ?? choices[0]
        bag.remaining.removeAll { $0 == index }
        bag.last = index
        var s = state
        s.copyBags[key] = bag
        return (index, s)
    }

    /// The draw with the system's random generator.
    public static func draw(_ kind: BreakKind, count: Int, state: RotationState) -> (index: Int, state: RotationState) {
        var generator = SystemRandomNumberGenerator()
        return draw(kind, count: count, state: state, using: &generator)
    }

    /// A named bag's draw with the system's random generator.
    public static func draw(bag key: String, count: Int, state: RotationState) -> (index: Int, state: RotationState) {
        var generator = SystemRandomNumberGenerator()
        return draw(bag: key, count: count, state: state, using: &generator)
    }
}
