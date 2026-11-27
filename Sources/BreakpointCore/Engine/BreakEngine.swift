import Foundation

/// Decides what to do with an opportunity (SPEC §2.5). A **pure function** of an `EngineSnapshot`,
/// an `Opportunity` and a clock: no state, no side effects, no system calls.
///
/// Contract — evaluate in this order and return the first that applies:
/// 1. `.suppress(.surfaceVisible)` if `snapshot.surfaceVisible`.
/// 2. `.suppress(.paused(reason))` if any pause reason is active (name `pause.primaryReason`).
/// 3. `.suppress(.away)` if `snapshot.presence.isAway`.
/// 4. `.suppress(.cooldown(until))` while `pause.cooldownUntil > now`; then
///    `.suppress(.spacing(until))` while within `Timing.nudgeSpacing` of `lastNudgeAt` or
///    `lastBreakEndedAt` (`until` = the later of the two + spacing).
/// 5. `.suppress(.strictMode)` if `settings.strictAgentOnly` and the opportunity is `typingPause`;
///    `.suppress(.presenting(cause))` if a display is mirrored or kept awake
///    (`input.presentingCause`) and the opportunity is `typingPause`.
/// 6. `.hold(.typing)` if `input.isTyping`; `.hold(.pointer)` if `input.isPointerBusy`;
///    `.hold(.microphone)` while a microphone is on but not yet a call (`microphonePending`).
/// 7. If `move` is due, not kind-spaced and not held after a breather (`stretchHeldUntil`): `breathe` if `consecutiveMoveRefusals >= 2`; else
///    `walk` (length = `BreakKind.walkTarget`) if the opportunity's session's expected run length
///    ≥ `settings.walkThreshold`; else `move`.
/// 8. Else if `eyes` is due and not kind-spaced: `eyes`.
/// 9. Else `.nothing`.
///
/// "Due" means timer ≥ cadence; for `typingPause` it means timer ≥ 1.5 × cadence. The offer
/// carries `overdueBy` (timer − cadence), `timerValue` and the agent's expected run length.
/// `manual` opportunities never reach the engine (the coordinator starts the break directly).
///
/// Kind spacing for the still-time slot: `move`, `walk` and `breathe` all answer the same timer,
/// so a decline or ignore of any of them spaces the whole slot (otherwise a declined walk
/// would come back as a stretch as soon as nudge spacing ends). `eyes` is spaced on its own.
/// How long a refusal spaces its slot is `spacingAfterRefusal` (the coordinator applies it).
///
/// The expected run length is only used (for `walk` and the why-now line) when the opportunity
/// came from an agent source with recorded runs (`snapshot.expectedRunLengths` holds only those);
/// the 90 s default never makes a walk and is never quoted as "usually takes".
public enum BreakEngine {
    public static func decide(_ snapshot: EngineSnapshot, opportunity: Opportunity, now: Date) -> EngineDecision {
        // 1–3
        if snapshot.surfaceVisible { return .suppress(.surfaceVisible) }
        if let reason = snapshot.pause.primaryReason { return .suppress(.paused(reason)) }
        if snapshot.presence.isAway { return .suppress(.away) }

        // 4
        if let until = snapshot.pause.cooldownUntil, now < until { return .suppress(.cooldown(until: until)) }
        if let until = spacingUntil(snapshot), now < until { return .suppress(.spacing(until: until)) }

        // 5
        if snapshot.settings.strictAgentOnly, opportunity.kind == .typingPause { return .suppress(.strictMode) }
        if opportunity.kind == .typingPause, let cause = snapshot.input.presentingCause {
            return .suppress(.presenting(cause))
        }

        // 6
        if snapshot.input.isTyping { return .hold(.typing) }
        if snapshot.input.isPointerBusy { return .hold(.pointer) }
        if snapshot.microphonePending { return .hold(.microphone) }

        // 7–9
        let cadence = snapshot.settings.cadence
        let factor = opportunity.kind == .typingPause ? Timing.typingPauseCadenceFactor : 1
        let expected = expectedRun(snapshot, opportunity)

        let still = snapshot.timers.stillTime
        if still >= cadence.moveEvery * factor, !isSpaced(.move, snapshot, now: now) {
            let kind: BreakKind
            let length: TimeInterval
            if snapshot.consecutiveMoveRefusals >= Timing.moveRefusalsBeforeBreathe {
                kind = .breathe
                length = BreakKind.breathe.defaultLength
            } else if let expected, expected >= snapshot.settings.walkThreshold {
                kind = .walk
                length = BreakKind.walkTarget(expectedRun: expected)
            } else {
                kind = .move
                length = BreakKind.move.defaultLength
            }
            return .offer(BreakOffer(kind: kind, length: length, opportunity: opportunity,
                                     overdueBy: max(0, still - cadence.moveEvery), timerValue: still,
                                     expectedRunLength: expected))
        }

        let screen = snapshot.timers.screenTime
        if screen >= cadence.eyesEvery * factor, !isSpaced(.eyes, snapshot, now: now) {
            return .offer(BreakOffer(kind: .eyes, length: BreakKind.eyes.defaultLength, opportunity: opportunity,
                                     overdueBy: max(0, screen - cadence.eyesEvery), timerValue: screen,
                                     expectedRunLength: expected))
        }
        return .nothing
    }

    /// The end of nudge spacing: the later of the previous nudge and the end of the previous break,
    /// plus `Timing.nudgeSpacing`.
    static func spacingUntil(_ snapshot: EngineSnapshot) -> Date? {
        let anchors = [snapshot.lastNudgeAt, snapshot.lastBreakEndedAt].compactMap { $0 }
        return anchors.max()?.addingTimeInterval(Timing.nudgeSpacing)
    }

    /// How long `kind`'s slot waits after an offer of it is declined or ignored (SPEC §2.4).
    /// `refusalsInARow` includes this one. The first refusals space it for `Timing.kindSpacing`;
    /// from `Timing.refusalsBeforeCadenceSpacing` in a row, for one whole cadence of that slot, so
    /// someone who keeps saying no is asked once per cadence rather than every ten minutes.
    public static func spacingAfterRefusal(_ kind: BreakKind, refusalsInARow: Int, cadence: Cadence) -> TimeInterval {
        guard refusalsInARow >= Timing.refusalsBeforeCadenceSpacing else { return Timing.kindSpacing }
        return max(Timing.kindSpacing, cadence.interval(for: kind))
    }

    /// The kinds that share a kind-spacing slot with `kind`.
    static func spacingSlot(_ kind: BreakKind) -> [BreakKind] {
        kind == .eyes ? [.eyes] : [.move, .walk, .breathe]
    }

    static func isSpaced(_ kind: BreakKind, _ snapshot: EngineSnapshot, now: Date) -> Bool {
        if kind != .eyes, stretchHold(snapshot, now: now) != nil { return true }
        return spacingSlot(kind).contains { snapshot.kindSpacedUntil[$0].map { now < $0 } ?? false }
    }

    /// The end of the hold on the still-time slot after a breather, while it lasts (SPEC §2.3).
    public static func stretchHold(_ snapshot: EngineSnapshot, now: Date) -> Date? {
        snapshot.stretchHeldUntil.flatMap { now < $0 ? $0 : nil }
    }

    /// The opportunity's agent's median run, when that agent has recorded runs.
    static func expectedRun(_ snapshot: EngineSnapshot, _ opportunity: Opportunity) -> TimeInterval? {
        guard let source = opportunity.source, source != .shell else { return nil }
        return snapshot.expectedRunLengths[source]
    }
}
