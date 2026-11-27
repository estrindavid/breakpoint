import AppKit
import CoreGraphics
import SwiftUI
import BreakpointCore

/// Plays any break screen or sequence on the real windows with sample data, for reviewing motion
/// and window behaviour that snapshots cannot show. It is a small stand-in coordinator: it owns its
/// own `AppState`, implements `AppActions` the way the app does (using `BreakSessionRules`), and
/// drives the same controllers the app uses. It records nothing and writes nothing (except the
/// watchdog's log line in the `watchdog` scenario).
///
/// Every scenario closes itself: when nothing is left on screen, or after `maxDuration`, it calls
/// `onFinish` (the app quits). Esc Esc closes any overlay; the pop-ups time out on their own.
///
/// From the app: `Breakpoint --demo NAME` (see `BreakDemo.catalogue`). `--demo list` prints the
/// names. `--demo selftest` runs scripted checks of the real windows and prints PASS / FAIL lines.
@MainActor
public final class BreakDemo {
    /// Scenario names and what each shows.
    public static let catalogue: [(name: String, summary: String)] = [
        ("nudge-eyes", "Nudge for a 20-sec eye rest (no auto-start). Start opens the overlay."),
        ("nudge-move", "Nudge for a 2-min stretch while Claude works. Hover for why-now, × and keycaps; ⌃⌥⌘B / ⌃⌥⌘. work."),
        ("nudge-walk", "Nudge for a 6-min walk."),
        ("nudge-breathe", "Nudge for a 1-min breather."),
        ("autostart", "The eye-rest ladder: card counts down from 10, the chip takes over at 5 by the pointer, then the overlay. Any key, hover or Not now cancels."),
        ("overlay-eyes", "Eye-rest overlay, 20 s, Claude working."),
        ("overlay-move", "The two-minute routine; → / ← change steps; 1 more minute appends a step."),
        ("overlay-walk", "Walk overlay counting up toward 6 min; I'm back (Return) ends it."),
        ("overlay-breathe", "Breathing ring, 60 s."),
        ("needs-you", "Move overlay; after 4 s Claude needs you: chime, amber chip, Back to work focused."),
        ("agent-done", "Eye-rest overlay; after 4 s the chip turns to “Claude is done. No rush.”; a resume card follows the exit."),
        ("walk-ambient", "Walk overlay that goes ambient after 4 s without input (demo-shortened from 30 s); move the pointer for Welcome back."),
        ("entrance", "Eye-rest overlay with the entrance held at 0 s: → / ← step it by 0.05 s; Esc Esc closes."),
        ("preview", "A Settings preview break: 5 s, one Esc closes."),
        ("resume-one", "Resume card: Claude finished · ran 6 min."),
        ("resume-several", "Resume card for three agents."),
        ("resume-needs-you", "Needs-you resume card (stays until clicked)."),
        ("resume-error", "Resume card: Claude stopped with an error."),
        ("away-note", "Away note with Undo (Undo shows “Timers restored”)."),
        ("toast", "“Timers restored” toast."),
        ("call-toast", "Call-pause toast with Resume."),
        ("wind-down", "Wind-down card: hold 15 more minutes (3 s), or Wrap up for the note."),
        ("stack", "Three pop-ups arriving: a toast, an away note, then a needs-you card evicts the toast."),
        ("flow", "Nudge → Start (by itself after 3 s) → stretch → Claude finishes → Done → resume card."),
        ("ceiling", "An overlay whose coordinator never ends it: the controller's backstop closes it ~2 s past the ceiling."),
        ("watchdog", "Overlay, then the main thread stalls 5 s: the watchdog exits the process within ~3.5 s."),
        ("selftest", "Scripted checks of the real windows; prints PASS / FAIL and quits."),
    ]

    public let state: AppState
    private var actions = AppActions.noop
    private let stack: TransientPanelStack
    private let hotKeys = HotKeyCenter()
    private let focusRestorer = FocusRestorer()
    private let watchdog: OverlayWatchdog
    private let sound = SoundPlayer()
    private var surfaces: [SurfaceController] = []
    public private(set) var overlay: BreakOverlayController!
    private var nudgeController: NudgePanelController!

