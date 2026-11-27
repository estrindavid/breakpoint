import Foundation
import BreakpointCore
import BreakpointKit

// A break you can follow without watching the screen (SPEC §3.3 Ending, §3.4, §4.7): the soft
// tick at each step change, the walk's idea line, and the closing moment of a completed break.

/// The closing moment the overlay shows after a break completed: the break's last state with its
/// closing line, until `until` (`Timing.completionMoment` after it completed).
struct CompletionMoment {
    var state: ActiveBreakState
    var until: Date
}

extension AppCoordinator {
    /// Plays the soft tick when time moved a stretch to its next step (never during a call).
    func playStepTickIfDue(from previous: BreakSession, to next: BreakSession) {
        if BreakSessionRules.playsStepTick(from: previous, to: next, settings: settings, callSignals: monitor.callSignals) {
            sound.play(.stepTick, volume: settings.volume)
        }
    }

    /// The walk's idea line, from its own shuffle bag (a preview shows the next one and changes
    /// nothing).
    func drawWalkIdea(isPreview: Bool) -> String {
        let ideas = BreakCopyLibrary.walkIdeas
        let draw = CopyRotation.draw(bag: BreakCopyLibrary.walkIdeaBag, count: ideas.count, state: rotation)
        if !isPreview {
            rotation = draw.state
            saveRotation()
        }
        return ideas[draw.index]
    }

    /// Shows the closing moment of `session`, which has just completed (not ended early, not a
    /// preview, not Back to work: the user is on the way to their agent).
    func beginCompletion(_ session: BreakSession, now: Date) {
        let templates = BreakCopyLibrary.closingTemplates(session.kind)
        let draw = CopyRotation.draw(bag: BreakCopyLibrary.closingBag(session.kind), count: templates.count, state: rotation)
        rotation = draw.state
        saveRotation()
        var state = activeBreakState(session, now: now)
        state.needsYou = false
        let line = BreakCopyLibrary.closingLine(kind: session.kind, rotation: draw.index, elapsed: session.elapsed(at: now),
                                                routine: session.routine)
        state.completion = BreakCompletionState(line: line, at: state.elapsed)
        completionMoment = CompletionMoment(state: state, until: now.addingTimeInterval(Timing.completionMoment))
        // End it on time rather than at the next 1 s tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.completionMoment + 0.02) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endCompletionIfDue(now: self.currentDate())
            }
        }
    }

    /// Ends the closing moment once its time is up.
    func endCompletionIfDue(now: Date) {
        guard let moment = completionMoment, now >= moment.until else { return }
        completionMoment = nil
        publish(now: now)
    }

    /// Ends the closing moment at once (Esc, Return or Done during it).
    func endCompletionNow() {
        guard completionMoment != nil else { return }
        completionMoment = nil
        publish()
    }
}
