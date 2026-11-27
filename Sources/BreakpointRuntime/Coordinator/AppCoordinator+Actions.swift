import Foundation
import BreakpointCore

// `AppActions` implementations (SPEC §7.2).

extension AppCoordinator {
    func makeActions() -> AppActions {
        AppActions(
            acceptNudge: { [weak self] in self?.acceptNudge() },
            declineNudge: { [weak self] in
                guard let self else { return }
                if self.nudge?.isRehearsal == true { return self.handleTour(.decline) }
                self.endNudge(.declined, now: self.currentDate())
                self.publish()
            },
            startBreak: { [weak self] kind in
                guard let self else { return }
                let now = self.currentDate()
                // A real break the user asked for ends the rehearsal first (SPEC §3.12).
                self.interruptTour(.realBreak, now: now)
                self.startBreak(kind, opportunity: Opportunity(kind: .manual, createdAt: now), length: nil,
                                isPreview: false, now: now)
            },
            skipBreak: { [weak self] in self?.skipBreak() },
            finishBreak: { [weak self] reason in
                guard let self else { return }
                // During the closing moment, Done / Return / Esc end it at once.
                guard self.breakSession != nil else { self.endCompletionNow(); return }
                self.endBreak(.finish(reason), now: self.currentDate())
            },
            extendBreak: { [weak self] in
                guard let self, let session = self.breakSession else { return }
                self.breakSession = BreakSessionRules.extended(session)
                self.publish()
            },
            stepRoutine: { [weak self] delta in
                guard let self, let session = self.breakSession else { return }
                self.breakSession = BreakSessionRules.stepped(session, by: delta, now: self.currentDate())
                self.publish()
            },
            undoLastDecision: { [weak self] in self?.undoLastDecision() },
            pause: { [weak self] duration in
                guard let self else { return }
                let now = self.currentDate()
                self.pause = PausePolicy.pause(self.pause, for: duration, now: now, calendar: self.calendar)
                self.withdrawNudge(now: now)
                self.publish(now: now)
            },
            resume: { [weak self] in
                guard let self else { return }
                self.pause = PausePolicy.resumeNow(self.pause, now: self.currentDate())
                self.publish()
            },
            dismissCard: { [weak self] id in
                guard let self else { return }
                if self.cards.first(where: { $0.id == id })?.isRehearsal == true {
                    // The tour's sample resume card, clicked away: the tour moves on.
                    self.cards.removeAll { $0.id == id }
                    return self.handleTour(.cardDismissed)
                }
                // Later, × or the prompt hiding itself: ask again about that version in three days.
                if let card = self.cards.first(where: { $0.id == id }), case .update(let content) = card.content {
                    if case .installing = content.stage { return } // it closes when Breakpoint reopens
                    self.postponeUpdate(content.release.version)
                    self.updateInstallFailure = nil
                }
                self.cards.removeAll { $0.id == id }
                self.publish()
            },
            windDownExtend: { [weak self] in
                guard let self else { return }
                self.windDown = WindDownPolicy.extend(self.windDown, now: self.currentDate())
                self.cards.removeAll { if case .windDown = $0.content { return true } else { return false } }
                self.publish()
            },
            windDownWrapUp: { [weak self] in self?.windDownWrapUp() },
            copyWrapUpNote: { [weak self] in
                guard let self else { return }
                let lines = WindDownPolicy.wrapUpNote(sessions: self.tracker.sessionsByUrgency)
                self.platform.copyText(lines.joined(separator: "\n"))
            },
            install: { [weak self] id in self?.runIntegration(id, install: true) },
            uninstall: { [weak self] id in self?.runIntegration(id, install: false) },
            updateSettings: { [weak self] mutate in self?.updateSettings(mutate) },
            previewNudge: { [weak self] kind in
                guard let self, self.tour == nil else { return }
                self.previewNudge(kind)
            },
            previewBreak: { [weak self] kind in
                guard let self, self.tour == nil else { return }
                self.startBreak(kind, opportunity: nil, length: nil, isPreview: true, now: self.currentDate())
            },
            openSettings: { [weak self] in
                guard let self else { return }
                // The Integrations pane shows install states; re-read them in case a tool was
                // connected with `breakpoint install` while the app ran.
                self.refreshIntegrations()
                self.shell.showSettings()
                self.recordSurface("settings shown")
            },
            quit: { [weak self] in self?.platform.quit() },
            ignoreNudge: { [weak self] in
                // The tour's sample nudge waits for Start or Not now.
                guard let self, self.nudge?.isRehearsal != true else { return }
                self.endNudge(.ignored, now: self.currentDate())
                self.publish()
            },
            cancelAutoStart: { [weak self] in
                guard let self else { return }
                self.cancelAutoStart(now: self.currentDate())
            },
            exportHistory: { [weak self] in self?.exportHistory() },
            deleteAllData: { [weak self] in self?.deleteAllData() },
            previewSound: { [weak self] sound in
                guard let self, self.monitor.callSignals.isEmpty else { return }
                self.sound.play(sound, volume: self.settings.volume)
            },
            completeOnboarding: { [weak self] in self?.completeOnboarding() },
            checkForUpdates: { [weak self] in self?.checkForUpdates(automatic: false) },
            openUpdate: { [weak self] in self?.openUpdate() },
            installUpdate: { [weak self] in self?.installUpdate(automatic: false) },
            replayTour: { [weak self] in self?.replayTour() },
            tour: { [weak self] input in self?.handleTour(input) },
            popoverVisibilityChanged: { [weak self] open in self?.popoverVisibilityChanged(open) },
            popoverMayClose: { [weak self] cause, pointerOnPopover in
                self?.popoverMayClose(cause, pointerOnPopover: pointerOnPopover)
            })
    }

