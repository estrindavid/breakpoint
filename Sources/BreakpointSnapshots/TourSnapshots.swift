import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

// The one-minute tour (SPEC §3.12): every step's coach line on the surface it explains. The
// whole tour in its real places, on a drawn desktop, is `TourFilm` (--tour-film / --tour-still).

@MainActor
enum TourSnapshots {
    static var all: [Snapshot] {
        var list: [Snapshot] = [
            Snapshot("tour/1-offer", variants: SnapshotVariant.accessibility, padding: 32) {
                TourCoachCard(tour: .at(.offer), pointerX: CoachCaption.width / 2, actions: .noop)
            },
            Snapshot("tour/2-mark", variants: SnapshotVariant.accessibility, padding: 32) {
                TourCoachCard(tour: .at(.mark), pointerX: CoachCaption.width / 2, actions: .noop)
            },
            Snapshot("tour/3-nudge", variants: SnapshotVariant.accessibility, padding: 32) {
                TourScenes.nudge()
            },
            Snapshot("tour/3b-not-now", padding: 32) {
                TourCoachCard(tour: .at(.declined), pointerX: nil, actions: .noop)
            },
            Snapshot("tour/4-break-working", size: OverlayFilm.size, scenes: SnapshotScene.darkOnly) {
                TourScenes.breakScreen(elapsed: 2)
            },
            Snapshot("tour/4-break-done", size: OverlayFilm.size, scenes: SnapshotScene.darkOnly) {
                TourScenes.breakScreen(elapsed: 9)
            },
            Snapshot("tour/5-resume", variants: SnapshotVariant.accessibility, padding: 32) {
                TourScenes.resume()
            },
        ]
        for part in TourPopoverPart.allCases {
            list.append(Snapshot("tour/6-popover-\(part.rawValue + 1)-\(part)", padding: 32) {
                TourScenes.popover(part)
            })
        }
        list.append(Snapshot("tour/7-farewell", padding: 32) {
            TourCoachCard(tour: .at(.farewell), pointerX: CoachCaption.width / 2, actions: .noop)
        })
        // A tour started with the nudge hotkeys off: the coach line names no keys.
        list.append(Snapshot("tour/3-nudge-hotkeys-off", padding: 32) { TourScenes.nudge(hotkeys: false) })
        // Settings → General → Getting started (Take the tour, Show hints): `settings/general-full`.
        return list
    }
}

/// The first-use hints on the real surfaces (SPEC §3.12), each as it first appears.
@MainActor
enum HintSnapshots {
    static var all: [Snapshot] {
        [
            Snapshot("hints/nudge", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
                NudgeCardView(nudge: nudge(.nudge), actions: .noop)
            },
            Snapshot("hints/nudge-autostart", scenes: SnapshotScene.allBackdrops) {
                NudgeCardView(nudge: nudge(.autoStart), actions: .noop)
            },
            BreakSnapshots.overlay("hints/break", desktop: .wallpaper) { firstBreak(lead: HintCopy.breakChip(agent: "Claude")) },
            BreakSnapshots.overlay("hints/break-no-agent", desktop: .plain) { firstBreak(lead: HintCopy.breakNoAgent, agent: false) },
            Snapshot("hints/resume", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
                ResumeCardView(card: resume(.one, hint: HintCopy.resumeCard), onDismiss: {})
            },
            Snapshot("hints/resume-needs-you", scenes: SnapshotScene.allBackdrops) {
                ResumeCardView(card: resume(.needsYou, hint: HintCopy.resumeNeedsYou(dismissKey: HotKeyCombo.nudgeDismiss.display)),
                               dismissKey: HotKeyCombo.nudgeDismiss.display, onDismiss: {})
            },
            Snapshot("hints/call-pause", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
                ToastView(toast: ToastContent(text: Copy.callPauseToast(.microphone), action: .resumeFromCall,
                                              hint: HintCopy.callPause), onAction: {})
            },
            Snapshot("hints/popover", scenes: SnapshotScene.popupBackdrops, variants: SnapshotVariant.accessibility,
                     padding: 32) {
                TourPopoverChrome { PopoverView(state: popoverState(), actions: .noop) }
            },
        ]
    }

    /// The first real nudge: a stretch offer, or an eye rest counting down to start by itself.
    static func nudge(_ lesson: HintLesson) -> NudgeState {
        var nudge = lesson == .autoStart ? AppState.preview(.autoStart(remaining: 9.2)).nudge!
            : AppState.preview(.breakDue(.move)).nudge!
        nudge.hint = HintCopy.nudge(lesson)
        return nudge
    }

