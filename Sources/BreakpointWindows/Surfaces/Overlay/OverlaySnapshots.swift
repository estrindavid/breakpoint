import BreakpointCore
import BreakpointRuntime
import Foundation

extension SnapshotCatalogue {
    /// The break overlay in every state, into `directory`/overlay, at 1440 × 900 over a bright
    /// stand-in desktop (the live overlay covers the real one).
    static func overlaySnapshots(_ directory: URL) throws -> Int {
        let folder = directory.appendingPathComponent("overlay")
        var count = 0
        for (name, shot) in OverlayShots.all {
            try Snapshot.write(folder.appendingPathComponent("\(name).png"), size: shot.size, scale: 1, background: nil,
                               focused: shot.focused.map(OverlayView.controlID)) { canvas, controls in
                if shot.focused != nil { controls.debugShowFocus() }
                OverlayView.draw(canvas, controls, shot.active, shot.presentation, handlers: OverlayView.Handlers())
            }
            count += 1
        }
        return count
    }
}

/// One overlay snapshot: a break, how it is presented and the display's size.
@MainActor
struct OverlayShot {
    var active: ActiveBreakState
    var presentation: OverlayPresentation
    var size = SizeF(width: 1440, height: 900)
    var focused: OverlayControl?

    init(_ active: ActiveBreakState, liveElapsed: TimeInterval? = nil, focused: OverlayControl? = nil,
         _ adjust: (inout OverlayPresentation) -> Void = { _ in }) {
        self.active = active
        var p = OverlayPresentation(liveElapsed: liveElapsed ?? active.elapsed)
        p.focused = focused
        p.ambient = OverlayView.isAmbient(active) ? 1 : 0
        adjust(&p)
        presentation = p
        self.focused = focused
    }
}

@MainActor
enum OverlayShots {
    static var all: [(String, OverlayShot)] {
        var list: [(String, OverlayShot)] = []
        // Every kind mid-break.
        for kind in BreakKind.allCases {
            list.append(("\(kind.rawValue)-middle", OverlayShot(activeBreak(kind, progress: 0.5))))
        }
        // The pace ring at moments of a repetition, and a step without a tempo.
        let neck = BuiltInRoutines.neckAndShoulders
        list.append(("move-pace-up", OverlayShot(activeBreak(.move, elapsed: 31.5, routine: neck))))
        list.append(("move-pace-down", OverlayShot(activeBreak(.move, elapsed: 34.5, routine: neck))))
        list.append(("move-pace-circle", OverlayShot(activeBreak(.move, elapsed: 2.5, routine: BuiltInRoutines.wristsAndForearms))))
        var plain = activeBreak(.move, elapsed: 40, routine: neck)
        plain.step?.step.tempo = []
        list.append(("move-plain-step", OverlayShot(plain)))
        list.append(("move-step-change", OverlayShot(activeBreak(.move, elapsed: 30.2, routine: neck)) { p in
            p.stepChange = (OverlayStepText(activeBreak(.move, elapsed: 29, routine: neck)), 0.5)
        }))
        // The Skip guard filling, then enabled; Done; extend shown and used up.
        list.append(("skip-guard-1s", OverlayShot(activeBreak(.eyes, elapsed: 1))))
        list.append(("skip-guard-2.7s", OverlayShot(activeBreak(.eyes, elapsed: 2.7))))
        list.append(("skip-enabled", OverlayShot(activeBreak(.eyes, elapsed: 6))))
        list.append(("eyes-done", OverlayShot(activeBreak(.eyes, progress: 0.86))))
        list.append(("move-done", OverlayShot(activeBreak(.move, progress: 0.86))))
        list.append(("breathe-extended-once", OverlayShot(activeBreak(.breathe, progress: 0.6, extensions: 1))))
        list.append(("breathe-extended-max", OverlayShot(activeBreak(.breathe, progress: 0.6, extensions: 2))))
        // An agent needs you: amber chip, Back to work focused.
        for kind in [BreakKind.move, .walk, .eyes] {
            var a = activeBreak(kind, progress: 0.45)
            a.needsYou = true
            a.agentChip = .needsYou(agent: "Claude")
            if kind == .walk { a.instruction = Copy.walkNeedsYouInstruction(agent: "Claude") }
            list.append(("needs-you-\(kind.rawValue)", OverlayShot(a, focused: .primary)))
        }
        // Walk: ambient, welcome back, past the target.
        var ambient = activeBreak(.walk, progress: 0.55)
        ambient.ambient = true
        list.append(("walk-ambient", OverlayShot(ambient)))
        var welcome = activeBreak(.walk, progress: 0.75)
        welcome.welcomeBack = true
        list.append(("walk-welcome-back", OverlayShot(welcome, focused: .primary)))
        list.append(("walk-past-target", OverlayShot(activeBreak(.walk, progress: 1.3))))
        // Breathe at the top of an inhale and near the bottom of an exhale.
        list.append(("breathe-inhale", OverlayShot(activeBreak(.breathe, elapsed: 16))))
        list.append(("breathe-exhale", OverlayShot(activeBreak(.breathe, elapsed: 21.2))))
        list.append(("breathe-reduce-motion", OverlayShot(activeBreak(.breathe, elapsed: 16)) { $0.reduceMotion = true }))
        // The closing moment, frame by frame on move, and its end on the other kinds.
        for t in [0.1, 0.3, 0.45, 1.2] {
            let a = completed(.move, "Shoulders done.", routine: neck)
            list.append(("complete-move-\(String(format: "%.2f", t))", OverlayShot(a, liveElapsed: a.elapsed + t)))
        }
        for (kind, line) in [(BreakKind.eyes, "That's twenty seconds."), (.walk, "That's six minutes."), (.breathe, "Breathing done.")] {
            let a = completed(kind, line)
            list.append(("complete-\(kind.rawValue)", OverlayShot(a, liveElapsed: a.elapsed + 1.2)))
        }
        // A Settings preview; the tour's rehearsal (agent working, then done); the first-use hint.
        var preview = activeBreak(.eyes, progress: 0.2)
        preview.isPreview = true
        list.append(("preview", OverlayShot(preview)))
        list.append(("rehearsal-working", OverlayShot(sampleBreak(elapsed: 5))))
        list.append(("rehearsal-done", OverlayShot(sampleBreak(elapsed: 12))))
        var hint = activeBreak(.eyes, progress: 0.25)
        hint.hint = HintCopy.breakChip(agent: "Claude")
        list.append(("first-break-hint", OverlayShot(hint)))
        var noAgent = activeBreak(.eyes, progress: 0.25)
        noAgent.agentChip = .clock(AppState.previewNow)
        noAgent.hint = HintCopy.breakNoAgent
        list.append(("first-break-hint-no-agent", OverlayShot(noAgent)))
        // Agent chip states.
        let chips: [(String, AgentChipState)] = [("several-working", .severalWorking(2)), ("done", .done(agent: "Claude"))]
        for (name, chip) in chips {
            var a = activeBreak(.eyes, progress: 0.4)
            a.agentChip = chip
            list.append(("chip-\(name)", OverlayShot(a)))
        }
        // Keyboard focus, high contrast, the other displays, a small display, the fades.
        list.append(("focus-skip", OverlayShot(activeBreak(.breathe, progress: 0.3), focused: .skip)))
        list.append(("focus-extend", OverlayShot(activeBreak(.move, progress: 0.3), focused: .extend)))
        list.append(("high-contrast-move", OverlayShot(activeBreak(.move, progress: 0.4)) { $0.highContrast = true }))
        list.append(("secondary-display", OverlayShot(activeBreak(.move, progress: 0.4)) { $0.showsContent = false }))
        list.append(("secondary-display-walk", OverlayShot(activeBreak(.walk, progress: 0.4)) { $0.showsContent = false }))
        var small = OverlayShot(activeBreak(.move, progress: 0.4))
        small.size = SizeF(width: 1280, height: 720)
        list.append(("small-display-move", small))
        list.append(("exit-content-half", OverlayShot(activeBreak(.eyes, progress: 1)) { $0.contentOpacity = 0.5 }))
        list.append(("esc-pulse", OverlayShot(activeBreak(.eyes, progress: 0.4)) { $0.hintPulse = 0.5 }))
        return list
    }