    // MARK: - Breaks

    private func acceptNudge() {
        guard let current = nudge else { return }
        if current.isRehearsal { return handleTour(.accept) }
        let now = self.currentDate()
        if current.isPreview {
            endNudge(nil, now: now)
            publish(now: now)
            return
        }
        startBreak(current.offer.kind, opportunity: current.offer.opportunity, length: current.offer.length,
                   isPreview: false, now: now)
    }

    private func skipBreak() {
        guard let session = breakSession else { return }
        let now = self.currentDate()
        if session.isPreview {
            endBreak(nil, now: now)
            return
        }
        // Keys and clicks on Skip during the guard do nothing (§3.3).
        guard BreakSessionRules.isSkipEnabled(session, now: now) else { return }
        endBreak(.skip, now: now)
    }

    private func previewNudge(_ kind: BreakKind) {
        let now = self.currentDate()
        guard breakSession == nil else { return }
        endNudge(nil, now: now)
        let opportunity = Opportunity(kind: .typingPause, createdAt: now)
        let length = kind == .walk ? BreakKind.walk.defaultLength : kind.defaultLength
        let offer = BreakOffer(kind: kind, length: length, opportunity: opportunity,
                               timerValue: timers.value(for: kind))
        showNudge(offer, isPreview: true, now: now)
        let id = nudge?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.previewLength) { [weak self] in
            guard let self, self.nudge?.id == id else { return }
            self.endNudge(nil, now: self.currentDate())
            self.publish()
        }
    }

    // MARK: - Decisions and wind-down

    private func undoLastDecision() {
        let now = self.currentDate()
        guard let decision = currentDecision, decision.isUndoable(at: now) else { return }
        timers = AwayPolicy.undo(decision, current: timers)
        do {
            try historyStore.delete(ids: Set(decision.historyEntryIDs))
        } catch {
            log.error("Could not delete credited entries: \(String(describing: error), privacy: .public)")
        }
        refreshToday()
        refreshTotals()
        currentDecision = nil
        cards.removeAll { if case .awayNote = $0.content { return true } else { return false } }
        cards.append(CardState(content: .toast(ToastContent(text: Copy.timersRestored)), createdAt: now))
        publish(now: now)
    }

    private func windDownWrapUp() {
        let now = self.currentDate()
        windDown = WindDownPolicy.wrapUp(windDown, now: now)
        pause = PausePolicy.wrapUp(pause, now: now, calendar: calendar)
        withdrawNudge(now: now)
        let lines = WindDownPolicy.wrapUpNote(sessions: tracker.sessionsByUrgency)
        cards = cards.map { card in
            guard case .windDown(var content) = card.content else { return card }
            content.phase = .note(lines: lines)
            var updated = card
            updated.content = .windDown(content)
            return updated
        }
        publish(now: now)
    }

    // MARK: - Settings

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        var updated = settings
        mutate(&updated)
        updated = updated.normalized()
        guard updated != settings else { return }
        let change = SettingsChange(previous: settings, current: updated)
        settings = updated
        saveSettings()
        // Every change takes effect now, not at the next tick.
        if change.changed(\.storePromptSnippets) { tracker.storePromptSnippets = updated.storePromptSnippets }
        if change.changed(\.launchAtLogin), updated.hasCompletedOnboarding {
            try? loginItem.setEnabled(updated.launchAtLogin)
        }
        if change.changed(\.codexHome) { refreshIntegrations() }
        if change.changed(\.popupPosition) { shell.relayoutPopups() }
        let now = currentDate()
        if change.presenceRulesChanged {
            // "Pause during calls" switched off ends a call pause at once (and on starts one).
            updatePause(callSignals: monitor.callSignals, now: now)
        }
        if change.changed(\.strictAgentOnly), updated.strictAgentOnly, heldOpportunity?.kind == .typingPause {
            heldOpportunity = nil
        }
        if change.changed(\.airpodsMovementCheck) {
            // Turning the check on is the only moment the Motion prompt may appear (§2.9).
            headphones.prepare(enabled: updated.airpodsMovementCheck)
        }
        if var current = nudge, change.changed(\.nudgeHotkeys) {
            current.hotkeysEnabled = updated.nudgeHotkeys
            nudge = current
        }
        publish(now: now)
    }

    private func completeOnboarding() {
        let offerTour = TourPolicy.offersAfterOnboarding(settings.tourStatus)
        updateSettings { $0.hasCompletedOnboarding = true }
        if settings.launchAtLogin {
            do {
                try loginItem.setEnabled(true)
            } catch {
                log.error("Could not register the login item: \(String(describing: error), privacy: .public)")
            }
        }
        // The one-minute tour is offered under the mark; declining it opens the popover once,
        // as finishing onboarding did before the tour existed (SPEC §3.10, §3.12).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if offerTour, self.tour == nil { self.startTour(.onboarding) } else { self.showPopover() }
        }
    }

    // MARK: - Integrations

    private func runIntegration(_ id: IntegrationID, install: Bool) {
        guard !integrationBusy.contains(id) else { return }
        integrationBusy.insert(id)
        integrationErrors[id] = nil
        publish()
        let environment = integrationEnvironment
        let bundled = bundledCLI
        let paths = self.paths
        let finish: @MainActor ([String], String?) -> Void = { [weak self] notes, failure in
            guard let self else { return }
            self.integrationNotes[id] = notes
            self.integrationErrors[id] = failure
            self.installCheckProblems[id] = nil
            self.integrationConnectedAt[id] = nil
            if install, failure == nil {
                // Still busy: the row turns to Connected once the check passes.
                self.startInstallCheck(id)
            } else {
                self.installChecks[id] = nil
                self.integrationBusy.remove(id)
            }
            self.refreshIntegrations()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var notes: [String] = []
            var failure: String?
            do {
                if install, let bundled {
                    let cli = CLIInstaller(paths: paths, bundledCLI: bundled)
                    if !cli.isInstalled || cli.needsRefresh() { try cli.install() }
                }
                let integration = IntegrationRegistry.integration(id, environment: environment)
                notes = (install ? try integration.install() : try integration.uninstall()).notes
            } catch let error as IntegrationError {
                failure = error.explanation
            } catch {
                failure = error.localizedDescription
            }
            let written = notes, problem = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finish(written, problem) }
            }
        }
    }

    /// Verifies an install without waiting for the tool (§5.6): runs the hook command, with kind
    /// `test`, the way the tool would. Its event arriving passes the check (`passInstallCheck`);
    /// after `Timing.installCheckTimeout` the row says what is wrong instead.
    private func startInstallCheck(_ id: IntegrationID) {
        let token = UUID()
        installChecks[id] = token
        var environment = ProcessInfo.processInfo.environment
        #if DEBUG
        environment.merge(debugInstallCheckEnvironment) { $1 }
        #endif
        let process = InstallCheck.hookProcess(for: id, paths: paths, environment: environment)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                log.error("Could not run the install check: \(String(describing: error), privacy: .public)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.installCheckTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.failInstallCheck(id, token: token) }
        }
    }

    /// The check's `test` event arrived: the install is verified.
    func passInstallCheck(_ id: IntegrationID) {
        guard installChecks.removeValue(forKey: id) != nil else { return }
        integrationBusy.remove(id)
        installCheckProblems[id] = nil
        integrationConnectedAt[id] = Date()
    }

    /// No `test` event in time: find out whether the CLI copy runs at all, and say so on the row.
    private func failInstallCheck(_ id: IntegrationID, token: UUID) {
        guard installChecks[id] == token else { return }
        installChecks[id] = nil
        let environment = integrationEnvironment
        let report: @MainActor (String) -> Void = { [weak self] problem in
            guard let self, self.installChecks[id] == nil else { return }
            log.error("Install check failed for \(id.rawValue, privacy: .public): \(problem, privacy: .public)")
            self.integrationBusy.remove(id)
            self.installCheckProblems[id] = problem
            self.publish()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = InstallCheck.unreachableProblem(cliRuns: InstallCheck.cliRuns(paths: environment.paths),
                                                          environment: environment)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { report(problem) }
            }
        }
    }

    // MARK: - Privacy

    private func exportHistory() {
        let store = historyStore
        platform.exportHistory(suggestedName: "Breakpoint history.json") { url in try store.export(to: url) }
    }

    private func deleteAllData() {
        let confirmed = platform.confirm(
            title: "Delete all Breakpoint data?",
            message: "This removes your break history, the agent run-length estimates and the routine rotation from this \(BreakpointPlatform.computerName). Settings and installed integrations stay, along with the record and the backups of your tools’ config files that Breakpoint keeps so Remove can restore them exactly. This cannot be undone.",
            confirm: "Delete")
        guard confirmed else { return }
        do {
            try deleteAllDataNow()
        } catch {
            platform.alert(title: "Breakpoint couldn’t delete its data", message: error.localizedDescription)
        }
    }

    /// Deletes history, the run-length estimates and the rotation. Keeps settings and the integrations ledger
    /// (`integrations.json`), which uninstall needs to put the tools' files back exactly as they
    /// were (an empty file stays empty, folders Breakpoint created are removed).
    func deleteAllDataNow() throws {
        try historyStore.deleteAll()
        try? FileManager.default.removeItem(at: paths.sessionsFile)
        tracker.estimator = RunLengthEstimator()
        try? FileManager.default.removeItem(at: paths.rotationFile)
        rotation = .empty
        currentDecision = nil
        refreshToday()
        totals = .empty
        publish()
    }
}
