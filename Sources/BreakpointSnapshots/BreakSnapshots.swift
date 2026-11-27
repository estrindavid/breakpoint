import SwiftUI
import BreakpointCore
import BreakpointKit

// The break screens' snapshots. SPEC §9 lists every state these must cover; this registers each
// screen in every meaningful state.
//
// Snapshots cannot show the live blur or motion. The overlay is drawn over a stand-in for the
// already-blurred desktop (a bright, busy wallpaper and a plain light desktop, the two worst cases
// for contrast), with glass rendering forced opaque. Entrance, exit and Skip-guard frames come from
// the same pure timeline functions the live overlay uses.

enum BreakSnapshots {
    static let display = CGSize(width: 1512, height: 982)

    @MainActor static var all: [Snapshot] {
        nudges + chips + popupMotion + overlays + routineSteps + pacing + completions + variety + overlayStates
            + overlayMotion + overlayDisplays + cards
    }

    // MARK: Nudge (§3.1)

    @MainActor static var nudges: [Snapshot] {
        var list: [Snapshot] = []
        for kind in BreakKind.allCases {
            list.append(Snapshot("break/nudge-\(kind.rawValue)", scenes: SnapshotScene.allBackdrops,
                                 variants: SnapshotVariant.accessibility) {
                NudgeCardView(nudge: AppState.preview(.breakDue(kind)).nudge!, actions: .noop)
            })
            list.append(Snapshot("break/nudge-\(kind.rawValue)-hover", scenes: SnapshotScene.allBackdrops) {
                NudgeCardView(nudge: AppState.preview(.breakDue(kind)).nudge!, actions: .noop, revealed: true, onClose: {})
            })
        }
        let reasons: [(String, Opportunity)] = [
            ("typing-pause", Opportunity(kind: .typingPause, createdAt: AppState.previewNow)),
            ("long-command", Opportunity(kind: .longCommand, source: .shell, sessionID: "4242", commandName: "swift test",
                                         createdAt: AppState.previewNow)),
        ]
        for (name, opportunity) in reasons {
            let nudge = nudge(.move, opportunity: opportunity)
            list.append(Snapshot("break/nudge-reason-\(name)") { NudgeCardView(nudge: nudge, actions: .noop) })
            list.append(Snapshot("break/nudge-reason-\(name)-hover") {
                NudgeCardView(nudge: nudge, actions: .noop, revealed: true, onClose: {})
            })
        }
        var noHotkeys = AppState.preview(.breakDue(.move)).nudge!
        noHotkeys.hotkeysEnabled = false
        list.append(Snapshot("break/nudge-hover-hotkeys-off") { NudgeCardView(nudge: noHotkeys, actions: .noop, revealed: true, onClose: {}) })
        for remaining in [10.0, 7.4] {
            list.append(Snapshot("break/nudge-autostart-\(Int(remaining.rounded(.up)))", scenes: SnapshotScene.allBackdrops) {
                NudgeCardView(nudge: AppState.preview(.autoStart(remaining: remaining)).nudge!, actions: .noop)
            })
        }
        return list
    }

    @MainActor static func nudge(_ kind: BreakKind, opportunity: Opportunity) -> NudgeState {
        let offer = BreakOffer(kind: kind, length: kind.defaultLength, opportunity: opportunity, overdueBy: 18 * 60,
                               timerValue: 52 * 60)
        return NudgeState(offer: offer, title: Copy.nudgeTitle(kind: kind, length: offer.length),
                          subtitle: Copy.nudgeSubtitle(for: offer), whyNow: Copy.whyNow(for: offer), shownAt: AppState.previewNow)
    }

    // MARK: Countdown chip (§3.2)

    @MainActor static var chips: [Snapshot] {
        [5.0, 2.2].map { remaining in
            Snapshot("break/countdown-chip-\(Int(remaining.rounded(.up)))", scenes: SnapshotScene.allBackdrops,
                     variants: SnapshotVariant.accessibility) {
                CountdownChipView(kind: .eyes, remaining: remaining)
            }
        }
    }

    // MARK: Pop-up motion (§4.6 "Liquid pop-ups")

