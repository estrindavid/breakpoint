import Foundation

/// The AirPods movement check's threshold (SPEC §2.9): "movement detected" when the head has
/// turned enough during a `move` or `walk` break. Pure; fed by Kit's `HeadphoneMotionMonitor`.
/// No rep counting, no scoring: one yes/no per break.
///
/// The rule: integrate the head's rotation speed (the magnitude of the gyroscope's rotation rate,
/// radians per second) over time, ignoring readings below `noiseFloor` (sitting still, breathing,
/// sensor noise). Movement is detected once the accumulated rotation reaches `threshold` radians.
/// 6 rad is about 340°: roughly six deliberate 60° neck bends, or a minute of walking, while
/// typing or reading at a desk stays far below it. Gaps between samples longer than `maxGap`
/// count as `maxGap`, so a dropped connection never inflates the total.
public struct MovementDetector: Equatable, Sendable {
    /// Rotation speeds below this (rad/s) are treated as stillness.
    public static let noiseFloor: Double = 0.3
    /// Accumulated rotation (rad) that counts as movement.
    public static let threshold: Double = 6
    /// The longest time step a single sample may cover.
    public static let maxGap: TimeInterval = 0.5

    /// Rotation accumulated so far, in radians.
    public private(set) var accumulated: Double = 0
    private var lastTimestamp: TimeInterval?

    public init() {}

    public var detected: Bool { accumulated >= Self.threshold }

    /// Adds one gyroscope reading (rad/s around x, y, z) taken at `timestamp` (seconds, any epoch).
    public mutating func add(x: Double, y: Double, z: Double, timestamp: TimeInterval) {
        defer { lastTimestamp = timestamp }
        guard let last = lastTimestamp, timestamp > last else { return }
        let speed = (x * x + y * y + z * z).squareRoot()
        guard speed.isFinite, speed >= Self.noiseFloor else { return }
        accumulated += speed * min(timestamp - last, Self.maxGap)
    }

    /// Starts a new break.
    public mutating func reset() { self = MovementDetector() }
}