    private let onFinish: () -> Void
    private let soundVolume: Double
    private var session: BreakSession?
    private var agentChip: AgentChipState = .working(agent: "Claude", elapsed: 102)
    private var agentWorkingSince = Date().addingTimeInterval(-102)
    private var finishedDuringBreak = false
    private var autoStartDeadline: Date?
    private var autoStartBegan: Date?
    private var ambientAfter: TimeInterval = Timing.walkAmbientAfter
    private var welcomeBackAfter: TimeInterval = Timing.walkWelcomeBackAfter
    private var idlePeak: TimeInterval = 0
    private var frozenCoordinator = false
    private var tickTimer: Timer?
    private var idleChecks = 0
    private var scheduled: [DispatchWorkItem] = []
    private let data = PreviewData(now: Date())

    /// - Parameters:
    ///   - soundVolume: volume of the needs-you chime in the demo (0 mutes it).
    ///   - onFinish: called once when the scenario is over.
    public init(soundVolume: Double = 0.5, onFinish: @escaping () -> Void) {
        self.soundVolume = soundVolume
        self.onFinish = onFinish
        state = AppState(sessions: [], settings: .defaults, now: Date())
        stack = TransientPanelStack(position: { .topCentre })
        watchdog = OverlayWatchdog(logURL: BreakpointPaths.live().watchdogLog, appURL: Bundle.main.bundleURL)
        actions = makeActions()
        nudgeController = NudgePanelController(state: state, actions: actions, stack: stack, hotKeys: hotKeys)
        overlay = BreakOverlayController(state: state, actions: actions, focusRestorer: focusRestorer, watchdog: watchdog)
        surfaces = [
            nudgeController,
            CountdownChipController(state: state),
            overlay,
            ResumeCardController(state: state, actions: actions, stack: stack),
            AwayNoteController(state: state, actions: actions, stack: stack),
            ToastController(state: state, actions: actions, stack: stack),
            WindDownCardController(state: state, actions: actions, stack: stack),
        ]
        stack.onEvicted = { [weak self] id in
            guard let self else { return }
            if self.state.nudge?.id == id { self.state.nudge = nil }
            self.state.cards.removeAll { $0.id == id }
            self.sync()
        }
    }

