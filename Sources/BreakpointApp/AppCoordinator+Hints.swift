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
            popoverOpenedAt = currentDate()
            popoverClosedBy = nil
            popoverHint = takeHint(.popover) ? HintCopy.popover : nil
        } else {
            popoverHint = nil
            recordSurface("popover closed")
            // Closed during the tour's look at it: the tour moves on to its last card.
            if tour?.step == .popover { handleTour(.popoverClosed) }
        }
        publish()
    }

    /// Something that may close the popover happened (SPEC §3.8): `PopoverPolicy` decides. Only the
    /// tour naming its parts, the first-use hint or the pointer on the popover keep it open, and
    /// only against the menu bar sliding away.
    func popoverMayClose(_ cause: PopoverCloseCause, pointerOnPopover: Bool) {
        guard popoverOpen else { return }
        let context = PopoverPolicy.Context(
            tourStep: tour?.step == .popover, showsHint: popoverHint != nil, pointerOnPopover: pointerOnPopover,
            secondsOpen: popoverOpenedAt.map { currentDate().timeIntervalSince($0) } ?? .infinity)
        guard PopoverPolicy.closes(for: cause, context: context) else {
            recordSurface("popover stays open after \(cause.phrase)")
            return
        }
        popoverClosedBy = cause
        recordSurface("popover closing: \(cause.phrase)")
        closePopover()
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
