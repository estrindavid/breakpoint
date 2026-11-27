import Foundation

/// Why Breakpoint is keeping quiet because the person is presenting or watching (SPEC §2.4). Read
/// without a permission and without naming any app.
public enum PresentingCause: String, Codable, Sendable, Hashable, CaseIterable {
    /// Some display is in a mirror set (a projector or a TV showing the same picture).
    case displayMirrored
    /// Some process holds a display-sleep assertion (slides, a video, a keep-awake tool).
    case displayKeptAwake

    /// "a display is mirrored", "the display is kept awake".
    public var phrase: String {
        switch self {
        case .displayMirrored: return "a display is mirrored"
        case .displayKeptAwake: return "the display is kept awake"
        }
    }
}

extension InputSample {
    /// The presenting guard's cause, if it is on (SPEC §2.4). A mirrored display wins: it is the
    /// stronger sign of a room watching the screen (slides usually keep the display awake too).
    ///
    /// While it is on, Breakpoint gets quieter, not silent (keep-awake tools hold the assertion all
    /// day): a pause in typing offers nothing (`BreakEngine`, step 5) and an eye rest never starts
    /// by itself. An agent run or a long command still brings the small nudge, which starts nothing
    /// unless the person chooses Start.
    public var presentingCause: PresentingCause? {
        if displayMirrored { return .displayMirrored }
        if displaySleepPrevented { return .displayKeptAwake }
        return nil
    }
}

/// When an eye rest may count down and start by itself, and when a running countdown stops
/// (SPEC §3.1). Pure.
public enum AutoStartRules {
    /// Whether an eye-rest offer may count down now: not while presenting or watching, and not
    /// while a microphone is on (someone dictating is still at work).
    public static func allows(_ sample: InputSample, microphonePending: Bool) -> Bool {
        sample.presentingCause == nil && !microphonePending
    }

    /// True when, since the countdown began `runningFor` seconds ago, the person pressed a key,
    /// clicked or dragged, or scrolled (reading), or the countdown is no longer allowed.
    public static func cancels(_ sample: InputSample, runningFor: TimeInterval, microphonePending: Bool) -> Bool {
        sample.secondsSinceKey < runningFor
            || sample.secondsSinceDrag < runningFor
            || sample.secondsSinceScroll < runningFor
            || !allows(sample, microphonePending: microphonePending)
    }
}
