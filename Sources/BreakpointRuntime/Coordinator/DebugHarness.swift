#if DEBUG
import Foundation
import BreakpointCore

// The end-to-end harness (debug builds only; compiled out of release builds, which
// scripts/build-app.sh makes). It lets scripts/e2e.sh drive the whole app through the real
// `breakpoint` CLI in seconds instead of hours, without anything appearing on screen:
//
// - `--debug-headless`: `SurfaceRecorder` replaces every window controller. It logs what would be
//   on screen and plays the part of the real controllers' timers (nudge ignored after 10 s, cards
//   auto-hidden), without hover. No window, panel, status item, alert, sound or hotkey.
// - `--debug-simulate`: `SimulatedActivityMonitor` replaces the input, call and presence signals;
//   `RecordingHeadphones` the AirPods check. The coordinator's clock can be moved forward.
// - `--debug-timers SCREEN,STILL`, `--debug-trace`.
//
// Commands arrive as `breakpoint debug …` (a `WireMessage.command` named "debug") and are listed
// in `DebugHarness.usage`.

@MainActor
final class DebugHarness {
    let options: DebugOptions
    let recorder: SurfaceRecorder
    let simulated: SimulatedActivityMonitor?
    let recordingHeadphones: RecordingHeadphones?
    let recordingSound: RecordingSound?
    /// The release feed, never from the network: a local file or a simulated failure
    /// (`breakpoint debug update-feed`). Used whenever the app runs headless or simulated.
    let fakeFeed: FakeUpdateFetcher?
    private weak var coordinator: AppCoordinator?

    init(options: DebugOptions) {
        self.options = options
        recorder = SurfaceRecorder(drivesTimers: options.headless, trace: options.trace)
        simulated = options.simulate ? SimulatedActivityMonitor() : nil
        recordingHeadphones = options.simulate ? RecordingHeadphones() : nil
        recordingSound = options.headless ? RecordingSound() : nil
        fakeFeed = (options.headless || options.simulate) ? FakeUpdateFetcher() : nil
    }

    var monitor: ActivityMonitoring? { simulated }
    var headphones: HeadphoneMotionMonitoring? { recordingHeadphones }
    var sound: SoundPlaying? { recordingSound }
    var updateFetcher: UpdateFetching? { fakeFeed }

    func attach(to coordinator: AppCoordinator) {
        self.coordinator = coordinator
        recorder.attach(state: coordinator.state, actions: coordinator.actions)
        simulated?.now = { [weak coordinator] in coordinator?.currentDate() ?? Date() }
        recordingSound?.onPlay = { [weak self] sound in self?.recorder.note("sound: \(sound.rawValue)") }
        // Installs run step by step within each command, and never against this build's own folder
        // or the real release key: `debug update-location` and `debug update-key` set stand-ins.
        if fakeFeed != nil {
            coordinator.updateWorkIsSynchronous = true
            coordinator.updateKeyOverride = ""
            coordinator.updateLocationOverride = coordinator.paths.home.appendingPathComponent("no-app-set")
        }
    }

    func didStart() {
        guard let coordinator else { return }
        if let preset = options.timers {
            coordinator.timers = TimerState(screenTime: preset.screen, stillTime: preset.still)
        }
        var modes: [String] = []
        if options.headless { modes.append("headless") }
        if options.simulate { modes.append("simulated signals") }
        recorder.note("debug harness: \(modes.isEmpty ? "trace only" : modes.joined(separator: ", ")); home \(coordinator.paths.home.path)")
    }

    static let usage = """
    breakpoint debug state                      JSON: timers, presence, pause, nudge, break, cards, decision,
                                                sessions, history, sounds, headphones, integrations, rotation, …
    breakpoint debug log [FROM]                 what was (or would have been) on screen, from line FROM
    breakpoint debug timers SCREEN STILL        set the timers (seconds)
    breakpoint debug tick                       run one engine tick now
    breakpoint debug advance SECONDS            move the clock forward 1 s at a time, user present (simulate)
    breakpoint debug idle SECONDS               move the clock forward with no input at all (simulate)
    breakpoint debug jump HH:MM|+SECONDS        move the clock to the next HH:MM, or ahead, input kept fresh (simulate)
    breakpoint debug input key|pointer|scroll|drag|button-down|button-up   (simulate)
    breakpoint debug input display-sleep on|off|mirrored on|off   a display kept awake or mirrored (simulate)
    breakpoint debug call none|mic|camera|both  simulated call signals (simulate)
    breakpoint debug presence EVENT             locked, unlocked, displaysSlept, displaysWoke, systemWillSleep,
                                                systemDidWake, screensaverStarted, screensaverStopped (simulate)
    breakpoint debug headphones available|unavailable|movement|still   the AirPods check (simulate)
    breakpoint debug settings '{"key": value}'  change settings through the app's own update path
    breakpoint debug update-feed PATH|fail|none the release feed the update check reads: a local file, a failure,
                                                or nothing (the default; never the network). An archive the feed
                                                names is read from the feed's folder, by file name.
    breakpoint debug update-key BASE64|none     the release key to trust (a throwaway test key; default none)
    breakpoint debug update-location APP        the app bundle an install replaces (a stand-in under the home)
    breakpoint debug install-check unreachable|normal   after Install, the check's hook command reaches no app
                                                (it times out after 10 s and the row says why), or it does again
    breakpoint debug action NAME [ARG]          accept, decline, ignore, cancel-autostart, start KIND, skip,
                                                finish done|imBack|backToWork, extend, step ±1, undo,
                                                pause 30m|1h|tomorrow, resume, dismiss resume|awayNote|toast|windDown|all,
                                                wind-down-extend, wind-down-wrap-up, install ID, uninstall ID,
                                                preview-nudge KIND, preview-break KIND, complete-onboarding,
                                                delete-all-data (no confirmation), open-settings, activate
                                                (opens the popover), close-popover, check-updates, install-update,
                                                open-update (dismiss update = Later)
    breakpoint debug tour start|next|skip|popover-closed   the one-minute tour (SPEC §3.12): start it as
                                                Settings → General does, press a coach card's primary or
                                                Skip tour, or close the popover. Start / Not now on its sample
                                                nudge are `action accept|decline`; its sample break ends with
                                                `action skip` or its timer; `action dismiss resume` clicks its card
    breakpoint debug popover CAUSE [pointer-on] what the status item reports while the popover is open
                                                (SPEC §3.8): click-outside, esc, other-app, space, display or
                                                menu-bar-hidden; pointer-on: the pointer is on the popover.
                                                `debug state` shows .popover.open and .popover.closedBy
    """

