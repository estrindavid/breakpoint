import Foundation

/// Wind-down rules (SPEC §2.8). Pure.
///
/// Contract:
/// - `shouldOfferCard`: true when `settings.windDownEnabled`, today (the Breakpoint day of `now`)
///   is in `settings.stopDays`, `now` is at or after the stop time (a stop time before 05:00
///   belongs to the night of the previous day), the user has not wrapped up tonight, the card is
///   not visible and `snoozedUntil` has passed. Checked by the coordinator on each `agentFinished`.
///   A state from an earlier Breakpoint day counts as a fresh night.
/// - `holdDuration`: 3 s, then 6 s, then 10 s for every later extension that night
///   (`Timing.windDownHolds`); always 3 s when `settings.escalatingHold` is off.
/// - `extend`: increments `extensionsTonight`, snoozes for 15 min, hides the card.
/// - `wrapUp`: sets `wrappedUp`, hides the card. (The coordinator also adds the pause reason.)
/// - `rolledOver`: a fresh state when `now` is in a later Breakpoint day than `state.dayStart`.
/// - `wrapUpNote`: one line per open session (folder + snippet) via `Copy.wrapUpLine`, most
///   recent first; sessions with neither a folder nor a snippet are left out, and identical lines
///   appear once.
public enum WindDownPolicy {
    public static func shouldOfferCard(_ state: WindDownState, settings: Settings, now: Date, calendar: Calendar = .current) -> Bool {
        guard settings.windDownEnabled else { return false }
        let dayStart = BreakpointDay.start(of: now, calendar: calendar)
        let tonight = state.dayStart == dayStart ? state : WindDownState(dayStart: dayStart)
        guard !tonight.wrappedUp, !tonight.cardVisible else { return false }
        if let snoozedUntil = tonight.snoozedUntil, now < snoozedUntil { return false }
        guard settings.stopDays.contains(dayStart, calendar: calendar) else { return false }
        return now >= stopMoment(settings.stopTime, dayStart: dayStart, calendar: calendar)
    }

    /// When the stop time falls in the Breakpoint day starting at `dayStart`: that calendar day for
    /// times from 05:00, the next calendar day for times before 05:00 (00:30 is "tonight").
    public static func stopMoment(_ stopTime: TimeOfDay, dayStart: Date, calendar: Calendar = .current) -> Date {
        if stopTime.hour >= Timing.dayBoundaryHour {
            return stopTime.date(on: dayStart, calendar: calendar)
        }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        return stopTime.date(on: nextDay, calendar: calendar)
    }

    public static func holdDuration(_ state: WindDownState, settings: Settings) -> TimeInterval {
        let holds = Timing.windDownHolds
        guard settings.escalatingHold else { return holds[0] }
        return holds[min(max(state.extensionsTonight, 0), holds.count - 1)]
    }

    public static func extend(_ state: WindDownState, now: Date) -> WindDownState {
        var state = state
        state.extensionsTonight += 1
        state.snoozedUntil = now.addingTimeInterval(Timing.windDownExtension)
        state.cardVisible = false
        return state
    }

    public static func wrapUp(_ state: WindDownState, now: Date) -> WindDownState {
        var state = state
        state.wrappedUp = true
        state.snoozedUntil = nil
        state.cardVisible = false
        return state
    }

    public static func rolledOver(_ state: WindDownState, now: Date, calendar: Calendar = .current) -> WindDownState {
        let dayStart = BreakpointDay.start(of: now, calendar: calendar)
        return dayStart > state.dayStart ? WindDownState(dayStart: dayStart) : state
    }

    public static func wrapUpNote(sessions: [AgentSession]) -> [String] {
        var seen = Set<String>()
        return sessions
            .sorted { ($0.lastEventAt, $0.key) > ($1.lastEventAt, $1.key) }
            .filter { $0.projectName != nil || !($0.title ?? "").isEmpty }
            .map { Copy.wrapUpLine(folder: $0.projectName, snippet: ($0.title?.isEmpty ?? true) ? nil : $0.title) }
            .filter { seen.insert($0).inserted }
    }
}
