import AppKit
import BreakpointCore
import BreakpointKit

// Updates (SPEC §2.11): at most once a day, at a quiet moment, one GET of the release feed; a calm
// prompt when a newer version exists; Update downloads the archive, checks its Ed25519 signature
// against the key compiled into this copy, swaps the app in place and reopens it, and the new copy
// confirms it started (or the old one comes back). Decisions are `UpdatePolicy`'s, file work is
// `UpdateInstaller` / `UpdateRelauncher`'s; this file sequences them.

extension AppCoordinator {
    /// What the app is doing now, for `UpdatePolicy`.
    func updateMoment() -> UpdateMoment {
        UpdateMoment(onboarded: settings.hasCompletedOnboarding, breakActive: breakSession != nil,
                     nudgeVisible: nudge != nil, cardsVisible: !cards.isEmpty, paused: pause.isPaused,
                     callActive: !monitor.callSignals.isEmpty, away: presence.status.isAway,
                     secondsSinceKey: lastSample.secondsSinceKey)
    }

    /// The app bundle an install replaces (the harness can point it at a stand-in).
    var updateInstallLocation: URL { updateLocationOverride ?? Bundle.main.bundleURL }

    /// The release key this copy trusts (the harness can use a throwaway test key).
    var updatePublicKey: String? { updateKeyOverride ?? UpdateKey.publicKeyBase64 }

    /// Why Update cannot install in place here, in one sentence; `nil` when it can.
    func updateInstallBlocker() -> String? {
        guard UpdateSignature.publicKey(updatePublicKey) != nil else {
            return UpdateCopy.noKey
        }
        return UpdateLocation.blocker(for: updateInstallLocation)?.explanation
    }

    var canInstallUpdates: Bool { updateInstallBlocker() == nil }

    /// Every tick: start a due automatic check; then install or offer at a quiet moment.
    func considerUpdates(now: Date) {
        guard updateInstallStep == nil else { return }
        let moment = updateMoment()
        if !updateChecking, UpdatePolicy.mayCheck(moment),
           UpdatePolicy.checkIsDue(updateRecord, automatic: settings.checkForUpdates, launchedAt: launchedAt, now: now) {
            checkForUpdates(automatic: true)
            return
        }
        // Only automatic checks lead to the prompt or an automatic install; with them off, About
        // still shows what is known.
        guard settings.checkForUpdates, !updateChecking else { return }
        if UpdatePolicy.shouldInstallAutomatically(updateRecord, current: .current, system: .operatingSystem,
                                                   automatic: settings.installUpdatesAutomatically,
                                                   canInstall: canInstallUpdates, moment: moment, now: now) {
            installUpdate(automatic: true)
            return
        }
        guard UpdatePolicy.shouldPrompt(updateRecord, current: .current, system: .operatingSystem, moment: moment, now: now),
              let release = UpdatePolicy.available(updateRecord, current: .current, system: .operatingSystem) else { return }
        let canInstall = canInstallUpdates && release.isInstallable && updateRecord.installFailedVersion != release.version
        cards.append(CardState(content: .update(UpdateCardContent(release: release, canInstall: canInstall)), createdAt: now))
    }

    // MARK: - Checking

    /// One GET of the feed. Automatic checks come from `considerUpdates`; Check now (About) runs
    /// whatever the moment and never shows the prompt (the answer is in the pane).
    func checkForUpdates(automatic: Bool) {
        guard !updateChecking, updateInstallStep == nil else { return }
        updateChecking = true
        recordSurface("update check (\(automatic ? "automatic" : "Check now"))")
        publish()
        updateFetcher.fetch { [weak self] result in
            guard let self else { return }
            let now = self.currentDate()
            self.updateChecking = false
            switch result {
            case .success(let data):
                do {
                    let release = try UpdateFeed.parse(data)
                    self.updateRecord = UpdatePolicy.checked(self.updateRecord, release: release, now: now)
                    self.recordSurface("update check: the feed names \(release.version)\(release.isInstallable ? ", signed" : "")")
                } catch {
                    self.updateRecord = UpdatePolicy.failed(self.updateRecord, now: now)
                    self.recordSurface("update check: the feed was not usable (\(error))")
                }
            case .failure(let error):
                self.updateRecord = UpdatePolicy.failed(self.updateRecord, now: now)
                self.recordSurface("update check failed: \(error)")
                log.info("Update check failed: \(String(describing: error), privacy: .public)")
            }
            self.saveUpdateRecord()
            self.publish(now: now)
        }
    }

    // MARK: - Installing

