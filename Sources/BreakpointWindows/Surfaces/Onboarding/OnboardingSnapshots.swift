import BreakpointCore
import BreakpointRuntime
import Foundation

extension SnapshotCatalogue {
    /// The onboarding window in every state, into `directory`/onboarding.
    static func onboardingSnapshots(_ directory: URL) throws -> Int {
        let folder = directory.appendingPathComponent("onboarding")
        var count = 0
        let looks: [(String, Look)] = [("light", .light), ("dark", .dark)]

        func shot(_ name: String, _ state: AppState, _ step: OnboardingStep, looks chosen: [(String, Look)] = looks,
                  focused: String? = nil, configure: (OnboardingModel) -> Void = { _ in }) throws {
            for (suffix, look) in chosen {
                let model = OnboardingModel(step: step)
                model.frozen = true
                model.arrowAngle = 135
                configure(model)
                try Snapshot.write(folder.appendingPathComponent("\(name)-\(suffix).png"), size: Theme.Size.onboardingSize, look: look,
                                   background: { OnboardingView.background($0, look: look) }, focused: focused) { canvas, controls in
                    if focused != nil { controls.debugShowFocus() }
                    OnboardingView.draw(canvas, controls, state: state, model: model, handlers: OnboardingView.Handlers(),
                                        now: AppState.previewNow)
                }
                count += 1
            }
        }

        // Every step, light and dark.
        let steps: [(String, OnboardingStep)] = [("1-welcome", .welcome), ("2-how-it-works", .howItWorks), ("3-connect", .connect),
                                                 ("4-pace", .pace), ("5-done", .done)]
        for (name, step) in steps { try shot("step-\(name)", AppState.preview(.firstRun), step) }

        // The Done step's other words: the tour already offered, the icon in the overflow, the
        // login choice unavailable for a copy outside Programs.
        let offered = AppState.preview(.firstRun)
        offered.settings.tourStatus = .declined
        try shot("step-5-done-tour-already-offered", offered, .done)
        try shot("step-5-done-icon-hidden", AppState.preview(.firstRun), .done) { $0.iconVisible = false; $0.arrowAngle = nil }
        try shot("step-5-done-login-outside-programs", AppState.preview(.firstRun), .done) { $0.loginAvailability = .outsideApplications }
        try shot("step-5-done-top-left", AppState.preview(.firstRun), .done) { $0.iconPlace = "top left of your screen"; $0.arrowAngle = -45 }

        // The demo at each moment (dark), and its reduced-motion stills.
        for phase in OnboardingDemo.Phase.allCases {
            try shot("demo-\(phase.rawValue)-\(phase)", AppState.preview(.firstRun), .howItWorks, looks: [("dark", .dark)]) {
                $0.demoPhase = phase
            }
        }
        try shot("demo-reduce-motion-stills", AppState.preview(.firstRun), .howItWorks) { $0.reduceMotion = true }

        // Connect in every status.
        for stage in OnboardingConnectStage.allCases {
            try shot("connect-\(stage.rawValue)", stage.state(), .connect)
        }
        // The ✓'s hop, mid-flight, and the keyboard focus on Install.
        try shot("connect-connected-hop-mid", OnboardingConnectStage.connected.state(), .connect) { $0.hopProgress = 0.3 }
        try shot("connect-focus", AppState.preview(.firstRun), .connect, focused: "claude-code.Install")
        try shot("step-4-pace-gentle", { let s = AppState.preview(.firstRun); s.settings.applyPreset(.gentle); return s }(), .pace)
        count += try connectedHopStrip(folder)
        return count
    }

    /// The ✓'s hop as key frames over its 0.45 s.
    private static func connectedHopStrip(_ folder: URL) throws -> Int {
        let frames: [Double] = [0, 0.15, 0.3, 0.45, 0.6, 0.8, 1]
        for (suffix, look) in [("light", Look.light), ("dark", Look.dark)] {
            try Snapshot.write(folder.appendingPathComponent("connect-connected-hop-\(suffix).png"),
                               size: SizeF(width: Float(frames.count) * (OnboardingConnect.pillWidth + 14) + 14, height: 64), look: look,
                               background: { OnboardingView.background($0, look: look) }) { canvas, _ in
                for (index, progress) in frames.enumerated() {
                    let x = 14 + Float(index) * (OnboardingConnect.pillWidth + 14)
                    OnboardingConnect.connectedPill(canvas, at: PointF(x: x, y: 12), look: look, progress: progress, reduceMotion: false)
                    canvas.text(String(format: "%.2f s", progress * OnboardingView.hopDuration), at: PointF(x: x, y: 46),
                                style: TextStyle(size: 10, monospacedDigits: true), look.secondary)
                }
            }
        }
        return 2
    }
}

/// The Connect step's states (as the macOS `OnboardingStates.connect`): Claude Code installing,
/// connected with its note, Codex installed and not yet heard from (its trust line) or heard
/// from, a failed install check, hooks turned off, updates and edits, an install error, and no
/// tools found.
enum OnboardingConnectStage: String, CaseIterable {
    case installing, connected, codexTrusted = "codex-trusted", checkFailed = "install-check-failed",
         hooksOff = "install-check-hooks-off", outdatedAndEdited = "outdated-and-edited", installError = "install-error",
         noneFound = "no-tools-found"

    @MainActor
    func state() -> AppState {
        let state = AppState.preview(.firstRun)
        let now = state.now
        let environment = IntegrationEnvironment(paths: BreakpointPaths(home: URL(fileURLWithPath: "C:/Users/you")))
        let claudeNotes = ClaudeCodeIntegration.installNotes
        state.integrations = state.integrations.map { row in
            var row = row
            switch (self, row.id) {
            case (.installing, .claudeCode): row.isBusy = true
            case (.connected, .claudeCode): row.status = .connected(lastEvent: nil); row.notes = claudeNotes
            case (.connected, .codex), (.checkFailed, .codex), (.hooksOff, .codex): row.status = .connected(lastEvent: nil)
            case (.codexTrusted, .claudeCode): row.status = .connected(lastEvent: now.addingTimeInterval(-90))
            case (.codexTrusted, .codex): row.status = .connected(lastEvent: now.addingTimeInterval(-30))
            case (.checkFailed, .claudeCode):
                row.status = IntegrationStatus(installState: .installed, lastEvent: nil,
                                               checkProblem: InstallCheck.unreachableProblem(cliRuns: true, environment: environment))
                row.notes = claudeNotes
            case (.hooksOff, .claudeCode):
                row.status = IntegrationStatus(installState: .installed, lastEvent: nil, checkProblem: InstallCheck.claudeHooksOff)
            case (.outdatedAndEdited, .claudeCode):
                row.status = IntegrationStatus(installState: .outdated, lastEvent: nil)
                row.installState = .outdated
            case (.outdatedAndEdited, .codex):
                row.status = IntegrationStatus(installState: .modified, lastEvent: nil)
                row.installState = .modified
            case (.installError, .claudeCode):
                row.errorMessage = "Could not write ~/.claude/settings.json: access is denied."
            case (.noneFound, .shell): row.status = .notInstalled
            case (.noneFound, _): row.status = .notFound
            default: break
            }
            if self != .outdatedAndEdited {
                row.installState = row.status.isInstalled || (self == .checkFailed || self == .hooksOff) && row.id == .claudeCode
                    ? .installed : IntegrationRowState(id: row.id, status: row.status).installState
            }
            return row
        }
        return state
    }
}
