import BreakpointCore
import BreakpointRuntime
import Foundation

extension SnapshotCatalogue {
    /// The pop-ups (nudge, countdown chip, cards) in every state, into `directory`/popups.
    static func popupSnapshots(_ directory: URL) throws -> Int {
        let folder = directory.appendingPathComponent("popups")
        var count = 0
        count += try PopupSnapshotPages.nudges(folder)
        count += try PopupSnapshotPages.chips(folder)
        count += try PopupSnapshotPages.cards(folder)
        count += try PopupSnapshotPages.stacks(folder)
        return count
    }
}

@MainActor
enum PopupSnapshotPages {
    // MARK: Nudge (§3.1)

    static func nudges(_ folder: URL) throws -> Int {
        var count = 0
        func write(_ name: String, _ nudge: NudgeState, revealed: Bool = false, focused: String? = nil) throws {
            var look = PopupNudgeView.Look()
            look.revealed = revealed
            look.whyNow = revealed ? 1 : 0
            look.ring = nudge.phase == .autoStartCard ? nudge.autoStartProgress : nil
            var handlers = PopupNudgeView.Handlers()
            handlers.close = {}
            let height = PopupNudgeView.height(nudge, look: look, handlers: handlers)
            try Snapshot.write(folder.appendingPathComponent("\(name).png"), size: SizeF(width: PopupNudgeView.width, height: height),
                               focused: focused) { canvas, controls in
                if focused != nil { controls.debugShowFocus() }
                PopupNudgeView.draw(canvas, controls, nudge, look: look, handlers: handlers)
            }
            count += 1
        }
        for kind in BreakKind.allCases {
            let nudge = AppState.preview(.breakDue(kind)).nudge!
            try write("nudge-\(kind.rawValue)", nudge)
            try write("nudge-\(kind.rawValue)-hover", nudge, revealed: true)
        }
        let longCommand = nudge(.move, opportunity: Opportunity(kind: .longCommand, source: .shell, sessionID: "4242",
                                                                 commandName: "swift test", createdAt: AppState.previewNow))
        try write("nudge-reason-long-command", longCommand)
        try write("nudge-reason-long-command-hover", longCommand, revealed: true)
        let typing = nudge(.move, opportunity: Opportunity(kind: .typingPause, createdAt: AppState.previewNow))
        try write("nudge-reason-typing-pause-hover", typing, revealed: true)
        var noHotkeys = AppState.preview(.breakDue(.move)).nudge!
        noHotkeys.hotkeysEnabled = false
        try write("nudge-hover-hotkeys-off", noHotkeys, revealed: true)
        var hinted = AppState.preview(.breakDue(.move)).nudge!
        hinted.hint = HintCopy.nudge(.nudge)
        try write("nudge-hint", hinted)
        for remaining in [10.0, 7.4] {
            try write("nudge-autostart-\(Int(remaining.rounded(.up)))", AppState.preview(.autoStart(remaining: remaining)).nudge!)
        }
        var autoHint = AppState.preview(.autoStart(remaining: 8)).nudge!
        autoHint.hint = HintCopy.nudge(.autoStart)
        try write("nudge-autostart-hint", autoHint)
        try write("nudge-focus", AppState.preview(.breakDue(.move)).nudge!, focused: "start")
        return count
    }

    static func nudge(_ kind: BreakKind, opportunity: Opportunity) -> NudgeState {
        let offer = BreakOffer(kind: kind, length: kind.defaultLength, opportunity: opportunity, overdueBy: 18 * 60, timerValue: 52 * 60)
        return NudgeState(offer: offer, title: Copy.nudgeTitle(kind: kind, length: offer.length),
                          subtitle: Copy.nudgeSubtitle(for: offer), whyNow: Copy.whyNow(for: offer), shownAt: AppState.previewNow)
    }

    // MARK: Countdown chip (§3.2)

    static func chips(_ folder: URL) throws -> Int {
        for remaining in [5.0, 2.2] {
            let size = PopupChipView.size(kind: .eyes, remaining: remaining)
            let margin: Float = 16
            try Snapshot.write(folder.appendingPathComponent("countdown-chip-\(Int(remaining.rounded(.up))).png"),
                               size: SizeF(width: size.width + 2 * margin, height: size.height + 2 * margin),
                               background: { wallpaper($0) }) { canvas, _ in
                PopupChipView.draw(canvas, RectF(x: margin, y: margin, width: size.width, height: size.height), kind: .eyes,
                                   remaining: remaining)
            }
        }
        return 2
    }

    // MARK: Cards (§3.5, §3.6, §2.11)

