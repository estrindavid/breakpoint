import BreakpointCore
import BreakpointRuntime
import Foundation

// Every settings pane in light and dark, as the macOS SettingsSnapshots draws them
// (Sources/BreakpointSnapshots/SettingsSnapshots.swift): the whole window at its default size and
// scrolled part-way down, each pane's full length, the Integrations pane with tools in every
// status, the update states, the options sheets, the shortcut recorder and the focus ring.

extension SnapshotCatalogue {
    /// The settings window in every state, into `directory`/settings.
    static func settingsSnapshots(_ directory: URL) throws -> Int {
        let folder = directory.appendingPathComponent("settings")
        var count = 0
        let looks: [(String, Look)] = [("light", .light), ("dark", .dark)]
        for (suffix, look) in looks {
            func url(_ name: String) -> URL { folder.appendingPathComponent("\(name)-\(suffix).png") }
            for pane in SettingsPane.allCases {
                try SettingsSnapshotPages.window(url("window-\(pane.rawValue)"), pane: pane, look: look)
                try SettingsSnapshotPages.window(url("window-\(pane.rawValue)-scrolled"), pane: pane, look: look, scroll: 240)
                try SettingsSnapshotPages.pane(url("\(pane.rawValue)-full"), pane: pane, look: look)
                count += 3
            }
            let states = SettingsSnapshotStates.self
            let pages: [(String, SettingsPane, AppState)] = [
                ("integrations-every-status", .integrations, states.everyIntegrationStatus()),
                ("integrations-install-check-failed", .integrations, states.installCheckFailed()),
                ("integrations-first-run", .integrations, AppState.preview(.firstRun)),
                ("breaks-custom-pace", .breaks, states.customPace()),
                ("pauses-during-call", .pauses, AppState.preview(.pausedForCall)),
                ("wind-down-off", .windDown, AppState.preview(.idle)),
                ("routine-left-out", .routine, states.routineLeftOut()),
                ("routine-band", .routine, states.band()),
                ("about-update-available", .about, states.updates(.available(states.release))),
                ("about-update-no-key", .about, states.updates(.available(states.release), canInstall: false)),
                ("about-update-installing", .about, states.updates(.installing(states.release, .verifying))),
                ("about-update-install-failed", .about,
                 states.updates(.installFailed(states.release, UpdateInstallError.didNotStart.explanation))),
                ("about-up-to-date", .about, states.updates(.upToDate)),
                ("about-check-failed", .about, states.updates(.failed, automatic: false)),
                ("about-never-checked", .about, states.updates(.idle)),
            ]
            for (name, pane, state) in pages {
                try SettingsSnapshotPages.pane(url(name), pane: pane, look: look, state: state)
                count += 1
            }
            for (name, login) in [("general-login-outside-programs", LoginItemAvailability.outsideApplications),
                                  ("general-login-development-run", .developmentRun)] {
                let ui = SettingsUI()
                ui.login = login
                try SettingsSnapshotPages.pane(url(name), pane: .general, look: look, ui: ui)
                count += 1
            }
            // The shortcut recorder waiting, refusing the nudge's keys, and with a shortcut.
            let recording = SettingsUI()
            recording.recording = true
            try SettingsSnapshotPages.window(url("window-general-recording"), pane: .general, look: look, scroll: 560, ui: recording)
            let refused = SettingsUI()
            refused.recording = true
            refused.recorderHint = "\(HotKeys.display(.nudgeStart)) is used by the nudge"
            try SettingsSnapshotPages.window(url("window-general-recording-refused"), pane: .general, look: look, scroll: 560, ui: refused)
            let withShortcut = SettingsSnapshotStates.standard()
            withShortcut.settings.popoverHotkey = HotKeyCombo(keyCode: 0x0B, carbonModifiers: HotKeyCombo.controlKey | HotKeyCombo.optionKey,
                                                              display: "⌃⌥B")
            try SettingsSnapshotPages.window(url("window-general-shortcut"), pane: .general, look: look, scroll: 560, state: withShortcut)
            // The Codex folder being typed, the integrations' pill flashing.
            let typing = SettingsUI()
            typing.codexDraft = "D:\\tools\\codex"
            try SettingsSnapshotPages.pane(url("integrations-codex-folder-typing"), pane: .integrations, look: look,
                                           state: SettingsSnapshotStates.codexNotFound(), ui: typing, focused: SettingsUI.codexFieldID)
            let flashing = SettingsUI()
            flashing.flashing = [.claudeCode, .cursor]
            try SettingsSnapshotPages.pane(url("integrations-flashing"), pane: .integrations, look: look,
                                           state: states.installCheckFailed(), ui: flashing)
            // The options sheets over their panes.
            let calls = SettingsUI()
            calls.sheet = .callOptions
            try SettingsSnapshotPages.window(url("window-sheet-call-options"), pane: .pauses, look: look, ui: calls)
            let codex = SettingsUI()
            codex.sheet = .codexOptions
            try SettingsSnapshotPages.window(url("window-sheet-codex-options"), pane: .integrations, look: look, ui: codex)
            let codexBlocked = SettingsSnapshotStates.everyIntegrationStatus()
            if let index = codexBlocked.integrations.firstIndex(where: { $0.id == .codexNotify }) {
                codexBlocked.integrations[index].errorMessage = "~\\.codex\\config.toml already has a notify line, so Breakpoint left it alone."
            } else {
                codexBlocked.integrations.append(IntegrationRowState(
                    id: .codexNotify, status: .notInstalled,
                    errorMessage: "~\\.codex\\config.toml already has a notify line, so Breakpoint left it alone."))
            }
            try SettingsSnapshotPages.window(url("window-sheet-codex-options-hooks-installed"), pane: .integrations, look: look,
                                             state: codexBlocked, ui: codex)
            // The smallest window, and the keyboard focus in the sidebar and on a row.
            try SettingsSnapshotPages.window(url("window-minimum-size"), pane: .general, look: look, size: SettingsMetrics.minimumSize)
            try SettingsSnapshotPages.window(url("window-minimum-size-about-scrolled"), pane: .about, look: look, scroll: 240,
                                             size: SettingsMetrics.minimumSize)
            try SettingsSnapshotPages.window(url("window-focus-sidebar"), pane: .breaks, look: look,
                                             focused: SettingsView.sidebarID(.breaks))
            try SettingsSnapshotPages.window(url("window-focus-row"), pane: .breaks, look: look, focused: "preset.balanced")
            count += 12
        }
        try SettingsSnapshotPages.glyphs(folder.appendingPathComponent("glyphs.png"))
        return count + 1
    }
}