    /// The nudge's glass growing (and folding away), and the card becoming the countdown chip,
    /// at fixed moments. The film (`--motion-film`) plays them; these keep them reviewable.
    @MainActor static var popupMotion: [Snapshot] {
        let nudge = AppState.preview(.breakDue(.move)).nudge!
        let canvas = CGSize(width: 500, height: 200)
        func posed(_ mode: LiquidMotion.Mode, _ progress: Double) -> some View {
            NudgeCardView(nudge: nudge, actions: .noop)
                .modifier(LiquidPopupPose(mode: mode, progress: progress))
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
                .padding(.top, 8)
        }
        var list: [Snapshot] = []
        for percent in [15, 35, 60, 100] {
            let p = Double(percent) / 100
            list.append(Snapshot("break/motion-arrive-\(percent)", size: canvas, scenes: [.init(appearance: .dark, backdrop: .dark)],
                                 variants: percent == 60 ? SnapshotVariant.accessibility : [.standard]) { posed(.grow, p) })
        }
        // The same frame in a real NSHostingView: the hosted glass and its radius reach the panel.
        list.append(Snapshot("break/motion-arrive-60-window", size: canvas, scenes: [.init(appearance: .dark, backdrop: .dark)],
                             renderer: .window) { posed(.grow, 0.6) })
        for percent in [85, 50, 20] {
            let p = Double(percent) / 100
            list.append(Snapshot("break/motion-timeout-\(percent)", size: canvas, scenes: [.init(appearance: .dark, backdrop: .dark)]) {
                posed(.retract, p)
            })
        }
        let card = AppState.preview(.autoStart(remaining: Timing.autoStartChipAt)).nudge!
        let cardView = NudgeCardView(nudge: card, actions: .noop).fixedSize()
        let cardSize = NSHostingView(rootView: cardView).fittingSize
        let chipSize = NSHostingView(rootView: CountdownChipView(kind: .eyes, remaining: 5).fixedSize()).fittingSize
        let padding = Double(Theme.Layout.cardPadding)
        for ms in [0, 80, 160, 300, 800] {
            let frame = LiquidMotion.handoff(
                at: Double(ms) / 1000,
                from: MorphShape(x: 20, y: 20, width: cardSize.width, height: cardSize.height, radius: Theme.Radius.card),
                to: MorphShape(x: 330, y: 250, width: chipSize.width, height: chipSize.height, radius: chipSize.height / 2),
                fromBadge: .circle(x: padding, y: padding, diameter: Theme.Layout.badge),
                toBadge: .circle(x: CountdownChipView.badgeInset, y: (chipSize.height - Theme.Layout.countdownChipBadge) / 2,
                                 diameter: Theme.Layout.countdownChipBadge))
            list.append(Snapshot("break/motion-nudge-to-chip-\(ms)ms", size: CGSize(width: 520, height: 320),
                                 scenes: [.init(appearance: .dark, backdrop: .dark)]) {
                NudgeChipMorphView(frame: frame, card: AnyView(cardView), kind: .eyes, remaining: 5)
                    .offset(x: frame.shape.x, y: frame.shape.y)
                    .frame(width: 520, height: 320, alignment: .topLeading)
            })
        }
        return list
    }

    // MARK: Overlay per kind (§3.3, §3.4)

    /// Each kind at the start (entrance done), the middle, late with Done, and extended.
    @MainActor static var overlays: [Snapshot] {
        var list: [Snapshot] = []
        for kind in BreakKind.allCases {
            var moments: [(String, Double, Int)] = [("start", 0.02, 0), ("middle", 0.5, 0)]
            if kind != .walk { moments.append(("done", 0.86, 0)) }
            if kind.allowsExtension { moments.append(("extended", 0.6, 1)); moments.append(("extended-max", 0.6, 2)) }
            if kind == .walk { moments.append(("past-target", 1.3, 0)) }
            for (moment, progress, extensions) in moments {
                for desktop in Desktop.allCases {
                    // Accessibility variants once per kind, on the busy desktop.
                    let variants: [SnapshotVariant] = (moment == "middle" && desktop == .wallpaper)
                        ? [.standard, .reduceTransparency, .increaseContrast, .reduceMotion] : [.standard]
                    list.append(overlay("break/overlay-\(kind.rawValue)-\(moment)-\(desktop.rawValue)", desktop: desktop,
                                        variants: variants) {
                        activeBreak(kind, progress: progress, extensions: extensions)
                    })
                }
            }
        }
        return list
    }

    /// A step of several routines from the library (SPEC §2.2), on the busy desktop.
    @MainActor static var routineSteps: [Snapshot] {
        let moments: [(Routine, TimeInterval)] = [
            (BuiltInRoutines.wristsAndForearms, 54),   // Palm-up stretch
            (BuiltInRoutines.upperBack, 70),           // Reach and row
            (BuiltInRoutines.hipsAndCalves, 10),       // Heel raises
            (BuiltInRoutines.standAndReach, 75),       // Desk lean
            (BuiltInRoutines.bandRaises, 35),          // Rest between sets
        ]
        return moments.map { routine, elapsed in
            overlay("break/overlay-move-routine-\(routine.id)", desktop: .wallpaper) {
                activeBreak(.move, elapsed: elapsed, routine: routine)
            }
        }
    }

