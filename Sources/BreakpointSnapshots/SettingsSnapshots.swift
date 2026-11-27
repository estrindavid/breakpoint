import SwiftUI
import BreakpointCore
import BreakpointKit

// Every settings pane in light and dark: the whole
// window at its default size (as first opened), each pane's full length, the Integrations pane with
// tools in every status, the options sheets and other states.

enum SettingsSnapshots {
    @MainActor static var all: [Snapshot] {
        var list: [Snapshot] = []
        for pane in SettingsPane.allCases {
            // The real window at its default size (what you see when it opens).
            list.append(Snapshot("settings/window-\(pane.rawValue)", size: Theme.Layout.settingsDefaultSize,
                                 scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 0) {
                SettingsRootView(state: SettingsStates.standard(), actions: .noop, selection: SettingsSelection(pane: pane))
                    .loginItemStatusPreview(.enabled)
            })
            // The pane's whole length, as if scrolled through.
            list.append(Snapshot("settings/\(pane.rawValue)-full", size: CGSize(width: 660, height: SettingsStates.fullHeight(pane)),
                                 scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: pane, state: SettingsStates.standard(), actions: .noop)
                    .loginItemStatusPreview(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            })
        }

        list += [
            Snapshot("settings/window-minimum-size", size: Theme.Layout.settingsMinimumSize, scenes: SnapshotScene.lightAndDark,
                     renderer: .window, padding: 0) {
                SettingsRootView(state: SettingsStates.standard(), actions: .noop, selection: SettingsSelection(pane: .general))
                    .loginItemStatusPreview(.enabled)
            },
            Snapshot("settings/integrations-every-status", size: CGSize(width: 660, height: 900), scenes: SnapshotScene.lightAndDark,
                     renderer: .window, padding: 24) {
                SettingsPaneView(pane: .integrations, state: SettingsStates.everyIntegrationStatus(), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/integrations-install-check-failed", size: CGSize(width: 660, height: 900), scenes: SnapshotScene.lightAndDark,
                     renderer: .window, padding: 24) {
                SettingsPaneView(pane: .integrations, state: SettingsStates.installCheckFailed(), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/integrations-first-run", size: CGSize(width: 660, height: 760), scenes: SnapshotScene.lightAndDark,
                     renderer: .window, padding: 24) {
                SettingsPaneView(pane: .integrations, state: AppState.preview(.firstRun), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/breaks-custom-pace", size: CGSize(width: 660, height: 980), scenes: SnapshotScene.lightAndDark,
                     renderer: .window, padding: 24) {
                SettingsPaneView(pane: .breaks, state: SettingsStates.customPace(), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/pauses-during-call", size: CGSize(width: 660, height: 720), scenes: SnapshotScene.lightAndDark,
                     renderer: .window, padding: 24) {
                SettingsPaneView(pane: .pauses, state: AppState.preview(.pausedForCall), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/wind-down-off", size: CGSize(width: 660, height: 820), scenes: SnapshotScene.lightAndDark,
                     renderer: .window, padding: 24) {
                SettingsPaneView(pane: .windDown, state: AppState.preview(.idle), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/routine-left-out", size: CGSize(width: 660, height: SettingsStates.fullHeight(.routine)),
                     scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: .routine, state: SettingsStates.routineLeftOut(), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/routine-band", size: CGSize(width: 660, height: SettingsStates.fullHeight(.routine) + 100),
                     scenes: SnapshotScene.lightAndDark,
                     renderer: .window, padding: 24) {
                SettingsPaneView(pane: .routine, state: SettingsStates.band(), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/general-login-needs-approval", size: CGSize(width: 660, height: SettingsStates.fullHeight(.general) + 60),
                     scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: .general, state: SettingsStates.standard(), actions: .noop)
                    .loginItemStatusPreview(.requiresApproval)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/general-login-outside-applications", size: CGSize(width: 660, height: SettingsStates.fullHeight(.general)),
                     scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: .general, state: SettingsStates.standard(), actions: .noop)
                    .loginItemStatusPreview(.unavailable(reason: LoginItem.outsideApplicationsNote))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/general-login-development-run", size: CGSize(width: 660, height: SettingsStates.fullHeight(.general)),
                     scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: .general, state: SettingsStates.standard(), actions: .noop)
                    .loginItemStatusPreview(.unavailable(reason: LoginItem.developmentRunNote))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/about-update-available", size: CGSize(width: 660, height: SettingsStates.fullHeight(.about)),
                     scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: .about, state: SettingsStates.updates(.available(SettingsStates.release)), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/about-update-no-key", size: CGSize(width: 660, height: SettingsStates.fullHeight(.about)),
                     scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: .about, state: SettingsStates.updates(.available(SettingsStates.release), canInstall: false),
                                 actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/about-update-installing", size: CGSize(width: 660, height: SettingsStates.fullHeight(.about)),
                     scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: .about, state: SettingsStates.updates(.installing(SettingsStates.release, .verifying)),
                                 actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/about-update-install-failed", size: CGSize(width: 660, height: SettingsStates.fullHeight(.about)),
                     scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: .about, state: SettingsStates.updates(
                    .installFailed(SettingsStates.release, UpdateInstallError.didNotStart.explanation)), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/about-up-to-date", size: CGSize(width: 660, height: SettingsStates.fullHeight(.about)),
                     scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: .about, state: SettingsStates.updates(.upToDate), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/about-check-failed", size: CGSize(width: 660, height: SettingsStates.fullHeight(.about)),
                     scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsPaneView(pane: .about, state: SettingsStates.updates(.failed, automatic: false), actions: .noop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            Snapshot("settings/sheet-call-options", scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 0) {
                SettingsPaneView.preview(.callOptions, state: SettingsStates.standard())
                    .background(Color(nsColor: .windowBackgroundColor))
            },
            Snapshot("settings/sheet-codex-options", scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 0) {
                SettingsPaneView.preview(.codexOptions, state: SettingsStates.standard())
                    .background(Color(nsColor: .windowBackgroundColor))
            },
        ]
        return list
    }
}

@MainActor
enum SettingsStates {
    /// Agent connected, defaults otherwise, wind-down on so its pane shows its controls.
    static func standard() -> AppState {
        let state = AppState.preview(.agentWorking)
        state.settings.windDownEnabled = true
        state.settings.stopDays = .weekdays
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

    /// One routine left out of the rotation.
    static func routineLeftOut() -> AppState {
        let state = standard()
        state.settings.setRoutine("hips-and-calves", excluded: true)
        return state
    }

    /// Every pill: connected with a last event, connected before any (Codex adds its trust step),
    /// an install whose check failed (Install again and Remove), not installed, busy, an unreadable
    /// file, an install from another version (Update and Remove), an install note and an error.
    /// ("Not found" is in integrations-first-run.)
    static func everyIntegrationStatus() -> AppState {
        let state = standard()
        let now = state.now
        state.integrations = [
            IntegrationRowState(id: .claudeCode, status: .connected(lastEvent: now.addingTimeInterval(-120))),
            IntegrationRowState(id: .cursor, status: .problem("~/.cursor/hooks.json is not valid JSON, so Breakpoint left it alone.")),
            IntegrationRowState(id: .codex, status: .connected(lastEvent: nil),
                                notes: ["Open /hooks in Codex and trust the new entries."]),
            IntegrationRowState(id: .copilot, status: .notInstalled, isBusy: true),
            IntegrationRowState(id: .gemini, status: IntegrationStatus(installState: .outdated, lastEvent: nil),
                                installState: .outdated),
            IntegrationRowState(id: .shell, status: .notInstalled,
                                errorMessage: "~/.zshrc is read-only, so nothing was changed."),
        ]
        return state
    }

    /// Install checks (§5.6): Claude Code's hooks could not reach the app, Cursor verified a moment
    /// ago (its note), Copilot's CLI copy gone missing, and the shell just installed (its note).
    static func installCheckFailed() -> AppState {
        let state = standard()
        let environment = OnboardingStates.environment
        func failed(_ id: IntegrationID, _ problem: String) -> IntegrationRowState {
            IntegrationRowState(id: id, status: IntegrationStatus(installState: .installed, lastEvent: nil, checkProblem: problem),
                                installState: .installed)
        }
        let missing = InstallCheck.problem(for: .copilot, state: .installed, environment: environment)
            ?? "The command its hooks call is missing."
        state.integrations = [
            failed(.claudeCode, InstallCheck.unreachableProblem(cliRuns: true, environment: environment)),
            IntegrationRowState(id: .cursor, status: .connected(lastEvent: nil), notes: CursorIntegration.installNotes,
                                connectedAt: state.now),
            IntegrationRowState(id: .codex, status: .notInstalled),
            failed(.copilot, missing),
            IntegrationRowState(id: .gemini, status: .notFound),
            IntegrationRowState(id: .shell, status: .connected(lastEvent: nil), notes: ["Open a new terminal window to start."]),
        ]
        return state
    }

    static let release = UpdateRelease(
        version: "0.2.0", notes: "Breaks now wait for Codex and Gemini too, and the routine has two new stretches.",
        page: URL(string: "https://github.com/estrindavid/breakpoint/releases/tag/v0.2.0")!,
        archive: URL(string: "https://github.com/estrindavid/breakpoint/releases/download/v0.2.0/Breakpoint-0.2.0.zip")!,
        size: 4_800_000, sha256: String(repeating: "a", count: 64), signature: Data(count: 64).base64EncodedString())

    /// Settings → About with the update check in `phase`, last checked at 09:12 today.
    static func updates(_ phase: UpdatePhase, automatic: Bool = true, canInstall: Bool = true) -> AppState {
        let state = standard()
        state.settings.checkForUpdates = automatic
        let checked = Calendar.current.date(bySettingHour: 9, minute: 12, second: 0, of: state.now)
        state.update = UpdateState(phase: phase, lastCheckedAt: phase == .failed ? nil : checked,
                                   installBlocker: canInstall ? nil
                                       : UpdateCopy.noKey)
        return state
    }

    /// Canvas heights that fit each pane's full length.
    static func fullHeight(_ pane: SettingsPane) -> CGFloat {
        switch pane {
        case .breaks: return 960
        case .routine: return 700
        case .pauses: return 620
        case .windDown: return 780
        case .integrations: return 780
        case .general: return 980
        case .privacy: return 1080
        case .about: return 860
        }
    }
}