/// Draws the settings window and its panes offscreen.
@MainActor
enum SettingsSnapshotPages {
    static func window(_ url: URL, pane: SettingsPane, look: Look, scroll: Float = 0, state: AppState? = nil, ui: SettingsUI? = nil,
                       size: SizeF = Theme.Size.settingsSize, focused: String? = nil) throws {
        let state = state ?? SettingsSnapshotStates.standard()
        let ui = ui ?? SettingsUI()
        var model = SettingsModel(state: state, pane: pane, look: look, ui: ui, opaque: true)
        model.scroll = min(scroll, SettingsView.maxScroll(model, size: size))
        try Snapshot.write(url, size: size, look: look, background: nil, focused: focused) { canvas, controls in
            if focused != nil { controls.debugShowFocus() }
            SettingsView.draw(canvas, controls, model, SettingsHandlers())
        }
    }

    /// The pane's whole length, as if scrolled through, 660 wide with 24 around it.
    static func pane(_ url: URL, pane: SettingsPane, look: Look, state: AppState? = nil, ui: SettingsUI? = nil,
                     focused: String? = nil) throws {
        let state = state ?? SettingsSnapshotStates.standard()
        let ui = ui ?? SettingsUI()
        let model = SettingsModel(state: state, pane: pane, look: look, ui: ui, opaque: true)
        let width: Float = 660, inset: Float = 24
        var measure = SettingsPage(canvas: nil, controls: nil, inert: nil, look: look, x: inset, width: width - 2 * inset, y: inset)
        SettingsPanes.draw(pane, &measure, model, SettingsHandlers())
        let height = measure.y - SettingsMetrics.sectionGap + inset
        try Snapshot.write(url, size: SizeF(width: width, height: height), look: look,
                           background: { canvas in
                               canvas.fill(canvas.bounds, look.dark ? Colour(hex: 0x202020) : Colour(hex: 0xF3F3F3))
                               canvas.fill(canvas.bounds, look.dark ? Colour.white.opacity(0.035) : Colour.white.opacity(0.6))
                           }, focused: focused) { canvas, controls in
            ui.inert.look = look
            ui.inert.begin()
            var page = SettingsPage(canvas: canvas, controls: controls, inert: ui.inert, look: look, x: inset, width: width - 2 * inset,
                                    y: inset, frames: ui.frames)
            SettingsPanes.draw(pane, &page, model, SettingsHandlers())
        }
    }

    /// Every symbol the settings rows name, as drawn on Windows (to check the icon font's glyphs).
    static func glyphs(_ url: URL) throws {
        let symbols = SettingsPane.allCases.map(\.systemImage) + SettingsGlyph.extra.keys.sorted()
            + ["eye", "sparkle", "figure.arms.open", "moon", "lock", "keyboard", "bell", "hourglass", "clock", "checkmark", "xmark",
               "info.circle", "square.and.arrow.up", "trash", "arrow.down.circle", "speaker.fill", "speaker.wave.3.fill"]
        let columns = 8
        let cell: Float = 72
        let rows = (symbols.count + columns - 1) / columns
        try Snapshot.write(url, size: SizeF(width: Float(columns) * cell, height: Float(rows) * cell), look: .dark) { canvas, _ in
            for (index, symbol) in symbols.enumerated() {
                let x = Float(index % columns) * cell, y = Float(index / columns) * cell
                SettingsGlyph.draw(symbol, on: canvas, centre: PointF(x: x + cell / 2, y: y + 26), size: 20, Colour.white)
                canvas.text(symbol, at: PointF(x: x + 2, y: y + 48), width: cell - 4, style: TextStyle(size: 8, align: .center, wrap: true),
                            Colour.white.opacity(0.6))
            }
        }
    }
}