    static func cards(_ folder: URL) throws -> Int {
        var count = 0
        func write(_ name: String, _ card: CardState, _ look: PopupCardLook = PopupCardLook()) throws {
            let size = PopupCardView.size(card, look: look)
            try Snapshot.write(folder.appendingPathComponent("\(name).png"), size: size) { canvas, controls in
                PopupCardView.draw(canvas, controls, card, look: look, handlers: PopupCardHandlers())
            }
            count += 1
        }
        func content(_ scenario: PreviewScenario) -> CardState { AppState.preview(scenario).cards[0] }
        var hover = PopupCardLook()
        hover.hovering = true
        var running = PopupCardLook()
        running.rim = PopupRimFrame(fraction: 0.62)
        var held = PopupCardLook()
        held.hovering = true
        held.rim = PopupRimFrame(fraction: 0.3, held: true)

        // Resume cards.
        let one = content(.resume(.one))
        try write("resume-one", one)
        var keyed = hover
        keyed.dismissKey = HotKeys.display(.nudgeDismiss)
        try write("resume-one-hover", one, keyed)
        try write("resume-one-rim", one, running)
        var heldKeyed = held
        heldKeyed.dismissKey = HotKeys.display(.nudgeDismiss)
        try write("resume-one-rim-held", one, heldKeyed)
        try write("resume-several", content(.resume(.several)))
        try write("resume-needs-you", content(.resume(.needsYou)))
        try write("resume-needs-you-hover", content(.resume(.needsYou)), keyed)
        if case .resume(var resume) = one.content {
            resume.hint = HintCopy.resumeCard
            try write("resume-hint", CardState(content: .resume(resume), createdAt: AppState.previewNow))
        }
        if case .resume(var resume) = content(.resume(.needsYou)).content {
            resume.hint = HintCopy.resumeNeedsYou(dismissKey: HotKeys.display(.nudgeDismiss))
            try write("resume-needs-you-hint", CardState(content: .resume(resume), createdAt: AppState.previewNow))
        }
        try write("resume-long-text", resumeCard(longResumeItems()))
        try write("resume-five-agents", resumeCard(fiveItems()))

        // Away note and toasts.
        let away = content(.awayCredited)
        try write("away-note", away)
        try write("away-note-hover", away, hover)
        try write("away-note-rim", away, running)
        try write("away-note-rim-held", away, held)
        let toast = content(.toast)
        try write("toast", toast)
        var toastRim = PopupCardLook()
        toastRim.rim = PopupRimFrame(fraction: 0.4)
        try write("toast-rim", toast, toastRim)
        let callText = Copy.callPauseToast([.microphone, .camera])
        try write("toast-call-pause", CardState(content: .toast(ToastContent(text: callText, action: .resumeFromCall)),
                                                createdAt: AppState.previewNow))
        let callHint = CardState(content: .toast(ToastContent(text: Copy.callPauseToast([.microphone]), action: .resumeFromCall,
                                                              hint: HintCopy.callPause)), createdAt: AppState.previewNow)
        try write("toast-call-pause-hint", callHint)
        try write("toast-call-pause-hint-hover", callHint, hover)

        // Wind-down.
        let asking = content(.windDown(wrapUp: false))
        try write("wind-down", asking)
        for (name, progress) in [("holding-40", 0.4), ("holding-90", 0.9)] {
            var look = PopupCardLook()
            look.holdProgress = progress
            look.holding = true
            try write("wind-down-\(name)", asking, look)
        }
        if case .windDown(var longer) = asking.content {
            longer.holdDuration = 10
            try write("wind-down-hold-10s", CardState(content: .windDown(longer), createdAt: AppState.previewNow))
        }
        let note = content(.windDown(wrapUp: true))
        try write("wind-down-note", note)
        var key = PopupCardLook()
        key.isKey = true
        try write("wind-down-note-key", note, key)
        var copied = key
        copied.copied = true
        try write("wind-down-note-copied", note, copied)
        if case .windDown(var empty) = note.content {
            empty.phase = .note(lines: [])
            try write("wind-down-note-empty", CardState(content: .windDown(empty), createdAt: AppState.previewNow))
        }

        // The update prompt.
        let update = UpdateCardContent(release: UpdateRelease(
            version: "0.2.0", notes: "Breaks now wait for Codex and Gemini too, and the routine has two new stretches.",
            page: URL(string: "https://github.com/estrindavid/breakpoint/releases/tag/v0.2.0")!))
        func updateCard(_ content: UpdateCardContent) -> CardState { CardState(content: .update(content), createdAt: AppState.previewNow) }
        try write("update", updateCard(update))
        try write("update-rim", updateCard(update), running)
        var updateHover = PopupCardLook()
        updateHover.hovering = true
        updateHover.rim = PopupRimFrame(fraction: 0.4, held: true)
        try write("update-hover", updateCard(update), updateHover)
        try write("update-no-notes", updateCard(UpdateCardContent(release: UpdateRelease(version: "1.0.0", notes: "",
                                                                                          page: update.release.page))))
        var page = update
        page.canInstall = false
        try write("update-download-page", updateCard(page))
        for step in [UpdateInstallStep.downloading, .verifying, .reopening] {
            var installing = update
            installing.stage = .installing(step)
            try write("update-\(step.rawValue)", updateCard(installing))
        }
        var failed = update
        failed.stage = .failed(UpdateInstallError.badSignature.explanation)
        try write("update-failed", updateCard(failed))
        return count
    }

