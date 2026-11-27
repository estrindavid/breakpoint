import Foundation

/// Whether a real surface appearing now carries its one-time hint (SPEC §3.12). Pure: the
/// coordinator asks, shows the line and saves what comes back.
///
/// A hint shows only when all of these hold:
/// - Show hints is on (off for anyone who updated from a version without hints, until they turn
///   it on);
/// - onboarding is done and its window is closed;
/// - the one-minute tour is not running, and the surface is real (not the tour's sample, not a
///   Settings preview);
/// - the lesson is not known yet: never shown, and not taught by the tour;
/// - no other hint is on screen (hints never stack: the later surface shows none and its hint
///   waits for that surface's next appearance).
///
/// Showing a hint marks its whole surface known, so each surface carries one hint at most, once.
/// The tour marks only the lessons it taught, when the user answered that step: the sample nudge
/// (Start or Not now), the sample break (it ended) and the sample resume card (Next or a click).
/// What it cannot teach stays: an eye rest that starts by itself, a resume card that waits because
/// an agent needs you, Option-click on the mark, the call pause.
/// A hint never delays, holds or changes anything else about its surface.
public enum HintPolicy {
    public struct Context: Equatable, Sendable {
        /// The one-minute tour is running.
        public var tourRunning: Bool
        /// The onboarding window is open (also a later run of it).
        public var onboardingOpen: Bool
        /// Another surface shows its hint right now.
        public var hintOnScreen: Bool
        /// The surface is a Settings preview or the tour's sample, not real use.
        public var isPreview: Bool

        public init(tourRunning: Bool = false, onboardingOpen: Bool = false, hintOnScreen: Bool = false,
                    isPreview: Bool = false) {
            self.tourRunning = tourRunning
            self.onboardingOpen = onboardingOpen
            self.hintOnScreen = hintOnScreen
            self.isPreview = isPreview
        }
    }

    public static func shows(_ lesson: HintLesson, settings: Settings, context: Context) -> Bool {
        settings.showHints
            && settings.hasCompletedOnboarding
            && !context.onboardingOpen
            && !context.tourRunning
            && !context.isPreview
            && !context.hintOnScreen
            && !settings.hintsSeen.contains(lesson)
    }

    /// `settings` once `lesson`'s hint has shown: every lesson of its surface is known.
    public static func markingShown(_ lesson: HintLesson, in settings: Settings) -> Settings {
        marking(HintLesson.allCases.filter { $0.surface == lesson.surface }, in: settings)
    }

    /// `settings` once the tour taught `lessons` (whatever Show hints says, so turning hints on
    /// later never repeats what the tour showed).
    public static func markingTaught(_ lessons: [HintLesson], in settings: Settings) -> Settings {
        marking(lessons, in: settings)
    }

    private static func marking(_ lessons: [HintLesson], in settings: Settings) -> Settings {
        guard lessons.contains(where: { !settings.hintsSeen.contains($0) }) else { return settings }
        var updated = settings
        updated.hintsSeen += lessons
        return updated.normalized()
    }

    /// What the tour taught when the user answered `step` and it moved on to `next`.
    public static func taught(leaving step: TourStep, for next: TourStep) -> [HintLesson] {
        guard step != next else { return [] }
        switch step {
        case .nudge: return [.nudge]
        case .breakScreen: return [.breakScreen]
        case .resumeCard: return [.resumeCard]
        case .offer, .mark, .declined, .popover, .farewell: return []
        }
    }

    /// The nudge's lesson: an eye rest that starts by itself has its own.
    public static func nudgeLesson(autoStart: Bool) -> HintLesson { autoStart ? .autoStart : .nudge }

    /// The resume card's lesson: a card that waits for you has its own.
    public static func resumeLesson(needsYou: Bool) -> HintLesson { needsYou ? .resumeNeedsYou : .resumeCard }

    /// The lessons still to come, in a stable order (the debug state).
    public static func pending(_ settings: Settings) -> [HintLesson] {
        HintLesson.allCases.filter { !settings.hintsSeen.contains($0) }
    }

    /// The call-pause toast appears when a due break or a visible nudge was affected (SPEC §3.5,
    /// decision 17), and once more, the first time a call pauses breaks, to carry its hint.
    public static func showsCallPauseToast(nudgeWasVisible: Bool, breakDue: Bool, hintShows: Bool) -> Bool {
        nudgeWasVisible || breakDue || hintShows
    }
}
