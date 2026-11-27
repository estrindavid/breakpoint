import Foundation
@testable import BreakpointCore

/// Builders shared by the core-logic tests. Every time comes from the fixed `Fixture` clock.
enum Make {
    static let minute: TimeInterval = 60

    /// A quiet, present input sample: no key for 30 s, no drag, last input 1 s ago.
    static func quiet(at date: Date) -> InputSample {
        InputSample(takenAt: date, secondsSinceKey: 30, secondsSinceAnyInput: 1, secondsSinceDrag: 30)
    }

    /// An engine snapshot with quiet input and the given timers.
    static func snapshot(
        at now: Date,
        screen: TimeInterval = 0,
        still: TimeInterval = 0,
        settings: Settings = .defaults,
        input: InputSample? = nil
    ) -> EngineSnapshot {
        EngineSnapshot(settings: settings, timers: TimerState(screenTime: screen, stillTime: still),
                       input: input ?? quiet(at: now))
    }

    static func opportunity(_ kind: OpportunityKind, source: AgentSource? = nil, session: String? = nil,
                            at now: Date) -> Opportunity {
        Opportunity(kind: kind, source: source, sessionID: session,
                    commandName: kind == .longCommand ? "swift" : nil, createdAt: now)
    }

    static func event(_ kind: AgentEventKind, _ source: AgentSource = .claudeCode, session: String? = "s1",
                      cwd: String? = "/Users/dev/breakpoint", title: String? = nil, detail: String? = nil,
                      via: String? = nil, at date: Date) -> AgentEvent {
        AgentEvent(kind: kind, source: source, sessionID: session, cwd: cwd, title: title, detail: detail,
                   via: via, timestamp: date)
    }
}

extension Date {
    /// `self` plus `minutes` minutes.
    func plus(minutes: Double) -> Date { addingTimeInterval(minutes * 60) }
    func plus(seconds: Double) -> Date { addingTimeInterval(seconds) }
}
