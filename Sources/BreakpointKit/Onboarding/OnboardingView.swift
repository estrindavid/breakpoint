import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.10.

/// Where onboarding is, shared by the window controller (keys) and the view (clicks).
@MainActor
final class OnboardingFlow: ObservableObject {
    @Published var step: OnboardingStep
    /// Direction from the window to the status item, in degrees clockwise from "up"; `nil` when
    /// unknown. Set by the controller when the Done step shows.
    @Published var arrowAngle: Double?
    /// The status item can be seen (not hidden by a full menu bar or the notch).
    @Published var statusItemVisible = true
    /// "top right" / "top left" / "top of your screen".
    @Published var statusItemPlace = "top right of your screen"
    /// Called when the last step finishes or the user skips.
    var onFinish: () -> Void = {}
    /// The step went forward (true) or back (false); drives the slide direction.
    private(set) var forward = true

    init(step: OnboardingStep = .welcome) { self.step = step }

    func advance() {
        if let next = OnboardingStep(rawValue: step.rawValue + 1) {
            forward = true
            step = next
        } else {
            onFinish()
        }
    }

    func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        forward = false
        step = previous
    }

    func skip() { onFinish() }
}

/// The step container: current step, page dots at the bottom, Skip setup, Back (Esc / ⌘[) and
/// Continue (primary, Return) at the bottom right.
public struct OnboardingView: View {
    @ObservedObject private var state: AppState
    private let actions: AppActions
    @ObservedObject private var flow: OnboardingFlow
    private let demoPhase: HowItWorksStep.Phase?
    private let traits = DesignTraits()
    @Environment(\.colorScheme) private var scheme

    public init(state: AppState, actions: AppActions, initialStep: OnboardingStep = .welcome, onFinish: @escaping () -> Void) {
        let flow = OnboardingFlow(step: initialStep)
        flow.onFinish = onFinish
        self.init(state: state, actions: actions, flow: flow, demoPhase: nil)
    }

    /// Snapshots: a step with the How it works demo frozen at `demoPhase`.
    public init(state: AppState, actions: AppActions, initialStep: OnboardingStep, demoPhase: HowItWorksStep.Phase?) {
        self.init(state: state, actions: actions, flow: OnboardingFlow(step: initialStep), demoPhase: demoPhase)
    }

    init(state: AppState, actions: AppActions, flow: OnboardingFlow, demoPhase: HowItWorksStep.Phase? = nil) {
        self.state = state
        self.actions = actions
        self.flow = flow
        self.demoPhase = demoPhase
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepView
                    .id(flow.step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            bottomBar
        }
        .frame(minWidth: Theme.Layout.onboardingSize.width, maxWidth: .infinity,
               minHeight: Theme.Layout.onboardingSize.height, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .animation(traits.reduceMotion ? .easeInOut(duration: Theme.Motion.reduceMotionFade)
                   : Theme.Motion.pageChange, value: flow.step)
        .tint(Theme.Colors.accent(for: scheme))
    }

    @ViewBuilder private var stepView: some View {
        switch flow.step {
        case .welcome: WelcomeStep()
        case .howItWorks: HowItWorksStep(state: state, frozenPhase: demoPhase)
        case .connect: ConnectStep(state: state, actions: actions)
        case .pace: PaceStep(state: state, actions: actions)
        case .done: DoneStep(state: state, actions: actions, flow: flow)
        }
    }

    private var stepTransition: AnyTransition {
        if traits.reduceMotion { return .opacity }
        let edgeIn: Edge = flow.forward ? .trailing : .leading
        let edgeOut: Edge = flow.forward ? .leading : .trailing
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: edgeIn == .trailing ? 24 : -24)),
                           removal: .opacity.combined(with: .offset(x: edgeOut == .leading ? -24 : 24)))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // The Connect step has its own skip ("Skip for now", its Continue button), so only
            // one skip control shows there.
            if flow.step != .done, flow.step != .connect {
                Button("Skip setup") { flow.skip() }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.row)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Closes this window. Breakpoint keeps running in the menu bar.")
            }
            Spacer()
            PageDots(count: OnboardingStep.allCases.count, current: flow.step.rawValue)
            Spacer()
            if flow.step != .welcome {
                PillButton("Back", role: .secondary, size: .small, keycap: "esc", showsKeycap: false) { flow.back() }
                    .accessibilityHint("Escape")
            }
            PillButton(continueTitle, role: continueRole, size: .small, keycap: "return", showsKeycap: false) {
                flow.advance()
            }
            .accessibilityHint("Return")
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }

    private var continueTitle: String {
        switch flow.step {
        case .welcome: return "Get started"
        case .connect where !state.integrations.contains(where: { $0.status.isInstalled }): return "Skip for now"
        case .done: return "Done"
        default: return "Continue"
        }
    }

    private var continueRole: PillButton.Role {
        flow.step == .connect && !state.integrations.contains(where: { $0.status.isInstalled }) ? .secondary : .mintPrimary
    }
}

/// Page dots: the current page is a short accent capsule, the others small dots (shape, not only
/// colour).
private struct PageDots: View {
    let count: Int
    let current: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Theme.Colors.accent(for: scheme) : Color.primary.opacity(0.2))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// Shared step layout: a title, one sentence, then the step's content.
struct OnboardingPage<Content: View>: View {
    let title: String
    let sentence: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(Theme.Typography.onboardingTitle)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(sentence)
                .font(Theme.Typography.onboardingSentence)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 8)
            content
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }
}
