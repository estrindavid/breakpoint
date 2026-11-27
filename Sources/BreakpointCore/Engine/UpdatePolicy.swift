import Foundation

/// What the app is doing right now, as far as the update check cares (SPEC §2.11).
public struct UpdateMoment: Equatable, Sendable {
    /// Onboarding finished (nothing is checked or offered before).
    public var onboarded: Bool
    /// A break (or a preview of one) is on screen.
    public var breakActive: Bool
    /// The nudge or the countdown chip is on screen.
    public var nudgeVisible: Bool
    /// Any other pop-up is on screen (resume card, away note, toast, wind-down, an earlier prompt).
    public var cardsVisible: Bool
    /// Breaks are paused for any reason: a call, a pause the person chose, wrap-up.
    public var paused: Bool
    /// A microphone or camera is in use (whether or not that pauses breaks).
    public var callActive: Bool
    public var away: Bool
    /// Seconds since the last key press.
    public var secondsSinceKey: TimeInterval

    public init(onboarded: Bool = true, breakActive: Bool = false, nudgeVisible: Bool = false, cardsVisible: Bool = false,
                paused: Bool = false, callActive: Bool = false, away: Bool = false,
                secondsSinceKey: TimeInterval = .infinity) {
        self.onboarded = onboarded
        self.breakActive = breakActive
        self.nudgeVisible = nudgeVisible
        self.cardsVisible = cardsVisible
        self.paused = paused
        self.callActive = callActive
        self.away = away
        self.secondsSinceKey = secondsSinceKey
    }
}

/// When to check for a new version and when to mention it. Pure: values in, values out; the
/// coordinator does the fetching, the saving and the showing.
public enum UpdatePolicy {
    /// No check runs during a break, a call, a pause, or while any pop-up is on screen.
    public static func mayCheck(_ moment: UpdateMoment) -> Bool {
        moment.onboarded && !moment.breakActive && !moment.nudgeVisible && !moment.cardsVisible
            && !moment.paused && !moment.callActive
    }

    /// The prompt needs all of that, plus the person at the Mac and not typing.
    public static func mayPrompt(_ moment: UpdateMoment) -> Bool {
        mayCheck(moment) && !moment.away && moment.secondsSinceKey >= Timing.updatePromptQuiet
    }

    /// An automatic check is due: the setting is on, the app has been running a little while, and
    /// a day has passed since the last attempt (three hours after one that failed).
    public static func checkIsDue(_ record: UpdateRecord, automatic: Bool, launchedAt: Date, now: Date) -> Bool {
        guard automatic, now.timeIntervalSince(launchedAt) >= Timing.updateFirstCheckDelay else { return false }
        guard let last = record.lastAttemptAt else { return true }
        // A clock set back (or a record from the future) counts as due rather than never.
        if last > now { return true }
        let wait = record.lastAttemptFailed ? Timing.updateRetryAfterFailure : Timing.updateCheckInterval
        return now.timeIntervalSince(last) >= wait
    }

    /// The release the record knows of that is newer than `current` and runs on `system`, if any.
    public static func available(_ record: UpdateRecord, current: SemanticVersion,
                                 system: SemanticVersion) -> UpdateRelease? {
        guard let latest = record.latest, let version = latest.semanticVersion, version > current,
              latest.runs(on: system) else { return nil }
        return latest
    }

    /// Show the prompt now: an update is available, the person has not put it off, and the moment
    /// is quiet.
    public static func shouldPrompt(_ record: UpdateRecord, current: SemanticVersion, system: SemanticVersion,
                                    moment: UpdateMoment, now: Date) -> Bool {
        guard let release = available(record, current: current, system: system), mayPrompt(moment) else { return false }
        return !isPostponed(record, version: release.version, now: now)
    }

    /// Install without asking: the person turned that on, this copy can install, the release is
    /// signed, it has not failed before (an automatic attempt that stopped postpones it), and the
    /// moment is as quiet as for the prompt.
    public static func shouldInstallAutomatically(_ record: UpdateRecord, current: SemanticVersion, system: SemanticVersion,
                                                  automatic: Bool, canInstall: Bool, moment: UpdateMoment, now: Date) -> Bool {
        guard automatic, canInstall, let release = available(record, current: current, system: system),
              release.isInstallable, record.installFailedVersion != release.version,
              !isPostponed(record, version: release.version, now: now) else { return false }
        return mayPrompt(moment)
    }

    public static func isPostponed(_ record: UpdateRecord, version: String, now: Date) -> Bool {
        guard record.postponedVersion == version, let until = record.postponedUntil else { return false }
        return now < until
    }

    // MARK: Transitions

    /// A check reached the feed.
    public static func checked(_ record: UpdateRecord, release: UpdateRelease, now: Date) -> UpdateRecord {
        var r = record
        r.lastAttemptAt = now
        r.lastCheckedAt = now
        r.lastAttemptFailed = false
        r.latest = release
        return r
    }

    /// A check failed (offline, no feed, a feed that does not parse). What was known stays known.
    public static func failed(_ record: UpdateRecord, now: Date) -> UpdateRecord {
        var r = record
        r.lastAttemptAt = now
        r.lastAttemptFailed = true
        return r
    }

    /// An install of `version` failed or was rolled back.
    public static func installFailed(_ record: UpdateRecord, version: String) -> UpdateRecord {
        var r = record
        r.installFailedVersion = version
        return r
    }

    /// "Later", Download, or the prompt hid itself: do not ask about `version` again for a while.
    public static func postponed(_ record: UpdateRecord, version: String, now: Date) -> UpdateRecord {
        var r = record
        r.postponedVersion = version
        r.postponedUntil = now.addingTimeInterval(Timing.updatePostpone)
        return r
    }
}
