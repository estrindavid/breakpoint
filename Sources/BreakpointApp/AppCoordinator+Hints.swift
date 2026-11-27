import Foundation
import BreakpointCore
import BreakpointKit

// First-use hints (SPEC §3.12). `HintPolicy` (Core) decides; this file keeps what is on screen,
// saves what is known, and lets the tour mark what it taught.

extension AppCoordinator {
    /// A hint is on screen now (hints never stack).
    var hintOnScreen: Bool {
        if nudge?.hint != nil || breakHintID != nil || popoverHint != nil { return true }
        return cards.contains { card in
            switch card.content {
            case .resume(let content): return content.hint != nil
            case .toast(let toast): return toast.hint != nil
            default: return false
            }
        }
    }

    /// Whether a surface appearing now carries `lesson`'s hint. If it does, its surface is marked
    /// known and saved at once, so it never carries one again.
    func takeHint(_ lesson: HintLesson, isPreview: Bool = false) -> Bool {
        let context = HintPolicy.Context(tourRunning: tour != nil, onboardingOpen: onboarding?.isVisible == true,
                                         hintOnScreen: hintOnScreen, isPreview: isPreview)
        guard HintPolicy.shows(lesson, settings: settings, context: context) else { return false }
        settings = HintPolicy.markingShown(lesson, in: settings)
        saveSettings()
        recordSurface("hint shown: \(lesson.rawValue)")
        return true
    }

    /// The tour moved from `previous` to `next`: what the user just answered is known now.
    func learnFromTour(leaving previous: TourStep, for next: TourStep) {
        let lessons = HintPolicy.taught(leaving: previous, for: next)
        let updated = HintPolicy.markingTaught(lessons, in: settings)
        guard updated != settings else { return }
        settings = updated
        saveSettings()
        recordSurface("taught by the tour: " + lessons.map(\.rawValue).joined(separator: ", "))
    }

    /// The popover opened or closed, however it happened (a click, the shortcut, the tour).
    func popoverVisibilityChanged(_ open: Bool) {
        guard open != popoverOpen else { return }
        popoverOpen = open
        if open {
            popoverHint = takeHint(.popover) ? HintCopy.popover : nil
        } else {
            popoverHint = nil
            recordSurface("popover closed")
            // Closed during the tour's look at it: the tour moves on to its last card.
            if tour?.step == .popover { handleTour(.popoverClosed) }
        }
        publish()
    }

    /// Closes the popover (headless: as if it closed).
    func closePopover() {
        if let statusItem {
            statusItem.closePopover()
        } else {
            popoverVisibilityChanged(false)
        }
    }
}