    // MARK: Commands

    func handle(_ arguments: [String]) -> String {
        guard let coordinator else { return "error: no coordinator" }
        guard let command = arguments.first else { return Self.usage }
        let rest = Array(arguments.dropFirst())
        func needsSimulation() -> String? {
            simulated == nil ? "error: start the app with --debug-simulate for \(command)" : nil
        }
        switch command {
        case "help":
            return Self.usage
        case "state":
            return stateJSON()
        case "log":
            let from = rest.first.flatMap(Int.init) ?? 0
            return recorder.lines(from: from).joined(separator: "\n")
        case "timers":
            guard rest.count == 2, let screen = TimeInterval(rest[0]), let still = TimeInterval(rest[1]) else {
                return "error: timers SCREEN STILL"
            }
            coordinator.timers = TimerState(screenTime: screen, stillTime: still)
            coordinator.publish()
            return "ok"
        case "tick":
            coordinator.tick()
            coordinator.syncSurfacesNow()
            return "ok"
        case "advance", "idle":
            if let error = needsSimulation() { return error }
            guard let seconds = rest.first.flatMap(Int.init), seconds >= 0, seconds <= 24 * 3600 else {
                return "error: \(command) SECONDS"
            }
            step(seconds: seconds, present: command == "advance")
            return "ok"
        case "jump":
            if let error = needsSimulation() { return error }
            if let ahead = rest.first, ahead.hasPrefix("+"), let seconds = TimeInterval(ahead.dropFirst()), seconds >= 0 {
                jump(by: seconds)
                return "ok"
            }
            guard let time = rest.first.flatMap(TimeOfDay.init(string:)) else { return "error: jump HH:MM|+SECONDS" }
            jump(to: time)
            return "ok"
        case "update-feed":
            guard let fakeFeed else { return "error: start the app with --debug-headless or --debug-simulate for update-feed" }
            switch rest.first {
            case nil: return "error: update-feed PATH|fail|none"
            case "fail": fakeFeed.source = .failure
            case "none": fakeFeed.source = .none
            case let path?: fakeFeed.source = .file(URL(fileURLWithPath: path))
            }
            return "ok"
        case "install-check":
            // `unreachable`: the check's hook command sends to a home with no app listening, so it
            // times out and the row says why, as when hooks cannot reach the socket.
            switch rest.first {
            case "unreachable":
                coordinator.debugInstallCheckEnvironment = [BreakpointPaths.homeOverrideVariable:
                    coordinator.paths.home.appendingPathComponent("nowhere").path]
            case "normal": coordinator.debugInstallCheckEnvironment = [:]
            default: return "error: install-check unreachable|normal"
            }
            return "ok"
        case "update-key":
            guard fakeFeed != nil, let key = rest.first else { return "error: update-key BASE64|none (headless or simulated)" }
            coordinator.updateKeyOverride = key == "none" ? "" : key
            coordinator.publish()
            return "ok"
        case "update-location":
            guard fakeFeed != nil, let path = rest.first else { return "error: update-location APP (headless or simulated)" }
            coordinator.updateLocationOverride = URL(fileURLWithPath: path)
            coordinator.publish()
            return "ok"
        case "input":
            if let error = needsSimulation() { return error }
            return input(rest)
        case "call":
            if let error = needsSimulation() { return error }
            let signals: CallSignals
            switch rest.first {
            case "none": signals = []
            case "mic": signals = .microphone
            case "camera": signals = .camera
            case "both": signals = [.microphone, .camera]
            default: return "error: call none|mic|camera|both"
            }
            simulated?.setCallSignals(signals)
            coordinator.syncSurfacesNow()
            return "ok"
        case "presence":
            if let error = needsSimulation() { return error }
            guard let event = rest.first.flatMap(PresenceEvent.init(rawValue:)) else {
                return "error: presence \(PresenceEvent.allCases.map(\.rawValue).joined(separator: "|"))"
            }
            simulated?.post(event)
            coordinator.syncSurfacesNow()
            return "ok"
        case "headphones":
            if let error = needsSimulation() { return error }
            guard let headphones = recordingHeadphones else { return "error: no headphones" }
            switch rest.first {
            case "available": headphones.isAvailable = true
            case "unavailable": headphones.isAvailable = false
            case "movement": headphones.movement = true
            case "still": headphones.movement = false
            default: return "error: headphones available|unavailable|movement|still"
            }
            return "ok"
        case "settings":
            return applySettings(rest.joined(separator: " "))
        case "tour":
            switch rest.first {
            case "start": coordinator.replayTour()
            case "next": coordinator.actions.tour(.next)
            case "skip": coordinator.actions.tour(.skip)
            case "popover-closed": coordinator.actions.popoverVisibilityChanged(false)
            default: return "error: tour start|next|skip|popover-closed"
            }
            coordinator.syncSurfacesNow()
            return "ok"
        case "popover":
            // What the real status item reports when something may close the popover (SPEC §3.8).
            let causes: [String: PopoverCloseCause] = [
                "click-outside": .clickOutside, "esc": .escape, "other-app": .otherAppActive,
                "space": .spaceChanged, "display": .displayChanged, "menu-bar-hidden": .menuBarHidden,
            ]
            guard let cause = rest.first.flatMap({ causes[$0] }),
                  rest.count == 1 || (rest.count == 2 && rest[1] == "pointer-on") else {
                return "error: popover \(causes.keys.sorted().joined(separator: "|")) [pointer-on]"
            }
            coordinator.actions.popoverMayClose(cause, rest.count == 2)
            coordinator.syncSurfacesNow()
            return "ok"
        case "action":
            let result = action(rest)
            coordinator.syncSurfacesNow()
            return result
        default:
            return "error: unknown debug command \(command)\n" + Self.usage
        }
    }