    static func resumeCard(_ items: [ResumeItem]) -> CardState {
        CardState(content: .resume(ResumeCardContent(items: items)), createdAt: AppState.previewNow)
    }

    static func longResumeItems() -> [ResumeItem] {
        let facts = ResumeFacts(name: "Claude", folder: "a-really-long-monorepo-folder-name-for-the-frontend-and-backend-services",
                                outcome: .finished(duration: 14 * 60),
                                message: "Refactored the authentication middleware so that every route checks the session token before the handler runs, and moved the token parsing into its own module with tests")
        return [ResumeItem(id: SessionKey(source: .claudeCode, sessionID: "long"), facts: facts)]
    }

    static func fiveItems() -> [ResumeItem] {
        let agents = ["Claude", "Codex", "Cursor", "Gemini", "Copilot"]
        let folders = ["breakpoint", "payments-service", "site", "infra", "docs"]
        return (0..<5).map { i in
            ResumeItem(id: SessionKey(source: .claudeCode, sessionID: "\(i)"),
                       facts: ResumeFacts(name: agents[i], folder: folders[i],
                                          outcome: i == 2 ? .failed(reason: nil) : .finished(duration: Double(i + 2) * 60)))
        }
    }

    // MARK: Stacks (§3.0)

    /// Two pop-ups as `PopupStack` places them: top centre, 8 below the work area's top, 8 apart,
    /// highest priority first, over a wallpaper.
    static func stacks(_ folder: URL) throws -> Int {
        let needsYou = AppState.preview(.resume(.needsYou)).cards[0]
        let away = AppState.preview(.awayCredited).cards[0]
        let nudge = AppState.preview(.breakDue(.move)).nudge!
        try stack(folder.appendingPathComponent("stack-two.png"), [needsYou, away], nudge: nil)
        try stack(folder.appendingPathComponent("stack-card-and-nudge.png"), [AppState.preview(.toast).cards[0]], nudge: nudge)
        return 2
    }

    private static func stack(_ url: URL, _ cards: [CardState], nudge: NudgeState?) throws {
        let look = PopupCardLook()
        var entries: [(SizeF, PopupPriority, (Canvas) -> Void)] = cards.map { card in
            (PopupCardView.size(card, look: look), card.priority, { canvas in
                PopupCardView.draw(canvas, nil, card, look: look, handlers: PopupCardHandlers())
            })
        }
        if let nudge {
            let nudgeLook = PopupNudgeView.Look()
            entries.append((SizeF(width: PopupNudgeView.width, height: PopupNudgeView.height(nudge, look: nudgeLook)), .nudge, { canvas in
                PopupNudgeView.draw(canvas, nil, nudge, look: nudgeLook, handlers: PopupNudgeView.Handlers())
            }))
        }
        entries.sort { $0.1 > $1.1 }
        let width: Float = 560
        let gap = Theme.Size.popupStackGap
        let height = Theme.Size.popupTopGap + entries.reduce(0) { $0 + $1.0.height + gap } + 40
        try Snapshot.write(url, size: SizeF(width: width, height: height), background: { wallpaper($0) }) { canvas, _ in
            var y = Theme.Size.popupTopGap
            for (size, _, draw) in entries {
                let rect = RectF(x: ((width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
                PopupChrome.card(canvas, rect)
                canvas.clipped(to: rect, radius: Theme.Radius.card) {
                    canvas.transformed(dx: rect.x, dy: rect.y) { draw(canvas) }
                }
                y += size.height + gap
            }
        }
    }

    /// A stand-in desktop behind the pop-ups.
    static func wallpaper(_ canvas: Canvas) {
        canvas.gradient(canvas.bounds, radius: 0, from: Colour(hex: 0x2E4A72), to: Colour(hex: 0xB08A6E), angle: 135)
        canvas.glow(PointF(x: canvas.size.width * 0.75, y: canvas.size.height * 0.2), rx: canvas.size.width * 0.5,
                    ry: canvas.size.height * 0.6, Colour(hex: 0xF0C9A0, alpha: 0.35))
    }
}