    /// The ring pacing a repetition (SPEC §3.4 `move`), at moments of a rep, each also under
    /// Reduce Motion (whole-second steps).
    @MainActor static var pacing: [Snapshot] {
        let moments: [(String, Routine, TimeInterval)] = [
            // Arms up the wall (3 s up · 3 s down), its first rep from 30 s.
            ("up", BuiltInRoutines.neckAndShoulders, 31.5),
            ("top", BuiltInRoutines.neckAndShoulders, 32.7),
            ("down", BuiltInRoutines.neckAndShoulders, 34.5),
            // Seated leg lifts (2 s up · 2 s hold · 2 s down), from 30 s.
            ("hold", BuiltInRoutines.seatedLegs, 33),
            // Slow wrist circles (4 s each circle): an arc travels around once per circle.
            ("circle", BuiltInRoutines.wristsAndForearms, 2.5),
            // Gentle neck side-bend (5 s each side), from 90 s.
            ("side", BuiltInRoutines.neckAndShoulders, 97.5),
        ]
        return moments.map { name, routine, elapsed in
            overlay("break/overlay-move-pace-\(name)", desktop: .wallpaper,
                    variants: name == "circle" || name == "side" ? [.standard] : [.standard, .reduceMotion]) {
                activeBreak(.move, elapsed: elapsed, routine: routine)
            }
        }
    }

    /// A completed break's closing moment, frame by frame (the live overlay draws these frames).
    @MainActor static var completions: [Snapshot] {
        var list: [Snapshot] = []
        func completed(_ kind: BreakKind, _ line: String, routine: Routine? = nil) -> ActiveBreakState {
            let length = kind == .walk ? 6 * 60.0 : PreviewData().activeBreak(kind: kind, progress: 0).plannedLength
            var a = activeBreak(kind, elapsed: length, routine: routine)
            a.completion = BreakCompletionState(line: line, at: length)
            return a
        }
        for t in [0.0, 0.1, 0.2, 0.3, 0.45, 0.6, 1.2] {
            list.append(overlay("break/overlay-complete-move-\(String(format: "%.2f", t))", desktop: .wallpaper,
                                liveElapsed: 120 + t) {
                completed(.move, "Shoulders done.", routine: BuiltInRoutines.neckAndShoulders)
            })
        }
        list.append(overlay("break/overlay-complete-move-reduce-motion-0.20", desktop: .wallpaper, variants: [.reduceMotion],
                            liveElapsed: 120.2) {
            completed(.move, "Shoulders done.", routine: BuiltInRoutines.neckAndShoulders)
        })
        // Then the layered exit takes the closed ring and the line with the content (SPEC §3.3).
        for t in [0.1, 0.35, 0.65] {
            list.append(overlay("break/overlay-complete-move-exit-\(String(format: "%.2f", t))", desktop: .wallpaper,
                                frame: OverlayFrame.exit(at: t, reduceMotion: false),
                                liveElapsed: 120 + Timing.completionMoment + t) {
                completed(.move, "Shoulders done.", routine: BuiltInRoutines.neckAndShoulders)
            })
        }
        let others: [(BreakKind, String, Double)] = [(.eyes, "That's twenty seconds.", 20), (.walk, "That's six minutes.", 360),
                                                     (.breathe, "Breathing done.", 60)]
        for (kind, line, length) in others {
            list.append(overlay("break/overlay-complete-\(kind.rawValue)", desktop: .wallpaper, liveElapsed: length + 1.2) {
                completed(kind, line)
            })
        }
        return list
    }

    /// Rotating copy that gives the emptiest breaks something to do: eye-rest tasks and walk ideas.
    @MainActor static var variety: [Snapshot] {
        var list: [Snapshot] = []
        for (n, rotation) in [1, 2, 3].enumerated() {
            list.append(overlay("break/overlay-eyes-task-\(n + 1)", desktop: .wallpaper) {
                activeBreak(.eyes, elapsed: 6, copyRotation: rotation)
            })
            list.append(overlay("break/overlay-walk-idea-\(n + 1)", desktop: .wallpaper) {
                var a = activeBreak(.walk, elapsed: 150, copyRotation: n)
                a.detail = BreakCopyLibrary.walkIdeas[rotation]
                return a
            })
        }
        return list
    }