    /// Moves the clock forward one second at a time, running the engine and the (recording)
    /// surfaces at every step, as if that much time had passed.
    private func step(seconds: Int, present: Bool) {
        guard let coordinator else { return }
        for _ in 0..<seconds {
            coordinator.clockOffset += 1
            if present { simulated?.touchPointer() }
            coordinator.tick()
            coordinator.syncSurfacesNow()
        }
    }

    /// Moves the clock to the next `time` without the jump counting as time at the screen or away.
    private func jump(to time: TimeOfDay) {
        guard let coordinator else { return }
        let now = coordinator.currentDate()
        let calendar = coordinator.calendar
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        guard var target = calendar.date(from: components) else { return }
        if target <= now { target = calendar.date(byAdding: .day, value: 1, to: target) ?? target }
        jump(by: target.timeIntervalSince(now))
    }

    /// Moves the clock ahead by `delta` without the jump counting as time at the screen or away.
    private func jump(by delta: TimeInterval) {
        guard let coordinator else { return }
        coordinator.clockOffset += delta
        coordinator.lastTick = coordinator.lastTick.addingTimeInterval(delta)
        simulated?.shift(by: delta)
        coordinator.tick()
        coordinator.syncSurfacesNow()
    }

    private func input(_ rest: [String]) -> String {
        guard let simulated, let coordinator else { return "error" }
        switch rest.first {
        case "key": simulated.pressKey()
        case "pointer": simulated.touchPointer()
        case "scroll": simulated.scroll()
        case "drag": simulated.drag()
        case "button-down": simulated.buttonDown = true
        case "button-up": simulated.buttonDown = false
        case "display-sleep":
            simulated.displaySleepPrevented = rest.dropFirst().first == "on"
        case "mirrored":
            simulated.displayMirrored = rest.dropFirst().first == "on"
        default: return "error: input key|pointer|scroll|drag|button-down|button-up|display-sleep on|off|mirrored on|off"
        }
        coordinator.tick()
        coordinator.syncSurfacesNow()
        return "ok"
    }

