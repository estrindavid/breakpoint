import Foundation

extension Timer {
    /// A timer that first fires `interval` seconds from now (then every `interval` when
    /// `repeats`), to add to a run loop. Code that runs on Windows uses this rather than
    /// `Timer(timeInterval:repeats:block:)`: swift-corelibs-foundation's version of that initializer
    /// sets the first fire date to now, so a 10 s one-shot timer fires at once. The fire-date
    /// initializer behaves the same on every platform.
    public static func after(_ interval: TimeInterval, repeats: Bool,
                             block: @escaping @Sendable (Timer) -> Void) -> Timer {
        Timer(fire: Date().addingTimeInterval(max(0, interval)), interval: repeats ? interval : 0,
              repeats: repeats, block: block)
    }
}