    /// Agent chip states, needs-you, walk ambient and welcome back, focus, Skip guard.
    @MainActor static var overlayStates: [Snapshot] {
        var list: [Snapshot] = []
        let chipStates: [(String, AgentChipState)] = [
            ("working", .working(agent: "Claude", elapsed: 102)),
            ("several-working", .severalWorking(2)),
            ("done", .done(agent: "Claude")),
            ("clock", .clock(AppState.previewNow)),
        ]
        for (name, chip) in chipStates {
            list.append(overlay("break/overlay-chip-\(name)", desktop: .wallpaper) {
                var a = activeBreak(.eyes, progress: 0.4)
                a.agentChip = chip
                return a
            })
        }
        for kind in [BreakKind.move, .walk, .eyes] {
            list.append(overlay("break/overlay-needs-you-\(kind.rawValue)", desktop: .wallpaper,
                                variants: kind == .walk ? SnapshotVariant.accessibility : [.standard],
                                focused: .primary) {
                var a = activeBreak(kind, progress: 0.45)
                a.needsYou = true
                a.agentChip = .needsYou(agent: "Claude")
                // As the coordinator does: the walk's "we'll chime" line has done its job.
                if kind == .walk { a.instruction = Copy.walkNeedsYouInstruction(agent: "Claude") }
                return a
            })
        }
        // The rare line in debugger voice, in place (one walk in five).
        list.append(overlay("break/overlay-walk-step-out-plain", desktop: .plain) {
            var a = activeBreak(.walk, progress: 0.5)
            let rotation = BreakCopyLibrary.walk.variants.firstIndex { Copy.debuggerVoice.contains($0.title) } ?? 0
            let copy = BreakCopyLibrary.variant(for: .walk, rotation: rotation, agentName: "Claude")
            a.title = copy.title
            a.instruction = copy.instruction
            return a
        })
        list.append(overlay("break/overlay-walk-ambient", desktop: .wallpaper, variants: SnapshotVariant.accessibility) {
            var a = activeBreak(.walk, progress: 0.55)
            a.ambient = true
            return a
        })
        list.append(overlay("break/overlay-walk-welcome-back", desktop: .wallpaper, focused: .primary) {
            var a = activeBreak(.walk, progress: 0.75)
            a.welcomeBack = true
            return a
        })
        list.append(overlay("break/overlay-focus-skip", desktop: .wallpaper, focused: .skip) {
            activeBreak(.breathe, progress: 0.3)
        })
        list.append(overlay("break/overlay-focus-extend", desktop: .wallpaper, focused: .extend) {
            activeBreak(.move, progress: 0.3)
        })
        list.append(overlay("break/overlay-preview", desktop: .wallpaper) {
            var a = activeBreak(.eyes, progress: 0.2)
            a.isPreview = true
            return a
        })
        // The Skip guard filling over its 3 s.
        for elapsed in [0.0, 1.0, 2.0, 2.7] {
            list.append(overlay("break/overlay-skip-guard-\(String(format: "%.1f", elapsed))", desktop: .wallpaper) {
                activeBreak(.eyes, elapsed: elapsed)
            })
        }
        // The single-Esc pulse at its dimmest.
        list.append(overlay("break/overlay-esc-pulse", desktop: .wallpaper, hintPulse: 0.5) {
            activeBreak(.eyes, progress: 0.4)
        })
        return list
    }

    /// The staged entrance and the exit, frame by frame (the live overlay draws these same frames).
    @MainActor static var overlayMotion: [Snapshot] {
        var list: [Snapshot] = []
        for t in [0.15, 0.45, 0.7, 0.85, 1.05, 1.2, 1.35, 1.6] {
            list.append(overlay("break/overlay-entrance-\(String(format: "%.2f", t))", desktop: .wallpaper,
                                frame: OverlayFrame.entrance(at: t, reduceMotion: false)) {
                activeBreak(.move, elapsed: 3.5)
            })
        }
        list.append(overlay("break/overlay-entrance-reduce-motion-0.12", desktop: .wallpaper, variants: [.reduceMotion],
                            frame: OverlayFrame.entrance(at: 0.12, reduceMotion: true)) {
            activeBreak(.move, elapsed: 3.5)
        })
        for t in [0.1, 0.35, 0.5, 0.65] {
            list.append(overlay("break/overlay-exit-\(String(format: "%.2f", t))", desktop: .wallpaper,
                                frame: OverlayFrame.exit(at: t, reduceMotion: false)) {
                activeBreak(.eyes, progress: 1)
            })
        }
        // The aurora's drift across its 60 s loop (the backdrop's clock set by hand).
        for t in [0.0, 20.0, 40.0] {
            list.append(overlay("break/overlay-aurora-\(Int(t))s", desktop: .wallpaper, backdropTime: t) {
                activeBreak(.eyes, progress: 0.4)
            })
        }
        // `breathe` across one cycle (the ring is the content).
        for t in [0.0, 2.75, 5.5, 8.25] {
            list.append(overlay("break/overlay-breathe-cycle-\(String(format: "%.2f", t))", desktop: .plain,
                                variants: t == 2.75 ? [.standard, .reduceMotion] : [.standard]) {
                activeBreak(.breathe, elapsed: 11 + t)
            })
        }
        return list
    }