    private func applySettings(_ json: String) -> String {
        guard let coordinator else { return "error" }
        guard let patch = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return "error: settings needs a JSON object, e.g. '{\"eyesEveryMinutes\": 10}'"
        }
        guard let data = try? JSONFile<Settings>.encoder.encode(coordinator.settings),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "error: encode" }
        for (key, value) in patch { object[key] = value }
        guard let merged = try? JSONSerialization.data(withJSONObject: object),
              let updated = try? JSONFile<Settings>.decoder.decode(Settings.self, from: merged) else {
            return "error: those values do not decode as settings"
        }
        coordinator.actions.updateSettings { $0 = updated }
        coordinator.syncSurfacesNow()
        return "ok"
    }

    private func action(_ rest: [String]) -> String {
        guard let coordinator else { return "error" }
        let actions = coordinator.actions
        let argument = rest.dropFirst().first
        func kind() -> BreakKind? { argument.flatMap(BreakKind.init(rawValue:)) }
        func integration() -> IntegrationID? { argument.flatMap(IntegrationID.init(rawValue:)) }
        switch rest.first {
        case "accept": actions.acceptNudge()
        case "decline": actions.declineNudge()
        case "ignore": actions.ignoreNudge()
        case "cancel-autostart": actions.cancelAutoStart()
        case "start":
            guard let kind = kind() else { return "error: start eyes|move|walk|breathe" }
            actions.startBreak(kind)
        case "skip": actions.skipBreak()
        case "finish":
            let reasons: [String: BreakFinishReason] = ["done": .done, "imBack": .imBack, "backToWork": .backToWork]
            guard let reason = argument.flatMap({ reasons[$0] }) else { return "error: finish done|imBack|backToWork" }
            actions.finishBreak(reason)
        case "extend": actions.extendBreak()
        case "step": actions.stepRoutine(argument.flatMap(Int.init) ?? 1)
        case "undo": actions.undoLastDecision()
        case "pause":
            let durations: [String: PauseDuration] = ["30m": .thirtyMinutes, "1h": .oneHour, "tomorrow": .untilTomorrow]
            guard let duration = argument.flatMap({ durations[$0] }) else { return "error: pause 30m|1h|tomorrow" }
            actions.pause(duration)
        case "resume": actions.resume()
        case "dismiss":
            let wanted = argument ?? "all"
            for card in coordinator.cards where wanted == "all" || Self.cardKind(card.content) == wanted {
                actions.dismissCard(card.id)
            }
        case "wind-down-extend": actions.windDownExtend()
        case "wind-down-wrap-up": actions.windDownWrapUp()
        case "install", "uninstall":
            guard let id = integration() else { return "error: \(rest[0]) \(IntegrationID.allCases.map(\.rawValue).joined(separator: "|"))" }
            if rest[0] == "install" { actions.install(id) } else { actions.uninstall(id) }
        case "preview-nudge":
            guard let kind = kind() else { return "error: preview-nudge KIND" }
            actions.previewNudge(kind)
        case "preview-break":
            guard let kind = kind() else { return "error: preview-break KIND" }
            actions.previewBreak(kind)
        case "complete-onboarding": actions.completeOnboarding()
        case "delete-all-data":
            do { try coordinator.deleteAllDataNow() } catch { return "error: \(error)" }
        case "open-settings": actions.openSettings()
        case "activate": coordinator.showPopover()
        case "close-popover": coordinator.closePopover()
        case "check-updates": actions.checkForUpdates()
        case "install-update": actions.installUpdate()
        case "open-update": actions.openUpdate()
        default:
            return "error: unknown action \(rest.first ?? "")"
        }
        return "ok"
    }

    static func cardHint(_ content: CardContent) -> String? {
        switch content {
        case .resume(let card): return card.hint
        case .toast(let toast): return toast.hint
        default: return nil
        }
    }

    static func cardKind(_ content: CardContent) -> String {
        switch content {
        case .resume: return "resume"
        case .awayNote: return "awayNote"
        case .toast: return "toast"
        case .windDown: return "windDown"
        case .update: return "update"
        }
    }

    static func cardText(_ content: CardContent) -> String {
        switch content {
        case .resume(let card): return card.title
        case .awayNote(let note): return note.text
        case .toast(let toast): return toast.text
        case .windDown(let card):
            switch card.phase {
            case .asking: return "\(Copy.windDownTitle(now: card.now)) hold \(Int(card.holdDuration)) s"
            case .note(let lines): return "Where you left off: " + lines.joined(separator: " | ")
            }
        case .update(let card):
            let buttons: String
            switch card.stage {
            case .offer: buttons = card.canInstall ? "Later | Update" : "Later | Download page"
            case .installing: buttons = "no buttons"
            case .failed: buttons = "Close | Open download page"
            }
            return "\(card.title) — \(card.detail) [\(buttons)]"
        }
    }

    // MARK: State

    func simulatedSignalReport(now: Date) -> String? {
        guard let simulated else { return nil }
        return "Simulated signals (debug harness)\n" + ActivityDiagnostics.report(
            sample: simulated.sample(), audioDevices: [], cameraInUse: simulated.callSignals.contains(.camera),
            locked: false, displaysAsleep: false, screensaverRunning: false, sessionActive: true, at: now)
    }

    private func stateJSON() -> String {
        guard let c = coordinator else { return "{}" }
        let now = c.currentDate()
        let iso = { (date: Date?) -> Any in date.map { ISO8601.string(from: $0) } ?? NSNull() }
        var object: [String: Any] = [:]
        object["now"] = iso(now)
        object["clockOffset"] = c.clockOffset
        object["headless"] = options.headless
        object["simulated"] = options.simulate
        object["timers"] = ["screen": c.timers.screenTime.rounded(), "still": c.timers.stillTime.rounded()]
        object["cadence"] = ["eyes": c.settings.cadence.eyesEvery, "move": c.settings.cadence.moveEvery]
        object["nextBreakIn"] = c.nextBreakIn().rounded()
        object["presence"] = c.presence.status.isAway ? "away" : "present"
        object["paused"] = c.pause.primaryReason.map { Copy.pauseSentence($0, now: now) } ?? NSNull()
        object["cooldownUntil"] = iso(c.pause.cooldownUntil.flatMap { $0 > now ? $0 : nil })
        object["stretchHeldUntil"] = iso(c.stretchHeldUntil.flatMap { $0 > now ? $0 : nil })
        object["held"] = c.heldOpportunity.map { $0.kind.rawValue } ?? NSNull()
        object["whyNotNow"] = Copy.whyNotNow(c.whyNotNow(now: now), now: now)
        object["quiet"] = c.lastSample.presentingCause?.rawValue ?? NSNull()
        object["microphoneOnFor"] = c.microphoneGate.microphoneOnFor(at: now).rounded()
        object["socketProblem"] = c.socketProblem ?? NSNull()
        if let nudge = c.nudge {
            object["nudge"] = ["kind": nudge.kind.rawValue, "phase": nudge.phase.rawValue, "title": nudge.title,
                               "subtitle": nudge.subtitle, "whyNow": nudge.whyNow, "preview": nudge.isPreview,
                               "opportunity": nudge.offer.opportunity.kind.rawValue, "length": nudge.offer.length,
                               "rehearsal": nudge.isRehearsal, "hint": nudge.hint ?? NSNull()]
        } else {
            object["nudge"] = NSNull()
        }
        if let active = c.state.activeBreak, let completion = active.completion {
            object["completion"] = ["kind": active.kind.rawValue, "line": completion.line]
        } else {
            object["completion"] = NSNull()
        }
        // `break` is the break in progress; the closing moment after it is `completion`.
        if let active = c.state.activeBreak, active.completion == nil {
            var info: [String: Any] = [
                "kind": active.kind.rawValue, "title": active.title, "instruction": active.instruction,
                "elapsed": active.elapsed.rounded(), "planned": active.plannedLength, "extensions": active.extensionsUsed,
                "canExtend": active.canExtend, "needsYou": active.needsYou, "done": active.doneAvailable,
                "chip": active.agentChip.text, "preview": active.isPreview, "ambient": active.ambient,
                "rehearsal": active.isRehearsal,
                "hint": active.hint ?? NSNull(),
                "controls": OverlayControls.controls(for: active).map { "\($0)" },
            ]
            if OverlayControls.hasPrimary(active) { info["primary"] = OverlayControls.primaryTitle(active) }
            if let step = active.step { info["step"] = "\(step.index + 1)/\(step.count)" }
            if let detail = active.detail { info["detail"] = detail }
            if let routine = c.breakSession?.routine {
                info["routine"] = routine.id
                info["steps"] = routine.steps.map(\.title)
            }
            object["break"] = info
        } else {
            object["break"] = NSNull()
        }
        object["cards"] = c.cards.map { card -> [String: Any] in
            var info: [String: Any] = ["kind": Self.cardKind(card.content), "text": Self.cardText(card.content),
                                       "rehearsal": card.isRehearsal,
                                       "hint": Self.cardHint(card.content) ?? NSNull()]
            if case .resume(let resume) = card.content {
                // The supporting line and the rows, as the card shows them (debug builds only).
                info["detail"] = resume.detail?.plain ?? NSNull()
                info["folder"] = resume.items.count == 1 ? (resume.items[0].facts.folder ?? NSNull()) : NSNull()
                info["rows"] = resume.items.map { "\($0.facts.name) \($0.facts.shortStatus)" }
            }
            return info
        }
        if let decision = c.currentDecision {
            object["decision"] = ["sentence": decision.sentence, "undoable": decision.isUndoable(at: now)]
        } else {
            object["decision"] = NSNull()
        }
        let menuBar = c.state.menuBar
        object["menuBar"] = ["mark": menuBar.mark.rawValue, "badge": "\(menuBar.badge)", "text": (menuBar.text as Any?) ?? NSNull(),
                             "tooltip": menuBar.tooltip,
                             "cue": (menuBar.cue.map { ["cue": $0.cue.rawValue, "id": $0.id] as [String: Any] } as Any?) ?? NSNull()] as [String: Any]
        object["sessions"] = c.tracker.sessionsByUrgency.map {
            ["source": $0.source.rawValue, "id": $0.key.sessionID, "state": $0.state.rawValue,
             "folder": $0.projectName ?? NSNull(), "title": $0.title ?? NSNull(),
             "report": ["edits": $0.report.edits, "commands": $0.report.commands,
                        "message": $0.report.message ?? NSNull(), "failure": $0.report.failure ?? NSNull(),
                        "request": $0.report.request.map { "\($0.tool.rawValue) \($0.subject ?? "-")" } ?? NSNull()] as [String: Any],
            ] as [String: Any]
        }
        object["commands"] = c.tracker.commands.map { ["command": $0.command, "shell": $0.shellPID] }
        object["expectedRun"] = Dictionary(uniqueKeysWithValues: c.tracker.estimator.expectedRunLengths.map { ($0.key.rawValue, $0.value) })
        let entries = (try? c.historyStore.allEntries()) ?? []
        object["history"] = entries.map {
            ["kind": $0.kind.rawValue, "outcome": $0.outcome.rawValue, "opportunity": $0.opportunityKind?.rawValue ?? NSNull(),
             "source": $0.source?.rawValue ?? NSNull(), "duration": $0.duration.rounded(), "movement": $0.movementDetected] as [String: Any]
        }
        object["today"] = ["breaksTaken": c.state.today.breaksTaken,
                           "byKind": Dictionary(uniqueKeysWithValues: c.state.today.takenByKind.map { ($0.key.rawValue, $0.value) })]
        let totals = c.state.totals
        let line = TotalsCopy.exampleLine(totals)
        object["totals"] = ["movingSeconds": totals.movingSeconds.rounded(), "stretches": totals.stretches,
                            "walks": totals.walks, "eyeRests": totals.eyeRests,
                            "period": TotalsCopy.period(firstEntry: totals.firstEntry, now: now),
                            "moving": TotalsCopy.moving(totals.movingSeconds),
                            "line": line?.text ?? NSNull(), "lineIsNew": line?.isNew ?? false] as [String: Any]
        object["windDown"] = ["enabled": c.settings.windDownEnabled, "extensionsTonight": c.windDown.extensionsTonight,
                              "wrappedUp": c.windDown.wrappedUp, "snoozedUntil": iso(c.windDown.snoozedUntil)]
        object["sounds"] = recordingSound?.played.map(\.rawValue) ?? []
        if let headphones = recordingHeadphones {
            object["headphones"] = ["prepareOn": headphones.prepareOnCount, "promptsRequested": headphones.promptsRequested,
                                    "begins": headphones.begins, "ends": headphones.ends]
        }
        var integrations: [String: Any] = [:]
        for row in c.state.integrations {
            integrations[row.id.rawValue] = [
                "state": Self.describe(c.integrationStates[row.id] ?? .notInstalled),
                "status": "\(row.status)", "notes": row.notes, "error": row.errorMessage ?? NSNull(),
                "busy": row.isBusy, "checking": c.installChecks[row.id] != nil,
                "connectedAt": iso(row.connectedAt),
            ] as [String: Any]
        }
        object["integrations"] = integrations
        object["nativeCursorInstalled"] = c.tracker.nativeCursorInstalled
        object["hotkeys"] = c.shell.registeredHotKeys
        object["rotation"] = ["next": c.nextRoutineID, "last": c.rotation.lastRoutineID ?? NSNull(),
                              "stretchesStarted": c.rotation.stretchesStarted,
                              "copyLast": c.rotation.copyBags.compactMapValues(\.last)] as [String: Any]
        object["settings"] = ["hasCompletedOnboarding": c.settings.hasCompletedOnboarding,
                              "hasBand": c.settings.hasBand, "excludedRoutines": c.settings.excludedRoutines,
                              "pauseForMicrophone": c.settings.pauseForMicrophone,
                              "airpodsMovementCheck": c.settings.airpodsMovementCheck,
                              "checkForUpdates": c.settings.checkForUpdates,
                              "installUpdatesAutomatically": c.settings.installUpdatesAutomatically,
                              "tourStatus": c.settings.tourStatus.rawValue,
                              "showHints": c.settings.showHints,
                              "stepTick": c.settings.stepTick]
        object["popover"] = ["open": c.popoverOpen, "hint": c.popoverHint ?? NSNull(),
                             "closedBy": c.popoverClosedBy?.rawValue ?? NSNull()] as [String: Any]
        object["hints"] = ["show": c.settings.showHints, "known": c.settings.hintsSeen.map(\.rawValue),
                           "pending": HintPolicy.pending(c.settings).map(\.rawValue), "onScreen": c.hintOnScreen] as [String: Any]
        if let tour = c.state.tour {
            object["tour"] = ["step": tour.step.rawValue, "part": tour.popoverPart.rawValue,
                              "progress": tour.progressIndex.map { "\($0)/\(tour.progressCount)" } ?? NSNull(),
                              "title": tour.coach.title ?? NSNull(), "text": tour.coach.text,
                              "primary": tour.coach.primary ?? NSNull(), "agent": tour.agent] as [String: Any]
        } else {
            object["tour"] = NSNull()
        }
        let update = c.state.update
        let record = c.updateRecord
        object["update"] = updateJSON(update, record: record, iso: iso)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func updateJSON(_ update: UpdateState, record: UpdateRecord, iso: (Date?) -> Any) -> [String: Any] {
        var phase = ""
        var detail: Any = NSNull()
        switch update.phase {
        case .idle: phase = "idle"
        case .checking: phase = "checking"
        case .upToDate: phase = "upToDate"
        case .available: phase = "available"
        case .installing(_, let step):
            phase = "installing"
            detail = step.rawValue
        case .installFailed(_, let reason):
            phase = "installFailed"
            detail = reason
        case .failed: phase = "failed"
        }
        var object: [String: Any] = [
            "current": update.currentVersion, "phase": phase, "detail": detail,
            "available": update.release?.version ?? NSNull(),
            "canInstall": update.canInstall, "blocker": update.installBlocker ?? NSNull(),
            "latest": record.latest?.version ?? NSNull(), "notes": record.latest?.notes ?? NSNull(),
            "page": record.latest?.page.absoluteString ?? NSNull(),
            "lastCheckedAt": iso(record.lastCheckedAt), "lastAttemptAt": iso(record.lastAttemptAt),
            "lastAttemptFailed": record.lastAttemptFailed,
            "postponedVersion": record.postponedVersion ?? NSNull(), "postponedUntil": iso(record.postponedUntil),
            "installFailedVersion": record.installFailedVersion ?? NSNull(),
        ]
        object["fetches"] = fakeFeed?.fetches ?? 0
        object["downloads"] = fakeFeed?.downloads ?? 0
        return object
    }

    static func describe(_ state: IntegrationInstallState) -> String {
        switch state {
        case .notFound: return "notFound"
        case .notInstalled: return "notInstalled"
        case .installed: return "installed"
        case .unreadable: return "unreadable"
        case .outdated: return "outdated"
        case .modified: return "modified"
        }
    }
}