    static func firstBreak(lead: String, agent: Bool = true) -> ActiveBreakState {
        var active = BreakSnapshots.activeBreak(.eyes, progress: 0.25)
        if !agent { active.agentChip = .clock(AppState.previewNow) }
        active.hint = lead
        return active
    }

    static func resume(_ variant: PreviewScenario.ResumeVariant, hint: String) -> ResumeCardContent {
        var card = BreakSnapshots.resumeContent(variant)
        card.hint = hint
        return card
    }

    /// The popover the first time it opens, a day in: its hint at the bottom.
    static func popoverState() -> AppState {
        let state = AppState.preview(.idle)
        state.popoverHint = HintCopy.popover
        return state
    }
}

/// The tour's surfaces as the app draws them, for the snapshots and the film.
@MainActor
enum TourScenes {
    static let agent = "Claude"

    /// The sample nudge with its coach line underneath.
    static func nudge(hotkeys: Bool = true) -> some View {
        var nudge = sampleNudge
        nudge.hotkeysEnabled = hotkeys
        return VStack(spacing: 0) {
            NudgeCardView(nudge: nudge, actions: .noop)
            TourAttachedCaption(tour: .at(.nudge, hotkeys: hotkeys), actions: .noop)
        }
    }

    static var sampleNudge: NudgeState {
        let opportunity = Opportunity(kind: .agentStarted, source: .claudeCode, createdAt: AppState.previewNow)
        let offer = BreakOffer(kind: .eyes, length: Timing.tourBreakLength, opportunity: opportunity)
        return NudgeState(offer: offer, title: Copy.nudgeTitle(kind: .eyes, length: Timing.tourBreakLength),
                          subtitle: Copy.nudgeSubtitle(for: offer), whyNow: TourCopy.nudgeWhyNow,
                          isPreview: true, isRehearsal: true, shownAt: AppState.previewNow)
    }

    /// The sample break `elapsed` seconds in, built as the coordinator builds it.
    static func sampleBreak(elapsed: TimeInterval) -> ActiveBreakState {
        let now = AppState.previewNow
        let copy = BreakCopyLibrary.variant(for: .eyes, rotation: 0, agentName: agent)
        let session = BreakSession(kind: .eyes, startedAt: now.addingTimeInterval(-elapsed),
                                   plannedLength: Timing.tourBreakLength, copy: copy)
        let chip: AgentChipState = TourPolicy.sampleAgentWorking(breakElapsed: elapsed)
            ? .working(agent: agent, elapsed: TourPolicy.sampleRunElapsed(breakElapsed: elapsed)) : .done(agent: agent)
        return ActiveBreakState(kind: .eyes, title: copy.title, instruction: copy.instruction, startedAt: session.startedAt,
                                elapsed: elapsed, plannedLength: Timing.tourBreakLength,
                                doneAvailable: BreakSessionRules.isDoneAvailable(session, now: now), agentChip: chip,
                                isRehearsal: true)
    }

    static func breakScreen(elapsed: TimeInterval, presentation: OverlayPresentation = OverlayPresentation()) -> some View {
        BreakOverlayView(activeBreak: sampleBreak(elapsed: elapsed), actions: .noop, displaySize: OverlayFilm.size,
                         now: AppState.previewNow, presentation: presentation)
    }

    /// The sample resume card with its coach line underneath.
    static func resume() -> some View {
        let facts = TourPolicy.sampleResume(agent: agent)
        let card = ResumeCardContent(items: [ResumeItem(id: SessionKey(source: .claudeCode, sessionID: "tour"), facts: facts)])
        return VStack(spacing: 0) {
            ResumeCardView(card: card, onDismiss: {})
            TourAttachedCaption(tour: .at(.resumeCard), actions: .noop)
        }
    }

    /// What a person who just finished onboarding sees in the popover: their agent connected,
    /// nothing counted yet.
    static func popoverState(part: TourPopoverPart?) -> AppState {
        let state = AppState.preview(.firstRun)
        state.integrations = PreviewData().integrations(connected: true)
        state.settings.hasCompletedOnboarding = true
        state.settings.tourStatus = .started
        state.tour = part.map { .at(.popover, part: $0) }
        return state
    }

    static func popover(_ part: TourPopoverPart) -> some View {
        TourPopoverChrome { PopoverView(state: popoverState(part: part), actions: .noop) }
    }
}

/// The popover's window as the snapshots draw it (the arrow, the rounded clip, the rim).
struct TourPopoverChrome<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            TourPopoverArrow()
                .fill(Theme.Colors.glassApproximation)
                .frame(width: 26, height: 11)
                .offset(y: 1)
            content
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    }
}

private struct TourPopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.midX - 4, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX + 4, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