    /// Other displays, a small and a large display.
    @MainActor static var overlayDisplays: [Snapshot] {
        [
            overlay("break/overlay-other-display", desktop: .wallpaper, showsContent: false) { activeBreak(.move, progress: 0.4) },
            overlay("break/overlay-small-display-breathe", desktop: .wallpaper, size: CGSize(width: 1280, height: 720)) {
                activeBreak(.breathe, progress: 0.4)
            },
            overlay("break/overlay-small-display-move", desktop: .wallpaper, size: CGSize(width: 1280, height: 720)) {
                activeBreak(.move, progress: 0.4)
            },
            overlay("break/overlay-large-display-walk", desktop: .plain, size: CGSize(width: 2560, height: 1440)) {
                activeBreak(.walk, progress: 0.4)
            },
            overlay("break/overlay-notch-eyes", desktop: .wallpaper, safeAreaTop: 32) { activeBreak(.eyes, progress: 0.3) },
        ]
    }

    // MARK: Cards (§3.5, §3.6)

    @MainActor static var cards: [Snapshot] {
        var list: [Snapshot] = []
        let resumes: [(String, ResumeCardContent)] = resumeCards
        for (name, content) in resumes {
            let big = name == "one" || name == "needs-you"
            list.append(Snapshot("break/resume-\(name)", scenes: big ? SnapshotScene.allBackdrops : SnapshotScene.popupBackdrops,
                                 variants: big ? SnapshotVariant.accessibility : [.standard]) {
                ResumeCardView(card: content, onDismiss: {})
            })
        }
        list.append(Snapshot("break/resume-one-hover") {
            ResumeCardView(card: resumeContent(.one), hovering: true, dismissKey: HotKeyCombo.nudgeDismiss.display, onDismiss: {})
        })

        let note: AwayNoteContent = {
            if case .awayNote(let note) = AppState.preview(.awayCredited).cards[0].content { return note }
            fatalError("preview has no away note")
        }()
        list.append(Snapshot("break/away-note", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
            AwayNoteView(note: note, onUndo: {})
        })
        list.append(Snapshot("break/away-note-hover") { AwayNoteView(note: note, hovering: true, onUndo: {}, onClose: {}) })
        list.append(Snapshot("break/toast", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
            ToastView(toast: ToastContent(text: Copy.timersRestored), onAction: {})
        })
        list.append(Snapshot("break/toast-call-pause", scenes: SnapshotScene.allBackdrops) {
            ToastView(toast: ToastContent(text: Copy.callPauseToast([.microphone, .camera]), action: .resumeFromCall), onAction: {})
        })

        list.append(Snapshot("break/wind-down", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
            windDown(wrapUp: false)
        })
        for (name, progress) in [("holding-40", 0.4), ("holding-90", 0.9)] {
            list.append(Snapshot("break/wind-down-\(name)") { windDown(wrapUp: false, holdProgress: progress) })
        }
        list.append(Snapshot("break/wind-down-hold-10s") { windDown(wrapUp: false, hold: 10) })
        list.append(Snapshot("break/wind-down-key") {
            let keyboard = WindDownKeyboard()
            keyboard.isKey = true
            return windDown(wrapUp: false, keyboard: keyboard)
        })
        list.append(Snapshot("break/wind-down-note", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
            windDown(wrapUp: true)
        })
        list.append(Snapshot("break/wind-down-note-key") {
            let keyboard = WindDownKeyboard()
            keyboard.isKey = true
            return windDown(wrapUp: true, keyboard: keyboard)
        })
        // The update prompt (§2.11): one line of what's new, Later · Update; progress; a failure.
        let update = UpdateCardContent(release: UpdateRelease(
            version: "0.2.0", notes: "Breaks now wait for Codex and Gemini too, and the routine has two new stretches.",
            page: URL(string: "https://github.com/estrindavid/breakpoint/releases/tag/v0.2.0")!))
        func updateCard(_ card: UpdateCardContent, hovering: Bool = false, rim: TimeRimSource? = nil) -> UpdateCardView {
            UpdateCardView(card: card, hovering: hovering, timeRim: rim, onUpdate: {}, onOpenPage: {}, onLater: {})
        }
        list.append(Snapshot("break/update", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
            updateCard(update)
        })
        list.append(Snapshot("break/update-rim") { updateCard(update, rim: .still(TimeRimFrame(fraction: 0.62))) })
        list.append(Snapshot("break/update-hover") {
            updateCard(update, hovering: true, rim: .still(TimeRimFrame(fraction: 0.4, held: true)))
        })
        list.append(Snapshot("break/update-no-notes") {
            updateCard(UpdateCardContent(release: UpdateRelease(version: "1.0.0", notes: "", page: update.release.page)))
        })
        list.append(Snapshot("break/update-download-page") {
            var card = update
            card.canInstall = false
            return updateCard(card)
        })
        for step in [UpdateInstallStep.downloading, .verifying, .reopening] {
            list.append(Snapshot("break/update-\(step.rawValue)", scenes: SnapshotScene.allBackdrops) {
                var card = update
                card.stage = .installing(step)
                return updateCard(card)
            })
        }
        list.append(Snapshot("break/update-failed", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
            var card = update
            card.stage = .failed(UpdateInstallError.badSignature.explanation)
            return updateCard(card)
        })
        // The time rim (§3.5): the lit edge is the card's timer.
        let running = TimeRimSource.still(TimeRimFrame(fraction: 0.62))
        list.append(Snapshot("break/resume-one-rim", scenes: SnapshotScene.allBackdrops,
                             variants: SnapshotVariant.accessibility + [.reduceMotion]) {
            ResumeCardView(card: resumeContent(.one), timeRim: running, onDismiss: {})
        })
        list.append(Snapshot("break/resume-one-rim-held") {
            ResumeCardView(card: resumeContent(.one), hovering: true, dismissKey: HotKeyCombo.nudgeDismiss.display,
                           timeRim: .still(TimeRimFrame(fraction: 0.3, held: true)), onDismiss: {})
        })
        list.append(Snapshot("break/away-note-rim", scenes: SnapshotScene.allBackdrops,
                             variants: SnapshotVariant.accessibility + [.reduceMotion]) {
            AwayNoteView(note: note, timeRim: running, onUndo: {})
        })
        list.append(Snapshot("break/away-note-rim-held") {
            AwayNoteView(note: note, hovering: true, timeRim: .still(TimeRimFrame(fraction: 0.3, held: true)), onUndo: {}, onClose: {})
        })
        list.append(Snapshot("break/toast-rim", scenes: SnapshotScene.allBackdrops) {
            ToastView(toast: ToastContent(text: Copy.timersRestored), timeRim: .still(TimeRimFrame(fraction: 0.4)), onAction: {})
        })
        // The rim drawing back over a card's life, and held under the pointer.
        list.append(Snapshot("break/time-rim-sequence", scenes: [SnapshotScene(appearance: .dark, backdrop: .dark)],
                             variants: [.standard, .reduceMotion]) {
            VStack(spacing: Theme.Layout.popupStackGap) {
                ForEach([1.0, 0.75, 0.5, 0.25, 0.08], id: \.self) { f in
                    AwayNoteView(note: note, timeRim: .still(TimeRimFrame(fraction: f)), onUndo: {})
                }
                AwayNoteView(note: note, hovering: true, timeRim: .still(TimeRimFrame(fraction: 0.3, held: true)), onUndo: {}, onClose: {})
            }
        })
        // The three pop-ups as the stack places them (top to bottom by priority, 8 pt gaps).
        list.append(Snapshot("break/stack-two", scenes: [SnapshotScene(appearance: .dark, backdrop: .wallpaper)]) {
            VStack(spacing: Theme.Layout.popupStackGap) {
                ResumeCardView(card: resumeContent(.needsYou), onDismiss: {})
                AwayNoteView(note: note, onUndo: {})
            }
        })
        return list
    }