    // MARK: Breaks, built with the coordinator's own rules

    static func activeBreak(_ kind: BreakKind, progress: Double, extensions: Int = 0) -> ActiveBreakState {
        let base = PreviewData().activeBreak(kind: kind, progress: 0)
        return activeBreak(kind, elapsed: (base.plannedLength + Double(extensions) * Timing.extensionLength) * progress,
                           extensions: extensions)
    }

    static func activeBreak(_ kind: BreakKind, elapsed: TimeInterval, extensions: Int = 0, routine: Routine? = nil) -> ActiveBreakState {
        let now = AppState.previewNow
        var session = BreakSessionRules.makeSession(kind: kind, opportunity: nil, settings: .defaults, expectedRun: 6 * 60 + 10,
                                                    agentName: "Claude", copyRotation: 0, now: now.addingTimeInterval(-elapsed),
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

    static func completed(_ kind: BreakKind, _ line: String, routine: Routine? = nil) -> ActiveBreakState {
        let length = kind == .walk ? 6 * 60.0 : activeBreak(kind, elapsed: 0, routine: routine).plannedLength
        var a = activeBreak(kind, elapsed: length, routine: routine)
        a.completion = BreakCompletionState(line: line, at: length)
        return a
    }

    /// The tour's sample break `elapsed` seconds in, as the coordinator builds it.
    static func sampleBreak(elapsed: TimeInterval) -> ActiveBreakState {
        let now = AppState.previewNow
        let copy = BreakCopyLibrary.variant(for: .eyes, rotation: 0, agentName: "Claude")
        let session = BreakSession(kind: .eyes, startedAt: now.addingTimeInterval(-elapsed), plannedLength: Timing.tourBreakLength,
                                   copy: copy)
        let chip: AgentChipState = TourPolicy.sampleAgentWorking(breakElapsed: elapsed)
            ? .working(agent: "Claude", elapsed: TourPolicy.sampleRunElapsed(breakElapsed: elapsed)) : .done(agent: "Claude")
        return ActiveBreakState(kind: .eyes, title: copy.title, instruction: copy.instruction, startedAt: session.startedAt,
                                elapsed: elapsed, plannedLength: Timing.tourBreakLength,
                                doneAvailable: BreakSessionRules.isDoneAvailable(session, now: now), agentChip: chip,
                                isRehearsal: true)
    }
}
