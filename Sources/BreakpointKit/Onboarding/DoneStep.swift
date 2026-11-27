import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.10 step 5.

/// "Breakpoint lives in your menu bar" with a small arrow pointing at the status item's actual
/// position (`StatusItemController.statusItemFrame`), the open-at-login choice, and what a click
/// on the item does.
public struct DoneStep: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    @ObservedObject var flow: OnboardingFlow
    @Environment(\.colorScheme) private var scheme
    @Environment(\.loginItemStatusProvider) private var loginStatusProvider
    @State private var nudged = false
    private let traits = DesignTraits()

    public init(state: AppState, actions: AppActions) {
        self.init(state: state, actions: actions, flow: OnboardingFlow(step: .done))
    }

    init(state: AppState, actions: AppActions, flow: OnboardingFlow) {
        self.state = state
        self.actions = actions
        self.flow = flow
    }

    public var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrow.up")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Colors.accent(for: scheme))
                .rotationEffect(.degrees(flow.arrowAngle ?? 30))
                .offset(y: nudged && traits.runsContinuousAnimations ? -3 : 0)
                .frame(height: 30)
                .padding(.top, 28)
                .accessibilityHidden(true)
                .onAppear {
                    guard traits.runsContinuousAnimations else { return }
                    withAnimation(Theme.Motion.arrowBob) { nudged = true }
                }
            MenuBarStripPreview([MenuBarState(mark: .idle, badge: .none, tooltip: "Breakpoint")],
                                backdrop: scheme == .dark ? .dark : .light, highlighted: true)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                .padding(.top, 10)
                .accessibilityHidden(true)
            Text("Breakpoint lives in your menu bar")
                .font(Theme.Typography.onboardingTitle)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text(placeSentence)
                .font(Theme.Typography.onboardingSentence)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                tip("cursorarrow.click", "Click it to see your next break, pause, or take one now.")
                tip("cursorarrow.click.2", "Right-click it for the same in a menu.")
                tip("gearshape", "Change anything later in Settings.")
            }
            .padding(16)
            .frame(width: 400, alignment: .leading)
            .background(OnboardingCard())
            .padding(.top, 20)

            loginChoice
                .padding(.top, 16)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    /// Outside an Applications folder a login item would point at a copy that moves or is
    /// deleted, so the choice is off and says why (§3.10). Development runs (`BREAKPOINT_HOME`)
    /// keep the plain choice: they never register anything.
    @ViewBuilder private var loginChoice: some View {
        if case .unavailable(let reason) = loginStatusProvider(), reason != LoginItem.developmentRunNote {
            VStack(spacing: 6) {
                LoginChoice(isOn: .constant(false))
                    .disabled(true)
                Text(reason)
                    .font(Theme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            LoginChoice(isOn: settingBinding(state, actions, \.launchAtLogin))
        }
    }

    private var placeSentence: String {
        if flow.statusItemVisible {
            // The tour is offered under the mark when this window closes (SPEC §3.12), once.
            let then = state.settings.tourStatus == .notOffered
                ? "When you close this window, it offers a one-minute tour."
                : "It opens there once when you close this window."
            return "Look for this mark at the \(flow.statusItemPlace). \(then)"
        }
        return "macOS is hiding it because your menu bar is full. Hold ⌘ and drag other icons out of the menu bar to make room."
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text).font(Theme.Typography.row).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Open at login" as a capsule check (✓ when on), so it reads as a choice and works by click,
/// Space or VoiceOver.
private struct LoginChoice: View {
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Theme.Colors.accent(for: scheme) : Color.secondary)
                Text("Open Breakpoint at login")
                    .foregroundStyle(.primary)
            }
            .font(Theme.Typography.row)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule(style: .circular).fill(Color.primary.opacity(0.05)))
            .contentShape(Capsule(style: .circular))
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Breakpoint at login")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
