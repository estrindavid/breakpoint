import Foundation

/// Turns the raw call signals into the ones that count as a call (SPEC §2.4). A value type: the
/// coordinator calls `observe` with the raw signals on every tick.
///
/// A microphone counts only once it has been on without a break for `Timing.microphoneCallAfter`:
/// dictating a prompt switches it on for seconds, a call for minutes. Until then it is *pending*:
/// offers are held while it lasts (as the typing guard holds them, so nothing appears while the
/// person speaks), with no call pause, no toast and no cool-down afterwards. The camera counts at
/// once.
public struct MicrophoneCallGate: Equatable, Sendable {
    /// When the microphone last came on; `nil` while it is off.
    public private(set) var microphoneOnSince: Date?

    public init() {}

    /// Notes the raw signals at `now`. Any moment off restarts the count.
    public mutating func observe(_ raw: CallSignals, at now: Date) {
        if !raw.contains(.microphone) {
            microphoneOnSince = nil
        } else if microphoneOnSince == nil {
            microphoneOnSince = now
        }
    }

    /// How long the microphone has been on without a break (0 while off).
    public func microphoneOnFor(at now: Date) -> TimeInterval {
        microphoneOnSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    /// The signals that count as a call: `raw`, without the microphone until it has been on for
    /// `Timing.microphoneCallAfter`.
    public func counted(_ raw: CallSignals, at now: Date) -> CallSignals {
        var signals = raw
        if microphoneOnSince == nil || microphoneOnFor(at: now) < Timing.microphoneCallAfter {
            signals.remove(.microphone)
        }
        return signals
    }

    /// A microphone is on but does not count as a call yet (dictation, or a call's first minute).
    public func isPending(_ raw: CallSignals, at now: Date) -> Bool {
        raw.contains(.microphone) && !counted(raw, at: now).contains(.microphone)
    }
}