// MARK: - Recording surfaces (headless)

/// Stands in for every window controller. Logs each change of what would be on screen. When
/// `drivesTimers` (headless), it also does what the real controllers do on their own: a nudge
/// offer is ignored after 10 s, and a card is dismissed after its auto-hide time (no hover).
@MainActor
final class SurfaceRecorder: SurfaceController {
    let drivesTimers: Bool
    let trace: Bool
    private weak var state: AppState?
    private var actions = AppActions.noop
    private var transcript: [String] = []
    private var previous: [String: String] = [:]
    private var offerSince: (id: UUID, since: Date)?
    private var cardSince: [UUID: Date] = [:]
    private let started = Date()

    init(drivesTimers: Bool, trace: Bool) {
        self.drivesTimers = drivesTimers
        self.trace = trace
    }

    func attach(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    /// The chip without its running clock (so the log changes only when the chip does).
    static func chipLabel(_ chip: AgentChipState) -> String {
        switch chip {
        case .clock: return "time of day"
        case .working(let agent, _): return "\(agent) is still working"
        default: return chip.text
        }
    }

    private static let clockFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func note(_ line: String) {
        let clock = state.map { Self.clockFormat.string(from: $0.now) } ?? "--:--:--"
        let entry = String(format: "%7.2f ", Date().timeIntervalSince(started)) + "[\(clock)] " + line
        transcript.append(entry)
        if transcript.count > 5000 { transcript.removeFirst(1000) }
        if trace {
            print(entry)
            fflush(stdout)
        }
    }

    func lines(from index: Int) -> [String] {
        Array(transcript.dropFirst(max(0, index)))
    }

    func sync() {
        guard let state else { return }
        var now: [String: String] = [:]
        if let nudge = state.nudge {
            now["nudge"] = "nudge \(nudge.kind.rawValue) \(nudge.phase.rawValue)\(nudge.isRehearsal ? " rehearsal" : nudge.isPreview ? " preview" : ""): \"\(nudge.title)\" — \(nudge.subtitle)"
                + (nudge.hint.map { " hint \"\($0)\"" } ?? "")
        } else {
            now["nudge"] = "no nudge"
        }
        if let active = state.activeBreak, let completion = active.completion {
            now["break"] = "break \(active.kind.rawValue) completed: \"\(completion.line)\""
        } else if let active = state.activeBreak {
            var line = "break \(active.kind.rawValue)\(active.isRehearsal ? " rehearsal" : active.isPreview ? " preview" : ""): \"\(active.title)\" / \"\(active.instruction)\" chip \"\(Self.chipLabel(active.agentChip))\""
            if active.needsYou { line += " needs-you" }
            if let hint = active.hint { line += " hint \"\(hint)\"" }
            if active.doneAvailable { line += " done-available" }
            if active.extensionsUsed > 0 { line += " +\(active.extensionsUsed) min" }
            if OverlayControls.hasPrimary(active) { line += " primary \"\(OverlayControls.primaryTitle(active))\"" }
            if let step = active.step { line += " step \(step.index + 1)/\(step.count)" }
            if let detail = active.detail { line += " idea \"\(detail)\"" }
            now["break"] = line
        } else {
            now["break"] = "no break"
        }
        now["cards"] = state.cards.isEmpty ? "no cards"
            : "cards: " + state.cards.map { card in
                "\(DebugHarness.cardKind(card.content)) \"\(DebugHarness.cardText(card.content))\""
                    + (DebugHarness.cardHint(card.content).map { " hint \"\($0)\"" } ?? "")
            }.joined(separator: ", ")
        now["menu"] = "menu bar \(state.menuBar.mark.rawValue), badge \(state.menuBar.badge)"
        if let tour = state.tour {
            let part = tour.step == .popover ? " (\(tour.popoverPart))" : ""
            now["tour"] = "tour \(tour.step.rawValue)\(part): \"\(tour.coach.title ?? tour.coach.text)\""
        } else {
            now["tour"] = "no tour"
        }
        now["cue"] = state.menuBar.cue.map { "mark movement: \($0.cue.rawValue) (#\($0.id))" } ?? "no mark movement"
        now["popoverHint"] = state.popoverHint.map { "popover hint \"\($0)\"" } ?? "no popover hint"
        for key in ["menu", "cue", "tour", "nudge", "break", "cards", "popoverHint"] where previous[key] != now[key] {
            if previous[key] != nil || !(now[key]?.hasPrefix("no ") ?? true) { note(now[key] ?? "") }
        }
        previous = now
        guard drivesTimers else { return }
        driveTimers(state)
    }

    private func driveTimers(_ state: AppState) {
        let now = state.now
        // The tour's sample nudge waits for Start or Not now, as the real panel does.
        if let nudge = state.nudge, nudge.phase == .offer, !nudge.isRehearsal {
            if offerSince?.id != nudge.id { offerSince = (nudge.id, now) }
            if let since = offerSince?.since, now.timeIntervalSince(since) >= Timing.nudgeIgnoreAfter {
                offerSince = nil
                note("nudge timed out (ignored)")
                if nudge.isPreview { return }
                actions.ignoreNudge()
            }
        } else {
            offerSince = nil
        }
        let ids = Set(state.cards.map(\.id))
        cardSince = cardSince.filter { ids.contains($0.key) }
        for card in state.cards {
            // Like the real surface, a card that stayed until dismissed starts its time when it
            // can first hide itself (a resume card whose needs-you row went away).
            guard let limit = card.autoHideAfter else { cardSince[card.id] = nil; continue }
            let since = cardSince[card.id] ?? now
            cardSince[card.id] = since
            if now.timeIntervalSince(since) >= limit {
                cardSince[card.id] = nil
                note("card timed out: \(DebugHarness.cardKind(card.content))")
                actions.dismissCard(card.id)
            }
        }
    }

    func tearDown() {}
}

// MARK: - Simulated signals

/// The input, call and presence signals, set by `breakpoint debug input|call|presence`, measured
/// against the coordinator's (movable) clock.
@MainActor
final class SimulatedActivityMonitor: ActivityMonitoring {
    var onCallSignalsChange: ((CallSignals) -> Void)?
    var onPresenceEvent: ((PresenceEvent) -> Void)?
    private(set) var callSignals: CallSignals = []
    var now: () -> Date = { Date() }
    var lastKeyAt: Date
    var lastInputAt: Date
    var lastDragAt: Date
    var lastScrollAt: Date
    var buttonDown = false
    var displaySleepPrevented = false
    var displayMirrored = false