    /// Resume cards (§3.5): every outcome, with snippets on and off, one row and several, long text.
    @MainActor static var resumeCards: [(String, ResumeCardContent)] {
        let p = PreviewData()
        func card(_ rows: ResumeItem...) -> ResumeCardContent { ResumeCardContent(items: rows) }
        func row(_ session: AgentSession, keepSnippets: Bool = true) -> ResumeItem {
            ResumeItem(id: session.key, facts: ResumeFacts.session(session, keepSnippets: keepSnippets)!)
        }
        func command(_ name: String, folder: String, exit: Int, minutes: Double) -> ResumeItem {
            let running = RunningCommand(shellPID: "\(name.count)", command: name, cwd: "/Users/dev/code/\(folder)",
                                         startedAt: p.now.addingTimeInterval(-minutes * 60))
            return ResumeItem(id: SessionKey(source: .shell, sessionID: running.shellPID),
                              facts: ResumeFacts.command(running, result: CommandResult(exitCode: exit, duration: minutes * 60)))
        }
        var usageLimit = p.claudeIdle
        usageLimit.lastRunEnding = .failed
        usageLimit.report = RunReport(edits: 2, commands: 1, failure: "rate_limit")
        var error = p.cursorIdle
        error.report = RunReport()
        var long = p.claudeIdle
        long.cwd = "/Users/dev/code/a-really-long-monorepo-folder-name-for-the-frontend-and-backend-services"
        long.lastRunEnding = .finished(duration: 14 * 60)
        long.report.message = "Refactored the authentication middleware so that every route checks the session token before the handler runs, and moved the token parsing into its own module with tests"
        var longAsk = p.claudeNeedsYou
        longAsk.cwd = long.cwd
        longAsk.report.request = AgentRequest(tool: .command, subject: "docker compose -f docker-compose.integration.yml run --rm api-tests pytest -x")
        var asksEdit = p.claudeNeedsYou
        asksEdit.report.request = AgentRequest(tool: .edit, subject: "OAuthCallbackController.swift")
        let agents = ["Claude", "Codex", "Cursor", "Gemini", "Copilot"]
        let folders = ["breakpoint", "payments-service", "site", "infra", "docs"]
        let five = (0..<5).map { i in
            ResumeItem(id: SessionKey(source: .claudeCode, sessionID: "\(i)"),
                       facts: ResumeFacts(name: agents[i], folder: folders[i],
                                          outcome: i == 2 ? .failed(reason: nil) : .finished(duration: Double(i + 2) * 60)))
        }
        return [
            ("one", card(row(p.claudeIdle))),
            ("no-snippet", card(row(p.claudeIdle, keepSnippets: false))),
            ("usage-limit", card(row(usageLimit))),
            ("error", card(row(error))),
            ("command-failed", card(command("swift", folder: "breakpoint", exit: 1, minutes: 4))),
            ("command-finished", card(command("cargo", folder: "engine", exit: 0, minutes: 6.2))),
            ("needs-you", card(row(p.claudeNeedsYou))),
            ("needs-you-no-snippet", card(row(p.claudeNeedsYou, keepSnippets: false))),
            ("needs-you-edit", card(row(asksEdit))),
            ("several", card(row(p.claudeIdle), row(p.codexIdle), row(p.cursorIdle))),
            ("several-mixed", card(row(p.claudeNeedsYou), command("swift", folder: "breakpoint", exit: 1, minutes: 4),
                                   row(p.cursorIdle), row(p.codexIdle))),
            ("long-text", card(row(long))),
            ("long-needs-you", card(row(longAsk))),
            ("five-agents", ResumeCardContent(items: five)),
        ]
    }