    /// Update: download → verify (before unpacking) → unpack and check the bundle → swap → reopen.
    /// Anything that goes wrong leaves this copy as it was and offers the download page.
    func installUpdate(automatic: Bool) {
        guard updateInstallStep == nil,
              let release = UpdatePolicy.available(updateRecord, current: .current, system: .operatingSystem) else { return }
        guard canInstallUpdates, release.isInstallable, let archiveURL = release.archive else {
            openUpdate()
            return
        }
        guard breakSession == nil else {
            failInstall(.breakInProgress, release: release)
            return
        }
        recordSurface("update install \(release.version) (\(automatic ? "automatic" : "Update"))")
        updateInstallIsAutomatic = automatic
        setInstallStep(.downloading, release: release)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("breakpoint-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        updateFetcher.download(archiveURL, into: folder) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                try? FileManager.default.removeItem(at: folder)
                self.failInstall(.download("\(error)"), release: release)
            case .success(let archive):
                self.setInstallStep(.verifying, release: release)
                self.stageUpdate(archive: archive, folder: folder, release: release)
            }
        }
    }

    /// Verifies and unpacks off the main thread (synchronously in the harness), then swaps.
    private func stageUpdate(archive: URL, folder: URL, release: UpdateRelease) {
        let installer = UpdateInstaller(installedApp: updateInstallLocation, publicKeyBase64: updatePublicKey)
        let work = {
            let result = Result { try installer.stage(archive: archive, release: release) }
            try? FileManager.default.removeItem(at: folder)
            return result
        }
        let finish: (Result<StagedUpdate, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.failInstall(error as? UpdateInstallError ?? .unpackFailed("\(error)"), release: release)
            case .success(let staged):
                self.swapAndReopen(staged, installer: installer, release: release)
            }
        }
        if updateWorkIsSynchronous {
            finish(work())
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                DispatchQueue.main.async { MainActor.assumeIsolated { finish(result) } }
            }
        }
    }

    private func swapAndReopen(_ staged: StagedUpdate, installer: UpdateInstaller, release: UpdateRelease) {
        // Never replace the app under a break that started while the download ran.
        guard breakSession == nil else {
            try? FileManager.default.removeItem(at: staged.stagingDirectory)
            failInstall(.breakInProgress, release: release)
            return
        }
        setInstallStep(.installing, release: release)
        let swapped: SwappedUpdate
        do {
            swapped = try installer.swap(staged)
        } catch {
            try? FileManager.default.removeItem(at: staged.stagingDirectory)
            failInstall(error as? UpdateInstallError ?? .swapFailed("\(error)"), release: release)
            return
        }
        let pending = PendingUpdate(fromVersion: BreakpointVersion.current, toVersion: release.version, swapped: swapped,
                                    startedAt: currentDate())
        do {
            try PendingUpdate.file(paths).write(pending)
        } catch {
            try? UpdateInstaller.rollback(swapped)
            failInstall(.swapFailed("could not write pending-update.json"), release: release)
            return
        }
        updateRecord = UpdatePolicy.postponed(updateRecord, version: release.version, now: currentDate())
        saveUpdateRecord()
        setInstallStep(.reopening, release: release)
        reopenAfterUpdate(swapped)
    }

    /// Hands over to `breakpoint update-relaunch`, run from the old copy (now the backup), and quits.
    private func reopenAfterUpdate(_ swapped: SwappedUpdate) {
        let helper = swapped.backup.appendingPathComponent("Contents/Helpers/breakpoint")
        let pid = ProcessInfo.processInfo.processIdentifier
        if isHeadless {
            recordSurface("reopen: \(helper.path) update-relaunch --pid \(pid), then quit (not in the harness)")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            try? UpdateInstaller.rollback(swapped)
            try? FileManager.default.removeItem(at: paths.pendingUpdateFile)
            failInstall(.swapFailed("no relaunch helper"), release: updateState().release)
            return
        }
        // Detached, so it outlives this process; it inherits BREAKPOINT_HOME.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup \"$0\" update-relaunch --pid \"$1\" >/dev/null 2>&1 &", helper.path, "\(pid)"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? UpdateInstaller.rollback(swapped)
            try? FileManager.default.removeItem(at: paths.pendingUpdateFile)
            failInstall(.swapFailed("\(error)"), release: updateState().release)
            return
        }
        log.info("Update installed; reopening")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    private func setInstallStep(_ step: UpdateInstallStep, release: UpdateRelease) {
        updateInstallStep = step
        updateInstallFailure = nil
        recordSurface("update: \(step.text)")
        setUpdateCard(.installing(step), release: release)
        publish()
    }

    private func failInstall(_ error: UpdateInstallError, release: UpdateRelease?) {
        let wasAutomatic = updateInstallIsAutomatic
        updateInstallStep = nil
        recordSurface("update install stopped: \(error)")
        log.error("Update install stopped: \(String(describing: error), privacy: .public)")
        if let release {
            switch error {
            case .breakInProgress, .download, .blocked:
                break // worth trying again: About keeps offering Update; the card says why it stopped
            default:
                updateRecord = UpdatePolicy.installFailed(updateRecord, version: release.version)
                updateInstallFailure = error.explanation
            }
            // An automatic install that stopped waits three days, like Later, so it never retries in a loop.
            if wasAutomatic { updateRecord = UpdatePolicy.postponed(updateRecord, version: release.version, now: currentDate()) }
            saveUpdateRecord()
            setUpdateCard(.failed(error.explanation), release: release)
        }
        publish()
    }

    private func setUpdateCard(_ stage: UpdateCardContent.Stage, release: UpdateRelease) {
        cards = cards.map { card in
            guard case .update(var content) = card.content else { return card }
            content.stage = stage
            var updated = card
            updated.content = .update(content)
            return updated
        }
    }

    /// Open download page: the release page in the browser (only ever a page inside the
    /// repository); puts the question off, as Later does.
    func openUpdate() {
        guard let release = UpdatePolicy.available(updateRecord, current: .current, system: .operatingSystem),
              UpdateFeed.isTrusted(release.page) else { return }
        if isHeadless {
            recordSurface("opened \(release.page.absoluteString)")
        } else {
            NSWorkspace.shared.open(release.page)
        }
        postponeUpdate(release.version)
        cards.removeAll { if case .update = $0.content { return true } else { return false } }
        publish()
    }

    func postponeUpdate(_ version: String) {
        updateRecord = UpdatePolicy.postponed(updateRecord, version: version, now: currentDate())
        saveUpdateRecord()
    }

    func saveUpdateRecord() {
        do {
            try UpdateRecord.file(paths).write(updateRecord)
        } catch {
            log.error("Could not save updates.json: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - After an update (the new copy, or the old one put back)

    /// Early in `start()`: the new copy notes its process so the helper can stop it if it hangs.
    func notePendingUpdateLaunch() {
        let file = PendingUpdate.file(paths)
        guard var pending = (try? file.read()) ?? nil, pending.toVersion == BreakpointVersion.current,
              pending.confirmedAt == nil, pending.failedAt == nil else { return }
        pending.newPID = ProcessInfo.processInfo.processIdentifier
        try? file.write(pending)
    }

    /// At the end of `start()`: confirm a finished update (and say so), or report one that was
    /// put back; clear leftovers of an interrupted one.
    func settlePendingUpdate() {
        let file = PendingUpdate.file(paths)
        let now = currentDate()
        guard var pending = (try? file.read()) ?? nil else {
            if UpdateLocation.blocker(for: updateInstallLocation) == nil {
                UpdateInstaller.cleanUpLeftovers(nextTo: updateInstallLocation)
            }
            return
        }
        if pending.toVersion == BreakpointVersion.current, pending.confirmedAt == nil, pending.failedAt == nil {
            pending.confirmedAt = now
            try? file.write(pending)
            updateRecord.installFailedVersion = nil
            updateRecord.postponedVersion = nil
            updateRecord.postponedUntil = nil
            saveUpdateRecord()
            cards.append(CardState(content: .toast(ToastContent(text: UpdateCopy.updated(to: pending.toVersion))), createdAt: now))
            recordSurface("updated from \(pending.fromVersion) to \(pending.toVersion)")
            // A new ad hoc build is a new app to macOS: register the login item again if it was on.
            if settings.launchAtLogin, settings.hasCompletedOnboarding {
                do {
                    try loginItem.setEnabled(true)
                } catch {
                    log.error("Could not register the login item after the update: \(String(describing: error), privacy: .public)")
                }
            }
        } else if pending.failedAt != nil, pending.fromVersion == BreakpointVersion.current {
            updateRecord = UpdatePolicy.installFailed(updateRecord, version: pending.toVersion)
            saveUpdateRecord()
            updateInstallFailure = UpdateInstallError.didNotStart.explanation
            cards.append(CardState(content: .toast(ToastContent(
                text: UpdateCopy.rolledBack(to: pending.fromVersion, from: pending.toVersion))), createdAt: now))
            recordSurface("the update to \(pending.toVersion) did not start; back on \(pending.fromVersion)")
            try? FileManager.default.removeItem(at: file.url)
        } else if now.timeIntervalSince(pending.startedAt) > 10 * 60 {
            // An update that never finished either way, long ago.
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    // MARK: - State for About

    func updateState() -> UpdateState {
        let phase: UpdatePhase
        let available = UpdatePolicy.available(updateRecord, current: .current, system: .operatingSystem)
        if updateChecking {
            phase = .checking
        } else if let available, let step = updateInstallStep {
            phase = .installing(available, step)
        } else if let available, updateRecord.installFailedVersion == available.version {
            phase = .installFailed(available, updateInstallFailure ?? UpdateInstallError.didNotStart.explanation)
        } else if let available {
            phase = .available(available)
        } else if updateRecord.lastAttemptFailed, updateRecord.lastAttemptAt != nil {
            phase = .failed
        } else if updateRecord.lastCheckedAt != nil {
            phase = .upToDate
        } else {
            phase = .idle
        }
        return UpdateState(phase: phase, lastCheckedAt: updateRecord.lastCheckedAt, installBlocker: updateInstallBlocker())
    }
}