    init() {
        let start = Date()
        lastKeyAt = start.addingTimeInterval(-30)
        lastInputAt = start
        lastDragAt = start.addingTimeInterval(-30)
        lastScrollAt = start.addingTimeInterval(-30)
    }

    /// The coordinator asks the harness first (`simulatedSignalReport`); nothing more here.
    func diagnosticReport() -> String { "" }

    func sample() -> InputSample {
        let now = now()
        return InputSample(takenAt: now, secondsSinceKey: max(0, now.timeIntervalSince(lastKeyAt)),
                           secondsSinceAnyInput: max(0, now.timeIntervalSince(lastInputAt)),
                           secondsSinceDrag: max(0, now.timeIntervalSince(lastDragAt)),
                           mouseButtonDown: buttonDown, displaySleepPrevented: displaySleepPrevented,
                           secondsSinceScroll: max(0, now.timeIntervalSince(lastScrollAt)),
                           displayMirrored: displayMirrored)
    }

    func pressKey() {
        lastKeyAt = now()
        lastInputAt = lastKeyAt
    }

    func touchPointer() { lastInputAt = now() }

    func drag() {
        lastDragAt = now()
        lastInputAt = lastDragAt
    }

    func scroll() {
        lastScrollAt = now()
        lastInputAt = lastScrollAt
    }