    @MainActor static func resumeContent(_ variant: PreviewScenario.ResumeVariant) -> ResumeCardContent {
        if case .resume(let card) = AppState.preview(.resume(variant)).cards[0].content { return card }
        fatalError("preview has no resume card")
    }

    @MainActor static func windDown(wrapUp: Bool, holdProgress: Double? = nil, hold: TimeInterval = 3,
                                    keyboard: WindDownKeyboard = WindDownKeyboard()) -> some View {
        var content: WindDownCardContent?
        if case .windDown(let card) = AppState.preview(.windDown(wrapUp: wrapUp)).cards[0].content {
            content = card
            content?.holdDuration = hold
        }
        return Group {
            if let content {
                WindDownCardView(card: content, actions: .noop, onDone: {}, holdProgress: holdProgress, keyboard: keyboard)
            }
        }
    }

    // MARK: Helpers

    @MainActor static func activeBreak(_ kind: BreakKind, progress: Double, extensions: Int = 0) -> ActiveBreakState {
        let base = PreviewData().activeBreak(kind: kind, progress: 0)
        return activeBreak(kind, elapsed: (base.plannedLength + Double(extensions) * Timing.extensionLength) * progress,
                           extensions: extensions)
    }

    /// A break `elapsed` seconds in, built with the same rules the coordinator uses.
    @MainActor static func activeBreak(_ kind: BreakKind, elapsed: TimeInterval, extensions: Int = 0,
                                       routine: Routine? = nil, copyRotation: Int = 0) -> ActiveBreakState {
        let now = AppState.previewNow
        var session = BreakSessionRules.makeSession(kind: kind, opportunity: nil, settings: .defaults, expectedRun: 6 * 60 + 10,
                                                    agentName: "Claude", copyRotation: copyRotation,
                                                    now: now.addingTimeInterval(-elapsed),
                                                    routine: routine)
        for _ in 0..<extensions { session = BreakSessionRules.extended(session) }
        var title = session.copy.title
        var instruction = session.copy.instruction
        var step: RoutineStepState?
        if let routine = session.routine {
            let index = routine.stepIndex(at: elapsed)
            let current = routine.steps[index]
            title = current.title
            instruction = current.instruction
            step = RoutineStepState(index: index, count: routine.steps.count, step: current,
                                    remaining: max(0, current.duration - (elapsed - routine.stepOffsets[index])))
        }
        return ActiveBreakState(
            kind: kind, title: title, instruction: instruction, step: step,
            detail: kind == .walk ? BreakCopyLibrary.walkIdeas[0] : nil, startedAt: session.startedAt, elapsed: elapsed,
            plannedLength: session.totalLength, extensionsUsed: extensions, canExtend: BreakSessionRules.canExtend(session),
            doneAvailable: BreakSessionRules.isDoneAvailable(session, now: now),
            agentChip: .working(agent: "Claude", elapsed: 102 + elapsed))
    }