/// The states the macOS snapshots show (`SettingsStates`), built the same way.
@MainActor
enum SettingsSnapshotStates {
    /// Agent connected, defaults otherwise, wind-down on so its pane shows its controls.
    static func standard() -> AppState {
        let state = AppState.preview(.agentWorking)
        state.settings.windDownEnabled = true
        state.settings.stopDays = .weekdays
        return state
    }

    /// First run with Codex not in its default folder: the folder override row shows.
    static func codexNotFound() -> AppState {
        let state = AppState.preview(.firstRun)
        if let index = state.integrations.firstIndex(where: { $0.id == .codex }) {
            state.integrations[index] = IntegrationRowState(id: .codex, status: .notFound)
        }
        return state
    }

    static func customPace() -> AppState {
        let state = standard()
        state.settings.eyesEveryMinutes = 25
        state.settings.moveEveryMinutes = 45
        state.settings.preset = .custom
        return state
    }

    static func band() -> AppState {
        let state = standard()
        state.settings.hasBand = true
        return state
    }

    static func routineLeftOut() -> AppState {
        let state = standard()
        state.settings.setRoutine("hips-and-calves", excluded: true)
        return state
    }

    /// Every pill: connected with a last event, connected before any (Codex adds its trust step),
    /// busy, an unreadable file, an install from another version (Update and Remove), an edited
    /// one (Restore), and an error. ("Not found" is in integrations-first-run.)
    static func everyIntegrationStatus() -> AppState {
        let state = standard()
        let now = state.now
        state.integrations = [
            IntegrationRowState(id: .claudeCode, status: .connected(lastEvent: now.addingTimeInterval(-120))),
            IntegrationRowState(id: .cursor, status: .problem("~\\.cursor\\hooks.json is not valid JSON, so Breakpoint left it alone.")),
            IntegrationRowState(id: .codex, status: .connected(lastEvent: nil), notes: ["Open /hooks in Codex and trust the new entries."]),
            IntegrationRowState(id: .copilot, status: .notInstalled, isBusy: true),
            IntegrationRowState(id: .gemini, status: IntegrationStatus(installState: .outdated, lastEvent: nil), installState: .outdated),
            IntegrationRowState(id: .shell, status: IntegrationStatus(installState: .modified, lastEvent: nil),
                                errorMessage: "Your PowerShell profile is read-only, so nothing was changed.", installState: .modified),
        ]
        return state
    }

    /// Install checks (§5.6): Claude Code's hooks could not reach the app, Cursor verified a moment
    /// ago (its note), Copilot's CLI copy gone missing, and the shell just installed (its note).
    static func installCheckFailed() -> AppState {
        let state = standard()
        func failed(_ id: IntegrationID, _ problem: String) -> IntegrationRowState {
            IntegrationRowState(id: id, status: IntegrationStatus(installState: .installed, lastEvent: nil, checkProblem: problem),
                                installState: .installed)
        }
        state.integrations = [
            failed(.claudeCode, "Its hooks ran but didn’t reach Breakpoint. Quit and reopen Breakpoint, then Install again."),
            IntegrationRowState(id: .cursor, status: .connected(lastEvent: nil), notes: CursorIntegration.installNotes, connectedAt: state.now),
            IntegrationRowState(id: .codex, status: .notInstalled),
            failed(.copilot, "The command its hooks call is missing. Install again to put it back."),
            IntegrationRowState(id: .gemini, status: .notFound),
            IntegrationRowState(id: .shell, status: .connected(lastEvent: nil), notes: ["Open a new PowerShell window to start."]),
        ]
        return state
    }

    static let release = UpdateRelease(
        version: "0.2.0", notes: "Breaks now wait for Codex and Gemini too, and the routine has two new stretches.",
        page: URL(string: "https://github.com/estrindavid/breakpoint/releases/tag/v0.2.0")!,
        archive: URL(string: "https://github.com/estrindavid/breakpoint/releases/download/v0.2.0/Breakpoint-0.2.0-windows.zip")!,
        size: 41_000_000, sha256: String(repeating: "a", count: 64), signature: Data(count: 64).base64EncodedString())

    /// Settings → About with the update check in `phase`, last checked at 09:12 today.
    static func updates(_ phase: UpdatePhase, automatic: Bool = true, canInstall: Bool = true) -> AppState {
        let state = standard()
        state.settings.checkForUpdates = automatic
        let checked = Calendar.current.date(bySettingHour: 9, minute: 12, second: 0, of: state.now)
        state.update = UpdateState(phase: phase, lastCheckedAt: phase == .failed || phase == .idle ? nil : checked,
                                   installBlocker: canInstall ? nil : UpdateCopy.noKey)
        return state
    }
}
