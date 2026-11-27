import Foundation

/// How a break ended, as seen by `BreakSessionRules.outcome`.
public enum BreakEnd: Equatable, Sendable {
    /// Skip (after the 3 s guard), or Esc twice.
    case skip
    /// Done, I'm back / Welcome back, Back to work.
    case finish(BreakFinishReason)
    /// The timer reached 0 (never for `walk`).
    case timerEnded
    /// The hard ceiling was hit (planned + extensions + 60 s; walk 30 min).
    case ceiling
}

/// The rules of a break in progress (SPEC §3.3, §3.4). Pure.
public enum BreakSessionRules {
    /// A new session for `kind`. `move` plays `routine` (the rotation's pick; default: the first
    /// allowed for `settings`); `walk` gets the walk target from `expectedRun` (default 5 min);
    /// `copyRotation` is the copy variant index.
    public static func makeSession(
        kind: BreakKind,
        opportunity: Opportunity?,
        settings: Settings,
        expectedRun: TimeInterval?,
        agentName: String?,
        copyRotation: Int,
        now: Date,
        isPreview: Bool = false,
        routine chosen: Routine? = nil
    ) -> BreakSession {
        let routine = kind == .move ? (chosen ?? BuiltInRoutines.routine(for: settings)) : nil
        let length: TimeInterval
        switch kind {
        case .walk: length = BreakKind.walkTarget(expectedRun: expectedRun ?? BreakKind.walk.defaultLength)
        case .move: length = routine?.totalDuration ?? kind.defaultLength
        default: length = kind.defaultLength
        }
        return BreakSession(
            kind: kind,
            startedAt: now,
            plannedLength: isPreview ? min(length, Timing.previewLength) : length,
            routine: routine,
            copy: BreakCopyLibrary.variant(for: kind, rotation: copyRotation, agentName: agentName),
            opportunity: opportunity,
            isPreview: isPreview)
    }

    /// Skip is disabled for the first 3 s.
    public static func isSkipEnabled(_ session: BreakSession, now: Date) -> Bool {
        session.elapsed(at: now) >= Timing.skipGuard
    }

    /// Skip relabels to Done once ≥ 80% of the planned length elapsed (not on `walk`).
    public static func isDoneAvailable(_ session: BreakSession, now: Date) -> Bool {
        session.kind != .walk && session.elapsed(at: now) >= Timing.doneFraction * session.totalLength
    }

    /// "1 more minute": `move` and `breathe` only, at most twice.
    public static func canExtend(_ session: BreakSession) -> Bool {
        session.kind.allowsExtension && session.extensionsUsed < Timing.maxExtensions
    }

    /// Adds 60 s; on `move` appends a minute replayed from the routine's own steps
    /// (`RoutineReplay`).
    public static func extended(_ session: BreakSession) -> BreakSession {
        guard canExtend(session) else { return session }
        var s = session
        s.extensionsUsed += 1
        if s.kind == .move, let routine = s.routine {
            s.routine = routine.appending(RoutineReplay.extraMinute(for: routine, plannedLength: session.plannedLength,
                                                                    extension: s.extensionsUsed))
        }
        return s
    }

    /// Moves to the next / previous step by hand (→ / ←).
    public static func stepped(_ session: BreakSession, by delta: Int, now: Date) -> BreakSession {
        guard let routine = session.routine, !routine.steps.isEmpty else { return session }
        var s = session
        let index = min(max(session.stepIndex + delta, 0), routine.steps.count - 1)
        guard index != session.stepIndex else { return session }
        s.stepIndex = index
        s.stepStartedAt = now
        return s
    }

    /// Advances to the next step when the current step's time is up.
    public static func advanced(_ session: BreakSession, now: Date) -> BreakSession {
        guard let step = session.currentStep, let routine = session.routine else { return session }
        guard now.timeIntervalSince(session.stepStartedAt) >= step.duration,
              session.stepIndex < routine.steps.count - 1 else { return session }
        var s = session
        s.stepIndex += 1
        s.stepStartedAt = session.stepStartedAt.addingTimeInterval(step.duration)
        return s
    }

    /// The soft step tick plays when time (not ← / →) moved a real stretch to its next step, the
    /// setting is on and no call signal is active (SPEC §4.7).
    public static func playsStepTick(from previous: BreakSession, to next: BreakSession, settings: Settings,
                                     callSignals: CallSignals) -> Bool {
        next.kind == .move && !next.isPreview && settings.stepTick && settings.volume > 0 && callSignals.isEmpty
            && previous.id == next.id && next.stepIndex > previous.stepIndex
    }

    /// Seconds left in the current step (`move`).
    public static func stepRemaining(_ session: BreakSession, now: Date) -> TimeInterval {
        guard let step = session.currentStep else { return 0 }
        return max(0, step.duration - now.timeIntervalSince(session.stepStartedAt))
    }

    /// The timer reached 0 (never for `walk`, which waits for I'm back).
    public static func timerEnded(_ session: BreakSession, now: Date) -> Bool {
        session.kind != .walk && session.elapsed(at: now) >= session.totalLength
    }

    /// Seconds after start at which the watchdog ceiling closes the overlay.
    public static func ceiling(_ session: BreakSession) -> TimeInterval {
        session.kind == .walk ? Timing.walkCeiling : session.totalLength + Timing.overlayCeilingSlack
    }

    public static func hitCeiling(_ session: BreakSession, now: Date) -> Bool {
        session.elapsed(at: now) >= ceiling(session)
    }

    /// The outcome to record (SPEC §2.7, §3.3, §3.4). A break the person started counts however
    /// briefly it ran and however it ends: Skip (or Esc twice) is just less time, like I'm back,
    /// and records `endedEarly` (or `completed` past 80%). A started break is never `skipped`.
    public static func outcome(for end: BreakEnd, session: BreakSession, now: Date) -> BreakOutcome {
        let reachedEighty = session.elapsed(at: now) >= Timing.doneFraction * session.totalLength
        switch end {
        case .finish(.done): return .completed
        case .skip, .finish(.imBack), .finish(.backToWork): return reachedEighty ? .completed : .endedEarly
        case .timerEnded: return .completed
        case .ceiling: return session.kind == .walk && !reachedEighty ? .endedEarly : .completed
        }
    }
}
