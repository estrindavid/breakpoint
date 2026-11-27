import SwiftUI
import BreakpointCore
import BreakpointKit

// Every onboarding step in light and dark, the
// demo at each moment and as Reduce Motion stills, and the connect step before, during and after
// an install (connected, or a check that failed).

enum OnboardingSnapshots {
    @MainActor static var all: [Snapshot] {
        var list: [Snapshot] = []
        let steps: [(String, OnboardingStep)] = [("1-welcome", .welcome), ("2-how-it-works", .howItWorks),
                                                 ("3-connect", .connect), ("4-pace", .pace), ("5-done", .done)]
        for (name, step) in steps {
            list.append(Snapshot("onboarding/step-\(name)", scenes: SnapshotScene.lightAndDark,
                                 variants: step == .welcome ? SnapshotVariant.accessibility : [.standard],
                                 renderer: .imageRenderer, padding: 0) {
                OnboardingView(state: AppState.preview(.firstRun), actions: .noop, initialStep: step, demoPhase: .nudge)
                    .loginItemStatusPreview(.off)
            })
        }
        // Run from outside an Applications folder: the login choice is off and says why (§3.10).
        list.append(Snapshot("onboarding/step-5-done-login-outside-applications", scenes: SnapshotScene.lightAndDark,
                             renderer: .imageRenderer, padding: 0) {
            OnboardingView(state: AppState.preview(.firstRun), actions: .noop, initialStep: .done, demoPhase: nil)
                .loginItemStatusPreview(.unavailable(reason: LoginItem.outsideApplicationsNote))
        })
        for phase in HowItWorksStep.Phase.allCases {
            list.append(Snapshot("onboarding/demo-\(phase.rawValue)-\(String(describing: phase))", scenes: [SnapshotScene(appearance: .dark, backdrop: .window)],
                                 renderer: .imageRenderer, padding: 0) {
                OnboardingView(state: AppState.preview(.firstRun), actions: .noop, initialStep: .howItWorks, demoPhase: phase)
            })
        }
        list.append(Snapshot("onboarding/demo-reduce-motion-stills", scenes: SnapshotScene.lightAndDark, variants: [.reduceMotion],
                             renderer: .imageRenderer, padding: 0) {
            OnboardingView(state: AppState.preview(.firstRun), actions: .noop, initialStep: .howItWorks, demoPhase: nil)
        })
        let connect: [(String, @MainActor () -> AppState)] = [
            ("nothing-installed", { AppState.preview(.firstRun) }),
            ("installing", { OnboardingStates.connect(.installing) }),
            ("connected", { OnboardingStates.connect(.connected) }),
            ("codex-trusted", { OnboardingStates.connect(.codexHeard) }),
            ("install-check-failed", { OnboardingStates.connect(.checkFailed) }),
            ("install-check-hooks-off", { OnboardingStates.connect(.hooksOff) }),
            ("no-tools-found", { OnboardingStates.connect(.noneFound) }),
        ]
        for (name, make) in connect {
            list.append(Snapshot("onboarding/connect-\(name)", scenes: SnapshotScene.lightAndDark, renderer: .imageRenderer, padding: 0) {
                OnboardingView(state: make(), actions: .noop, initialStep: .connect, demoPhase: nil)
            })
        }
        list.append(Snapshot("onboarding/connect-connected-hop", scenes: SnapshotScene.lightAndDark,
                             variants: [.standard, .reduceMotion], renderer: .imageRenderer, padding: 24) {
            ConnectedHopStrip()
        })
        return list
    }
}

@MainActor
enum OnboardingStates {
    enum Connect { case installing, connected, codexHeard, checkFailed, hooksOff, noneFound }

    /// Claude Code just installed (its note), Codex installed and not yet heard from (its trust
    /// step), and the variants.
    static func connect(_ stage: Connect) -> AppState {
        let state = AppState.preview(.firstRun)
        let now = state.now
        let claudeNotes = ClaudeCodeIntegration.installNotes
        state.integrations = state.integrations.map { row in
            var row = row
            switch (stage, row.id) {
            case (.installing, .claudeCode): row.isBusy = true
            case (.connected, .claudeCode): row.status = .connected(lastEvent: nil); row.notes = claudeNotes
            case (.connected, .codex), (.checkFailed, .codex), (.hooksOff, .codex): row.status = .connected(lastEvent: nil)
            case (.codexHeard, .claudeCode): row.status = .connected(lastEvent: now.addingTimeInterval(-90))
            case (.codexHeard, .codex): row.status = .connected(lastEvent: now.addingTimeInterval(-30))
            case (.checkFailed, .claudeCode):
                row.status = IntegrationStatus(installState: .installed, lastEvent: nil,
                                               checkProblem: InstallCheck.unreachableProblem(cliRuns: true, environment: Self.environment))
                row.notes = claudeNotes
            case (.hooksOff, .claudeCode):
                row.status = IntegrationStatus(installState: .installed, lastEvent: nil,
                                               checkProblem: InstallCheck.claudeHooksOff)
            case (.noneFound, .shell): row.status = .notInstalled
            case (.noneFound, _): row.status = .notFound
            default: break
            }
            // Installed (a failed check included: its entries are there, so Remove applies).
            row.installState = row.status.isInstalled || (stage == .checkFailed || stage == .hooksOff) && row.id == .claudeCode
                ? .installed : IntegrationRowState(id: row.id, status: row.status).installState
            return row
        }
        return state
    }

    /// A made-up home for the sentences that show paths (they abbreviate it to ~).
    static let environment = IntegrationEnvironment(paths: BreakpointPaths(home: URL(fileURLWithPath: "/Users/you")))
}

/// An install verified on the Connect step: the ✓ hops 4 pt once and the pill flashes mint, as key
/// frames over its 0.45 s (Reduce Motion: no hop, a 0.2 s flash).
private struct ConnectedHopStrip: View {
    static let frames: [Double] = [0, 0.15, 0.3, 0.45, 0.6, 0.8, 1]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Self.frames, id: \.self) { progress in
                    VStack(spacing: 6) {
                        ConnectedPill(connectedAt: nil, frozenProgress: progress)
                            .padding(.top, 6)
                        Text(String(format: "%.2f s", progress * Theme.Motion.connectedHopDuration))
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Text("Key frames: the ✓ hops 4 pt once and the pill flashes mint (0.4 s), then rests.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
