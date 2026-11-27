import Foundation

/// What Breakpoint is waiting for right now (SPEC §3.7 "Why not now?", §3.8). A pure function of
/// the same `EngineSnapshot` the engine decides on: it asks `BreakEngine.decide` about the held
/// opportunity, or about an agent starting this very moment, and names the answer. So the line is
/// true at the moment it is computed, and it only uses facts the app shows elsewhere (timers, pause,
/// agents and their states, typing).
public enum WaitReason: Equatable, Hashable, Sendable {
    /// The break overlay is up.
    case onBreak
    /// A nudge or the eye-rest countdown is showing.
    case offering
    case paused(PauseReason)
    case away
    /// Neither timer has reached its cadence.
    case nothingDue(next: BreakKind, in: TimeInterval)
    /// The resume cool-down after a pause, a return from away, unlock or wake.
    case easingBackIn(until: Date)
    /// Nudge spacing after the previous nudge or break.
    case spacingNudges(until: Date)
    /// Every due kind was offered a few minutes ago (kind spacing). `kind` is the one due first.
    case spacingKind(BreakKind, until: Date)
    /// The person took a breather: the stretch (still-time slot) waits one move cadence from its
    /// end (SPEC §2.3), and no eye rest is due meanwhile.
    case afterBreather(until: Date)
    /// An opportunity arrived while input was busy; it is offered as soon as input is quiet.
    case holding(HoldReason)
    /// A break is due and nothing holds it back: the next opportunity offers it.
    case waiting(Waiting)

    /// The opportunity a due break is waiting for, with the facts that say why it has not come.
    public struct Waiting: Equatable, Hashable, Sendable {
        public enum Next: Sendable, Hashable {
            /// A pause in typing may offer it (the timer is at 1.5 × its cadence).
            case typingPause
            /// Only an agent run (or a long command) can offer it: not yet 1.5 × the cadence.
            case agentRun
            /// "Only during agent runs" is on.
            case agentRunOnly
        }

        public var due: BreakKind
        public var next: Next
        /// A key was pressed within the typing-pause quiet time.
        public var typing: Bool
        /// The most urgent agent: its name and state; `nil` when no session is tracked.
        public var agent: AgentFact?
        /// The presenting guard, when it is the reason a pause in typing would not offer the break
        /// (SPEC §2.4): only an agent run can, until the display is no longer mirrored or kept awake.
        public var quiet: PresentingCause?

        public init(due: BreakKind, next: Next, typing: Bool, agent: AgentFact?, quiet: PresentingCause? = nil) {
            self.due = due
            self.next = next
            self.typing = typing
            self.agent = agent
            self.quiet = quiet
        }
    }

    public struct AgentFact: Equatable, Hashable, Sendable {
        public var name: String
        public var state: AgentState
        /// How many sessions share that state (≥ 2 reads "2 agents are working").
        public var count: Int

        public init(name: String, state: AgentState, count: Int = 1) {
            self.name = name
            self.state = state
            self.count = count
        }
    }

    /// The popover shows the line only when it adds something to its status block: a break is due
    /// and not on offer, and nothing paused it (the caption already says "Paused: …").
    public var explainsADueBreak: Bool {
        switch self {
        case .easingBackIn, .spacingNudges, .spacingKind, .afterBreather, .holding, .waiting: return true
        case .onBreak, .offering, .paused, .away, .nothingDue: return false
        }
    }
}

public enum WhyNotNow {
    /// Why no nudge is showing at `now`.
    /// - `held`: the opportunity the typing guard is holding, if any (it is what the engine is
    ///   actually deciding on).
    /// - `onBreak`: the overlay is up (a visible surface is otherwise a nudge or countdown).
    public static func explain(_ snapshot: EngineSnapshot, held: Opportunity?, onBreak: Bool, now: Date) -> WaitReason {
        if onBreak { return .onBreak }
        let candidate = held.flatMap { $0.isExpired(at: now) ? nil : $0 }
            ?? Opportunity(kind: .agentStarted, createdAt: now)
        let isHeld = held != nil && candidate.id == held?.id
        let decision = BreakEngine.decide(snapshot, opportunity: candidate, now: now)
        switch decision {
        case .suppress(.strictMode), .suppress(.presenting), .hold:
            // Strict mode, the presenting guard and the holds (steps 5–6) come before the timers in
            // the engine, but they only keep back a break that is due. When every due kind is
            // spaced (after a refusal, a whole cadence from the third in a row, or after a
            // breather), that is the true answer: nothing would be offered once they lift.
            if dueKind(snapshot, now: now) == nil { return notOffered(snapshot, now: now) }
        default:
            break
        }
        switch decision {
        case .suppress(.surfaceVisible): return .offering
        case .suppress(.paused(let reason)): return .paused(reason)
        case .suppress(.away): return .away
        case .suppress(.cooldown(let until)): return .easingBackIn(until: until)
        case .suppress(.spacing(let until)): return .spacingNudges(until: until)
        case .suppress(.strictMode), .suppress(.presenting):
            // A held typing pause with strict mode switched on, or a display mirrored or kept
            // awake, since: only agent runs offer now.
            return waiting(snapshot, due: dueKind(snapshot, now: now) ?? .eyes)
        case .hold(let reason):
            if isHeld { return .holding(reason) }
            return waiting(snapshot, due: dueKind(snapshot, now: now) ?? .eyes)
        case .offer(let offer):
            // Held and now quiet: the next tick offers it.
            return isHeld ? .offering : waiting(snapshot, due: offer.kind)
        case .nothing:
            return notOffered(snapshot, now: now)
        }
    }