    /// Runs scenario `name`. Returns false for an unknown name.
    @discardableResult
    public func run(_ name: String, maxDuration: TimeInterval = 150) -> Bool {
        guard Self.catalogue.contains(where: { $0.name == name }) else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration) { [weak self] in self?.finish() }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        switch name {
        case "nudge-eyes": showNudge(.eyes, autoStart: false)
        case "nudge-move": showNudge(.move, autoStart: false)
        case "nudge-walk": showNudge(.walk, autoStart: false)
        case "nudge-breathe": showNudge(.breathe, autoStart: false)
        case "autostart": showNudge(.eyes, autoStart: true)
        case "overlay-eyes": startBreak(.eyes)
        case "overlay-move": startBreak(.move)
        case "overlay-walk": startBreak(.walk, length: 6 * 60)
        case "overlay-breathe": startBreak(.breathe)
        case "needs-you":
            startBreak(.move)
            after(4) { [weak self] in self?.agentNeedsYou() }
        case "agent-done":
            startBreak(.eyes)
            after(4) { [weak self] in self?.agentFinished() }
        case "walk-ambient":
            ambientAfter = 4
            welcomeBackAfter = 6
            startBreak(.walk, length: 6 * 60)
        case "entrance":
            startBreak(.eyes, length: 600)
            overlay.holdEntrance(at: 0)
        case "preview": startBreak(.eyes, preview: true)
        case "resume-one": addCard(.resume(ResumeCardContent(items: [data.resumeItem(data.claudeIdle, .finished(duration: 6 * 60))])))
        case "resume-several":
            addCard(.resume(ResumeCardContent(items: [data.resumeItem(data.claudeIdle, .finished(duration: 6 * 60)),
                                                       data.resumeItem(data.codexIdle, .finished(duration: 3 * 60)),
                                                       data.resumeItem(data.cursorIdle, .failed(reason: nil))])))
        case "resume-needs-you": addCard(.resume(ResumeCardContent(items: [data.resumeItem(data.claudeNeedsYou)])))
        case "resume-error": addCard(.resume(ResumeCardContent(items: [data.resumeItem(data.claudeIdle, .failed(reason: nil))])))
        case "away-note": addAwayNote()
        case "toast": addCard(.toast(ToastContent(text: Copy.timersRestored)))
        case "call-toast": addCard(.toast(ToastContent(text: Copy.callPauseToast(.microphone), action: .resumeFromCall)))
        case "wind-down": addWindDown()
        case "stack":
            addCard(.toast(ToastContent(text: Copy.timersRestored)))
            after(1.2) { [weak self] in self?.addAwayNote() }
            after(2.4) { [weak self] in
                guard let self else { return }
                self.addCard(.resume(ResumeCardContent(items: [self.data.resumeItem(self.data.claudeNeedsYou)])))
            }
        case "flow":
            showNudge(.move, autoStart: false)
            after(3) { [weak self] in self?.actions.acceptNudge() }
            after(9) { [weak self] in self?.agentFinished() }
            after(14) { [weak self] in
                guard let self, var session = self.session else { return }
                // Jump to 85% so Done shows, as if the stretch had run its course.
                session.startedAt = Date().addingTimeInterval(-session.totalLength * 0.85)
                self.session = session
            }
            after(17) { [weak self] in self?.actions.finishBreak(.done) }
        case "ceiling":
            frozenCoordinator = true
            startBreak(.eyes)
            if var session { session.startedAt = Date().addingTimeInterval(-(20 + Timing.overlayCeilingSlack)); self.session = session }
            after(5) { [weak self] in
                guard let self else { return }
                print("ceiling: overlay windows after the backstop: \(self.overlay.windowCount)")
                self.session = nil
                self.frozenCoordinator = false
            }
        case "watchdog":
            overlay.debugStallSeconds = 5
            startBreak(.eyes)
        case "selftest":
            selfTest()
        default:
            return false
        }
        sync()
        return true
    }

    // MARK: Loop

    private func tick() {
        let now = Date()
        state.now = now
        if case .working(let agent, _) = agentChip { agentChip = .working(agent: agent, elapsed: now.timeIntervalSince(agentWorkingSince)) }
        advanceAutoStart(now: now)
        if var session, !frozenCoordinator {
            session = BreakSessionRules.advanced(session, now: now)
            self.session = session
            if session.isPreview, session.elapsed(at: now) >= Timing.previewLength {
                endBreak()
            } else if BreakSessionRules.timerEnded(session, now: now) || BreakSessionRules.hitCeiling(session, now: now) {
                endBreak()
            } else if session.kind == .walk {
                idlePeak = max(idlePeak, Self.secondsSinceAnyInput())
            }
        }
        publishBreak(now: now)
        sync()
        trace(now: now)
        // Finish once nothing has been on screen for a second.
        let idle = state.nudge == nil && state.activeBreak == nil && state.cards.isEmpty && overlay.windowCount == 0
        idleChecks = idle ? idleChecks + 1 : 0
        if idleChecks >= 12 && scheduled.isEmpty { finish() }
    }

    private func sync() { surfaces.forEach { $0.sync() } }

    /// With `BREAKPOINT_DEMO_TRACE=1`, prints each change of what is on screen.
    private let tracing = ProcessInfo.processInfo.environment["BREAKPOINT_DEMO_TRACE"] == "1"
    private var lastTrace = ""
    private let traceStart = Date()

    private func trace(now: Date) {
        guard tracing else { return }
        var parts: [String] = []
        if let nudge = state.nudge { parts.append("nudge \(nudge.kind.rawValue) \(nudge.phase.rawValue) \"\(nudge.title)\"") }
        if let active = state.activeBreak {
            parts.append("break \(active.kind.rawValue)\(active.needsYou ? " needs-you" : "")\(active.ambient ? " ambient" : "")\(active.doneAvailable ? " done" : "") windows=\(overlay.windowCount) key=\(overlay.isKey)")
        } else if overlay.windowCount > 0 {
            parts.append("overlay exiting windows=\(overlay.windowCount)")
        }
        if !state.cards.isEmpty { parts.append("cards=\(state.cards.count) stack=\(stack.visibleIDs.count)") }
        if hotKeys.registeredCount > 0 { parts.append("hotkeys=\(hotKeys.registeredCount)") }
        let line = parts.isEmpty ? "nothing on screen" : parts.joined(separator: " | ")
        guard line != lastTrace else { return }
        lastTrace = line
        print(String(format: "%6.2f  ", now.timeIntervalSince(traceStart)) + line)
        fflush(stdout)
    }

    private func publishBreak(now: Date) {
        guard let session else {
            if state.activeBreak != nil { state.activeBreak = nil }
            return
        }
        var title = session.copy.title
        var instruction = session.copy.instruction
        var step: RoutineStepState?
        if let routine = session.routine, let current = session.currentStep {
            title = current.title
            instruction = current.instruction
            step = RoutineStepState(index: session.stepIndex, count: routine.steps.count, step: current,
                                    remaining: BreakSessionRules.stepRemaining(session, now: now))
        }
        let idle = Self.secondsSinceAnyInput()
        state.activeBreak = ActiveBreakState(
            id: session.id, kind: session.kind, title: title, instruction: instruction, step: step,
            startedAt: session.startedAt, elapsed: session.elapsed(at: now), plannedLength: session.totalLength,
            extensionsUsed: session.extensionsUsed, canExtend: BreakSessionRules.canExtend(session),
            doneAvailable: BreakSessionRules.isDoneAvailable(session, now: now),
            agentChip: session.needsYou ? .needsYou(agent: "Claude") : agentChip, needsYou: session.needsYou,
            ambient: session.kind == .walk && idle >= ambientAfter,
            welcomeBack: session.kind == .walk && idlePeak >= welcomeBackAfter && idle < 1,
            isPreview: session.isPreview)
    }

    // MARK: Scenario building blocks

    private func showNudge(_ kind: BreakKind, autoStart: Bool) {
        var nudge = data.nudge(kind: kind)
        nudge.shownAt = Date()
        if autoStart {
            nudge.phase = .autoStartCard
            nudge.autoStartRemaining = Timing.autoStartCountdown
            nudge.title = Copy.autoStartTitle(kind: kind, length: nudge.offer.length, remaining: Timing.autoStartCountdown)
            autoStartDeadline = Date().addingTimeInterval(Timing.autoStartCountdown)
            autoStartBegan = Date()
        }
        state.nudge = nudge
    }

    private func advanceAutoStart(now: Date) {
        guard var nudge = state.nudge, let deadline = autoStartDeadline, let began = autoStartBegan else { return }
        let since = now.timeIntervalSince(began)
        let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let click = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        if key < since || click < since {
            cancelAutoStart()
            return
        }
        let remaining = deadline.timeIntervalSince(now)
        if remaining <= 0 {
            autoStartDeadline = nil
            autoStartBegan = nil
            state.nudge = nil
            startBreak(.eyes)
            return
        }
        nudge.autoStartRemaining = remaining
        nudge.phase = remaining <= Timing.autoStartChipAt ? .countdownChip : .autoStartCard
        nudge.title = Copy.autoStartTitle(kind: nudge.kind, length: nudge.offer.length, remaining: remaining)
        state.nudge = nudge
    }

    private func cancelAutoStart() {
        guard var nudge = state.nudge, autoStartDeadline != nil else { return }
        autoStartDeadline = nil
        autoStartBegan = nil
        if nudge.phase == .countdownChip {
            state.nudge = nil
        } else {
            nudge.phase = .offer
            nudge.autoStartRemaining = nil
            nudge.title = Copy.nudgeTitle(kind: nudge.kind, length: nudge.offer.length)
            state.nudge = nudge
        }
        sync()
    }

    private func startBreak(_ kind: BreakKind, length: TimeInterval? = nil, preview: Bool = false) {
        guard session == nil else { return }
        state.nudge = nil
        autoStartDeadline = nil
        var session = BreakSessionRules.makeSession(kind: kind, opportunity: nil, settings: .defaults, expectedRun: 6 * 60 + 10,
                                                    agentName: "Claude", copyRotation: Int.random(in: 0..<4), now: Date(),
                                                    isPreview: preview)
        if let length, kind == .walk || length > session.plannedLength { session.plannedLength = length }
        self.session = session
        finishedDuringBreak = false
        idlePeak = 0
        publishBreak(now: Date())
        sync()
    }

    private func endBreak() {
        guard let ended = session else { return }
        session = nil
        state.activeBreak = nil
        if ended.needsYou {
            addCard(.resume(ResumeCardContent(items: [data.resumeItem(data.claudeNeedsYou)])))
        } else if finishedDuringBreak {
            addCard(.resume(ResumeCardContent(items: [data.resumeItem(data.claudeIdle, .finished(duration: 6 * 60))])))
        }
        sync()
    }

    private func agentNeedsYou() {
        guard var session else { return }
        if !session.needsYou, soundVolume > 0 { sound.play(.needsYouChime, volume: soundVolume) }
        session.needsYou = true
        self.session = session
    }

    private func agentFinished() {
        agentChip = .done(agent: "Claude")
        finishedDuringBreak = true
        if session == nil {
            addCard(.resume(ResumeCardContent(items: [data.resumeItem(data.claudeIdle, .finished(duration: 6 * 60))])))
        }
    }

    private func addCard(_ content: CardContent) {
        state.cards.append(CardState(content: content, createdAt: Date()))
        sync()
    }

    private func addAwayNote() {
        addCard(.awayNote(AwayNoteContent(decisionID: UUID(), kind: .move, text: Copy.creditedAway(duration: 6 * 60))))
    }

    private func addWindDown() {
        let late = Calendar.current.date(bySettingHour: 23, minute: 20, second: 0, of: Date()) ?? Date()
        addCard(.windDown(WindDownCardContent(now: late, stopTime: TimeOfDay(hour: 23, minute: 0), holdDuration: 3)))
    }

    /// Runs `work` after `delay`; the scenario is not over while any of these is pending.
    private func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled.removeAll { $0 === item }
                work()
            }
        }
        scheduled.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private var finished = false

    private func finish() {
        guard !finished else { return }
        finished = true
        tickTimer?.invalidate()
        scheduled.forEach { $0.cancel() }
        surfaces.forEach { $0.tearDown() }
        stack.dismissAll()
        hotKeys.unregisterAll()
        watchdog.stop()
        onFinish()
    }

    private static func secondsSinceAnyInput() -> TimeInterval {
        let any = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    // MARK: Actions (what the coordinator does, minus history and timers)

    private func makeActions() -> AppActions {
        AppActions(
            acceptNudge: { [weak self] in
                guard let self, let nudge = self.state.nudge else { return }
                self.startBreak(nudge.kind, length: nudge.offer.length)
            },
            declineNudge: { [weak self] in self?.state.nudge = nil; self?.sync() },
            startBreak: { [weak self] kind in self?.startBreak(kind) },
            skipBreak: { [weak self] in
                guard let self, let session = self.session else { return }
                guard session.isPreview || BreakSessionRules.isSkipEnabled(session, now: Date()) else { return }
                self.endBreak()
            },
            finishBreak: { [weak self] _ in self?.endBreak() },
            extendBreak: { [weak self] in
                guard let self, let session = self.session else { return }
                self.session = BreakSessionRules.extended(session)
                self.publishBreak(now: Date())
                self.sync()
            },
            stepRoutine: { [weak self] delta in
                guard let self, let session = self.session else { return }
                self.session = BreakSessionRules.stepped(session, by: delta, now: Date())
                self.publishBreak(now: Date())
                self.sync()
            },
            undoLastDecision: { [weak self] in
                guard let self else { return }
                self.state.cards.removeAll { if case .awayNote = $0.content { return true } else { return false } }
                self.addCard(.toast(ToastContent(text: Copy.timersRestored)))
            },
            resume: { [weak self] in
                self?.state.cards.removeAll { if case .toast = $0.content { return true } else { return false } }
                self?.sync()
            },
            dismissCard: { [weak self] id in
                self?.state.cards.removeAll { $0.id == id }
                self?.sync()
            },
            windDownExtend: { [weak self] in
                self?.state.cards.removeAll { if case .windDown = $0.content { return true } else { return false } }
                self?.sync()
            },
            windDownWrapUp: { [weak self] in
                guard let self else { return }
                let lines = WindDownPolicy.wrapUpNote(sessions: [self.data.claudeIdle, self.data.codexIdle])
                self.state.cards = self.state.cards.map { card in
                    guard case .windDown(var content) = card.content else { return card }
                    content.phase = .note(lines: lines)
                    var updated = card
                    updated.content = .windDown(content)
                    return updated
                }
                self.sync()
            },
            copyWrapUpNote: {},
            ignoreNudge: { [weak self] in self?.state.nudge = nil; self?.sync() },
            cancelAutoStart: { [weak self] in self?.cancelAutoStart() })
    }

    // MARK: Self-test

    private var results: [(String, Bool)] = []

    private func check(_ name: String, _ condition: Bool) {
        results.append((name, condition))
        print("\(condition ? "PASS" : "FAIL")  \(name)")
        fflush(stdout)
    }

    /// Scripted checks of the real windows (about 7 s, overlays up for about 5 s in all).
    /// Prints PASS / FAIL lines.
    private func selfTest() {
        let frontBefore = NSWorkspace.shared.frontmostApplication
        let screens = NSScreen.screens.count
        print("selftest: \(screens) display(s); frontmost app: \(frontBefore?.localizedName ?? "none")")
        for cue in SoundID.allCases {
            let lufs = ChimeSynth.measuredLUFS(for: cue), peak = ChimeSynth.peakDBFS(for: cue)
            check("sound: \(cue.rawValue) at full volume \(String(format: "%.1f", lufs)) LUFS, peak \(String(format: "%.1f", peak)) dBFS",
                  lufs <= -18 && peak < -1)
            // ≥ 30 ms attack, no transient: the first 25 ms stay well under the cue's peak.
            let samples = ChimeSynth.samples(for: cue).map { abs($0) }
            let overall = samples.max() ?? 1
            let early = samples.prefix(Int(0.025 * ChimeSynth.sampleRate)).max() ?? 1
            check("sound: \(cue.rawValue) soft start (first 25 ms reach \(Int(100 * early / overall))% of peak)", early < 0.8 * overall)
        }
        startBreak(.eyes)
        after(0.5) { [weak self] in
            guard let self else { return }
            self.check("overlay: one window per display (\(self.overlay.windowCount)/\(screens))", self.overlay.windowCount == screens)
            if Self.screenIsLocked {
                print("SKIP  overlay: active display's window is key (the screen is locked; the lock screen holds the keyboard)")
            } else {
                self.check("overlay: active display's window is key", self.overlay.isKey)
            }
            self.check("overlay: Breakpoint was not activated", !NSApp.isActive)
            self.check("overlay: frontmost app unchanged",
                       NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore?.processIdentifier)
            self.check("overlay: watchdog running", self.watchdog.isRunning)
            // Real key events through the app's event queue (the same path as a key press).
            self.postKey(KeyCode.escape)
        }
        after(0.8) { [weak self] in
            guard let self else { return }
            self.check("Esc once: overlay stays", self.overlay.windowCount == screens && self.session != nil)
            self.postKey(KeyCode.escape)
        }
        after(1.1) { [weak self] in
            guard let self else { return }
            self.check("Esc Esc inside the 3 s guard: nothing happens", self.session != nil)
        }
        after(3.15) { [weak self] in self?.postKey(KeyCode.escape) }
        after(3.35) { [weak self] in self?.postKey(KeyCode.escape) }
        after(3.6) { [weak self] in
            guard let self else { return }
            self.check("Esc Esc after the guard: break ends", self.session == nil)
        }
        after(4.3) { [weak self] in
            guard let self else { return }
            self.check("exit: windows gone after the 0.6 s exit", self.overlay.windowCount == 0)
            self.check("exit: watchdog stopped", !self.watchdog.isRunning)
            self.check("exit: frontmost app is the one from before",
                       NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore?.processIdentifier)
            self.showNudge(.move, autoStart: false)
            self.sync()
        }
        after(4.7) { [weak self] in
            guard let self else { return }
            self.check("nudge: hotkeys registered while visible (\(self.hotKeys.registeredCount))", self.hotKeys.registeredCount == 2)
            self.check("nudge: Breakpoint still not active", !NSApp.isActive)
            self.actions.declineNudge()
        }
        after(5.0) { [weak self] in
            guard let self else { return }
            self.check("nudge: hotkeys unregistered when it closes", self.hotKeys.registeredCount == 0)
            // Ceiling backstop: a break the "coordinator" never ends, already just short of
            // ceiling + grace.
            self.frozenCoordinator = true
            self.startBreak(.eyes)
            if var session = self.session {
                session.startedAt = Date().addingTimeInterval(-(20 + Timing.overlayCeilingSlack + BreakTiming.ceilingBackstopGrace - 0.3))
                self.session = session
            }
            self.publishBreak(now: Date())
            self.sync()
        }
        after(5.2) { [weak self] in
            guard let self else { return }
            self.check("ceiling: overlay up past its ceiling", self.overlay.windowCount == screens)
        }
        after(7.0) { [weak self] in
            guard let self else { return }
            self.check("ceiling: backstop closed the windows", self.overlay.windowCount == 0)
            self.session = nil
            self.state.activeBreak = nil
            self.frozenCoordinator = false
            self.sync()
            self.check("all windows closed at the end", self.overlay.windowCount == 0)
            let failures = self.results.filter { !$0.1 }.count
            print("selftest: \(self.results.count - failures) passed, \(failures) failed")
            self.finish()
        }
    }

    /// The login window's lock screen is up (read without any permission).
    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Posts a key-down / key-up pair to the app's event queue, addressed to the key window.
    private func postKey(_ keyCode: UInt16) {
        let window = NSApp.keyWindow ?? NSApp.windows.first { $0 is OverlayPanel && $0.canBecomeKey }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                                            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
}