    func shift(by delta: TimeInterval) {
        lastKeyAt = lastKeyAt.addingTimeInterval(delta)
        lastInputAt = lastInputAt.addingTimeInterval(delta)
        lastDragAt = lastDragAt.addingTimeInterval(delta)
        lastScrollAt = lastScrollAt.addingTimeInterval(delta)
    }

    func setCallSignals(_ signals: CallSignals) {
        guard signals != callSignals else { return }
        callSignals = signals
        onCallSignalsChange?(signals)
    }

    func post(_ event: PresenceEvent) { onPresenceEvent?(event) }

    func start() {}
    func stop() {}
}

/// The AirPods check without CoreMotion: counts what the real monitor would do, including when it
/// would show the Motion prompt (the setting switched from off to on while the app runs).
@MainActor
final class RecordingHeadphones: HeadphoneMotionMonitoring {
    var isAvailable = true
    var movement = true
    private(set) var prepareOnCount = 0
    private(set) var promptsRequested = 0
    private(set) var begins = 0
    private(set) var ends = 0
    private var lastEnabled: Bool?

    func prepare(enabled: Bool) {
        if enabled { prepareOnCount += 1 }
        if enabled, lastEnabled == false { promptsRequested += 1 }
        lastEnabled = enabled
    }

    func begin() { begins += 1 }