    /// The desktop behind the overlay, already blurred (the live overlay blurs the real one).
    enum Desktop: String, CaseIterable {
        /// A bright, colourful photo-like wallpaper with app windows: busy worst case.
        case wallpaper
        /// A plain light desktop: bright worst case.
        case plain
    }

    @MainActor static func overlay(_ name: String, desktop: Desktop, size: CGSize = display,
                                   variants: [SnapshotVariant] = [.standard], showsContent: Bool = true,
                                   focused: OverlayControl? = nil, hintPulse: Double = 1, safeAreaTop: CGFloat = 0,
                                   frame: OverlayFrame = .settled, liveElapsed: TimeInterval? = nil,
                                   backdropTime: TimeInterval? = nil,
                                   _ make: @escaping @MainActor () -> ActiveBreakState) -> Snapshot {
        Snapshot(name, size: size, scenes: SnapshotScene.darkOnly, variants: variants) {
            let active = make()
            ZStack {
                // The live blur's opacity is what moves in the entrance and exit: the sharp
                // desktop shows through until it is fully in.
                if frame.backdrop < 1 { BlurredDesktop(desktop: desktop, sharp: true) }
                BlurredDesktop(desktop: desktop)
                    .opacity(frame.backdrop)
                BreakOverlayView(activeBreak: active, actions: .noop, displaySize: size, showsContent: showsContent,
                                 now: AppState.previewNow,
                                 presentation: OverlayPresentation(frame: frame, focused: focused, hintPulse: hintPulse,
                                                                   safeAreaTop: safeAreaTop, liveElapsed: liveElapsed,
                                                                   backdropTime: backdropTime))
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }
}

/// A stand-in for the user's desktop as the overlay's behind-window blur shows it (or, with
/// `sharp`, as it is before the blur arrives).
private struct BlurredDesktop: View {
    let desktop: BreakSnapshots.Desktop
    var sharp = false

    var body: some View {
        switch desktop {
        case .plain:
            LinearGradient(colors: [Color(hex: 0xF1F3F6), Color(hex: 0xDCE1E8)], startPoint: .top, endPoint: .bottom)
        case .wallpaper:
            GeometryReader { proxy in
                let w = proxy.size.width, h = proxy.size.height
                ZStack {
                    LinearGradient(colors: [Color(hex: 0xF6C85F), Color(hex: 0xF08A5D), Color(hex: 0xB83B5E), Color(hex: 0x2E86AB)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    // Sky, hills and a lake, very roughly.
                    Ellipse().fill(Color(hex: 0xFFF3C4)).frame(width: w * 0.25, height: w * 0.25).position(x: w * 0.72, y: h * 0.22)
                    Ellipse().fill(Color(hex: 0x3F7D5A)).frame(width: w * 1.1, height: h * 0.6).position(x: w * 0.3, y: h * 0.95)
                    Ellipse().fill(Color(hex: 0x1D4E89)).frame(width: w * 0.9, height: h * 0.35).position(x: w * 0.8, y: h * 1.0)
                    // App windows: a white editor and a dark terminal.
                    RoundedRectangle(cornerRadius: 12).fill(Color.white).frame(width: w * 0.42, height: h * 0.6)
                        .position(x: w * 0.3, y: h * 0.45)
                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x1E1E1E)).frame(width: w * 0.38, height: h * 0.45)
                        .position(x: w * 0.7, y: h * 0.6)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<14, id: \.self) { i in
                            Capsule().fill(Color(hex: [0x2F6FEB, 0x1A1A1A, 0xC2185B, 0x1A1A1A][i % 4]))
                                .frame(width: w * CGFloat([0.3, 0.22, 0.34, 0.18, 0.27][i % 5]), height: 8)
                        }
                    }
                    .position(x: w * 0.3, y: h * 0.45)
                    // Menu bar.
                    Rectangle().fill(Color.white.opacity(0.7)).frame(height: 30).position(x: w / 2, y: 15)
                }
                .blur(radius: sharp ? 0 : 30)
                .clipped()
            }
        }
    }
}