    /// The kind the engine would offer for an opportunity now, ignoring everything but the timers,
    /// kind spacing and the breather hold (steps 7–8 of `BreakEngine.decide`).
    static func dueKind(_ snapshot: EngineSnapshot, now: Date) -> BreakKind? {
        let cadence = snapshot.settings.cadence
        if snapshot.timers.stillTime >= cadence.moveEvery, !BreakEngine.isSpaced(.move, snapshot, now: now) { return .move }
        if snapshot.timers.screenTime >= cadence.eyesEvery, !BreakEngine.isSpaced(.eyes, snapshot, now: now) { return .eyes }
        return nil
    }

    /// The engine found nothing to offer: either nothing is due, or every due kind is spaced or
    /// held.
    static func notOffered(_ snapshot: EngineSnapshot, now: Date) -> WaitReason {
        let cadence = snapshot.settings.cadence
        let timers = snapshot.timers
        var spaced: [(reason: WaitReason, until: Date)] = []
        if timers.stillTime >= cadence.moveEvery {
            // The later of kind spacing and the breather hold is the one that decides.
            let kindUntil = spacedUntil(.move, snapshot, now: now)
            let holdUntil = BreakEngine.stretchHold(snapshot, now: now)
            if let holdUntil, holdUntil >= (kindUntil ?? .distantPast) {
                spaced.append((.afterBreather(until: holdUntil), holdUntil))
            } else if let kindUntil {
                spaced.append((.spacingKind(.move, until: kindUntil), kindUntil))
            }
        }
        if timers.screenTime >= cadence.eyesEvery, let until = spacedUntil(.eyes, snapshot, now: now) {
            spaced.append((.spacingKind(.eyes, until: until), until))
        }
        if let first = spaced.min(by: { $0.until < $1.until }) {
            return first.reason
        }
        let eyesIn = cadence.eyesEvery - timers.screenTime
        let moveIn = cadence.moveEvery - timers.stillTime
        return moveIn <= eyesIn ? .nothingDue(next: .move, in: max(0, moveIn)) : .nothingDue(next: .eyes, in: max(0, eyesIn))
    }

    static func spacedUntil(_ kind: BreakKind, _ snapshot: EngineSnapshot, now: Date) -> Date? {
        BreakEngine.spacingSlot(kind).compactMap { snapshot.kindSpacedUntil[$0] }.filter { now < $0 }.max()
    }

    static func waiting(_ snapshot: EngineSnapshot, due: BreakKind) -> WaitReason {
        let next: WaitReason.Waiting.Next
        var quiet: PresentingCause?
        if snapshot.settings.strictAgentOnly {
            next = .agentRunOnly
        } else if OpportunityDetector.isWellOverdue(snapshot.timers, cadence: snapshot.settings.cadence) {
            // A pause in typing would offer it, unless the presenting guard is on (SPEC §2.4).
            quiet = snapshot.input.presentingCause
            next = quiet == nil ? .typingPause : .agentRun
        } else {
            next = .agentRun
        }
        return .waiting(.init(due: due, next: next, typing: snapshot.input.secondsSinceKey < Timing.typingPauseQuiet,
                              agent: agentFact(snapshot.sessions), quiet: quiet))
    }

    /// The most urgent session (needs you > working > idle), with how many share its state.
    static func agentFact(_ sessions: [AgentSession]) -> WaitReason.AgentFact? {
        guard let top = sessions.max(by: { ($0.state.urgency, $0.lastEventAt) < ($1.state.urgency, $1.lastEventAt) })
        else { return nil }
        let count = sessions.filter { $0.state == top.state }.count
        return WaitReason.AgentFact(name: top.displayName, state: top.state, count: count)
    }
}