    func end() -> Bool {
        ends += 1
        return movement
    }
}

/// The release feed without the network: reads a local file, or fails, synchronously (so a check
/// started during `debug advance` finishes within the same step).
@MainActor
final class FakeUpdateFetcher: UpdateFetching {
    enum Source {
        case none
        case failure
        case file(URL)
    }

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    var source: Source = .none
    private(set) var fetches = 0
    private(set) var downloads = 0

    /// The archive: the file of the same name next to the feed file.
    func download(_ url: URL, into folder: URL, _ completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        downloads += 1
        guard case .file(let feed) = source else {
            completion(.failure(Unavailable(description: "no archive in the debug harness")))
            return
        }
        let source = feed.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            completion(.success(destination))
        } catch {
            completion(.failure(error))
        }
    }

    func fetch(_ completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        fetches += 1
        switch source {
        case .none: completion(.failure(Unavailable(description: "no feed in the debug harness")))
        case .failure: completion(.failure(Unavailable(description: "simulated failure")))
        case .file(let url):
            do {
                completion(.success(try Data(contentsOf: url)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

/// Records the cues instead of playing them.
@MainActor
final class RecordingSound: SoundPlaying {
    private(set) var played: [SoundID] = []
    var onPlay: ((SoundID) -> Void)?

    func play(_ sound: SoundID, volume: Double) {
        played.append(sound)
        onPlay?(sound)
    }
}
/// The platform's real windows plus the recorder, which then only traces (`--debug-trace` with
/// windows shown; the real controllers own the timers).
@MainActor
final class TracingShell: PlatformShell {
    let base: PlatformShell
    let recorder: SurfaceRecorder

    init(_ base: PlatformShell, recorder: SurfaceRecorder) {
        self.base = base
        self.recorder = recorder
    }

    var surfaces: [SurfaceController] { base.surfaces + [recorder] }
    var hasStatusItem: Bool { base.hasStatusItem }
    func installStatusItem() { base.installStatusItem() }
    func showPopover() { base.showPopover() }
    func closePopover() { base.closePopover() }
    func statusItemDiagnostics() -> String? { base.statusItemDiagnostics() }
    func showSettings() { base.showSettings() }
    func closeSettings() { base.closeSettings() }
    func showOnboarding() { base.showOnboarding() }
    var isOnboardingVisible: Bool { base.isOnboardingVisible }
    func relayoutPopups() { base.relayoutPopups() }
    func dismissAllPopups() { base.dismissAllPopups() }
    var onPopupEvicted: ((UUID) -> Void)? {
        get { base.onPopupEvicted }
        set { base.onPopupEvicted = newValue }
    }
    func stop() { base.stop() }
    var registeredHotKeys: Int { base.registeredHotKeys }
}
#endif
