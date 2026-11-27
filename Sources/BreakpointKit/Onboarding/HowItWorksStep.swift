import SwiftUI
import BreakpointCore

// SPEC §3.10 step 2.

/// A looping 6 s demo built from the real components (the nudge at 60% scale, the overlay laid out
/// on a 1280 × 640 display and shrunk to the stage): nudge over a mock terminal →
/// Start → overlay entrance → agent chip turns amber "Claude needs you" → back. Reduce Motion:
/// three stills with captions.
public struct HowItWorksStep: View {
    /// The moments of the demo, in order.
    public enum Phase: Int, CaseIterable, Sendable {
        /// The agent starts working; only the terminal.
        case working
        /// The nudge offers a stretch.
        case nudge
        /// Start pressed; the break takes the screen.
        case onBreak
        /// The agent needs you: the chip turns amber.
        case needsYou
        /// Back at the terminal.
        case back

        /// When the phase starts within the 6 s loop.
        var start: TimeInterval {
            switch self {
            case .working: return 0
            case .nudge: return 0.5
            case .onBreak: return 2.1
            case .needsYou: return 3.7
            case .back: return 4.9
            }
        }

        static func at(_ t: TimeInterval) -> Phase {
            allCases.last { $0.start <= t } ?? .working
        }

        var caption: String {
            switch self {
            case .working, .nudge: return "When your agent starts working, a small offer appears."
            case .onBreak: return "Start it, and the break takes the screen for a moment."
            case .needsYou: return "If your agent needs you, a soft chime calls you back."
            case .back: return "Back to work, right where you left off."
            }
        }
    }

    @ObservedObject var state: AppState
    private let frozenPhase: Phase?
    private let traits = DesignTraits()

    public init(state: AppState) {
        self.init(state: state, frozenPhase: nil)
    }

    init(state: AppState, frozenPhase: Phase?) {
        self.state = state
        self.frozenPhase = frozenPhase
    }

    static let loop: TimeInterval = 6

    public var body: some View {
        OnboardingPage(title: "How it works",
                       sentence: "Breaks come at natural pauses, like the minutes while your agent works.") {
            if traits.reduceMotion {
                stills
            } else if let frozenPhase {
                demo(frozenPhase)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.loop)
                    demo(Phase.at(t))
                }
            }
        }
    }

    private func demo(_ phase: Phase) -> some View {
        VStack(spacing: 14) {
            DemoStage(phase: phase, now: state.now)
                .frame(width: 472, height: 236)
            Text(phase.caption)
                .font(Theme.Typography.row)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(height: 20, alignment: .top)
                .id(phase.caption)
                .transition(.opacity)
                .animation(traits.animation(.subtitleSwap), value: phase.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Demonstration: a break offer appears while your agent works, the break takes the screen, and a chime calls you back when the agent needs you.")
    }

    /// Reduce Motion: three stills with captions.
    private var stills: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach([Phase.nudge, .onBreak, .needsYou], id: \.self) { phase in
                VStack(spacing: 8) {
                    DemoStage(phase: phase, now: state.now)
                        .frame(width: 472, height: 236)
                        .scaleEffect(0.32, anchor: .topLeading)
                        .frame(width: 472 * 0.32, height: 236 * 0.32, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(Self.stillCaption(phase))
                        .font(Theme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 472 * 0.32)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func stillCaption(_ phase: Phase) -> String {
        switch phase {
        case .nudge: return "1. An offer appears while your agent works."
        case .onBreak: return "2. Start it, and the break takes the screen."
        default: return "3. A chime calls you back when it needs you."
        }
    }
}

/// A miniature desktop with a terminal, and the real nudge card and break overlay on top.
struct DemoStage: View {
    let phase: HowItWorksStep.Phase
    let now: Date
    private let traits = DesignTraits()

    private static let scale = Theme.Layout.onboardingDemoScale
    private static let stage = CGSize(width: 472, height: 236)
    /// The display the overlay is laid out on (the stage's 2:1 shape), and its scale on the stage.
    private static let overlayDisplay = CGSize(width: 1280, height: 640)
    private static var overlayScale: CGFloat { stage.width / overlayDisplay.width }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0x24344F), Color(hex: 0x2F5566), Color(hex: 0x4F7F84)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            MockTerminal(phase: phase)
                .frame(width: 330, height: 168)
                .offset(y: 50)
                .blur(radius: phase == .onBreak || phase == .needsYou ? 6 : 0)
            // Menu bar: the frontmost app's menus on the left, Breakpoint's mark on the right.
            HStack(spacing: 9) {
                Text("Terminal").fontWeight(.semibold)
                ForEach(["Shell", "Edit", "View", "Window"], id: \.self) { Text($0) }
                Spacer()
                Image(nsImage: BrandMark.templateImage(phase == .onBreak || phase == .needsYou ? .onBreak : .idle,
                                                       badge: phase == .needsYou ? .needsYou : (phase == .back ? .needsYou : .working)))
                    .renderingMode(.template)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .scaleEffect(0.75)
            }
            .font(.system(size: 8))
            .foregroundStyle(Color.white.opacity(0.8))
            .padding(.horizontal, 10)
            .frame(height: 16)
            .background(Color.black.opacity(0.25))

            if phase == .nudge {
                NudgeCardView(nudge: Self.nudge(now: now), actions: .noop)
                    .fixedSize()
                    .scaleEffect(Self.scale, anchor: .top)
                    .padding(.top, 22)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -8)),
                                            removal: .opacity.combined(with: .scale(scale: 1.04))))
            }
            if phase == .onBreak || phase == .needsYou {
                // The overlay is a whole display: it is laid out at a display's size and shrunk to
                // the stage (at the nudge's 60% the stage would be a 393 pt-tall display, too short
                // for the routine's ring, which would run into the controls).
                BreakOverlayView(activeBreak: Self.activeBreak(now: now, needsYou: phase == .needsYou), actions: .noop,
                                 displaySize: Self.overlayDisplay, now: now)
                    .frame(width: Self.overlayDisplay.width, height: Self.overlayDisplay.height)
                    .scaleEffect(Self.overlayScale)
                    .frame(width: Self.stage.width, height: Self.stage.height)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.stage.width, height: Self.stage.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .glassRendering(.opaque)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .animation(traits.reduceMotion ? .easeInOut(duration: Theme.Motion.reduceMotionFade) : Theme.Motion.demoScene, value: phase)
    }

    static func nudge(now: Date) -> NudgeState {
        PreviewData(now: now).nudge(kind: .move)
    }

    static func activeBreak(now: Date, needsYou: Bool) -> ActiveBreakState {
        var active = PreviewData(now: now).activeBreak(kind: .move, progress: 0.3)
        if needsYou {
            active.needsYou = true
            active.agentChip = .needsYou(agent: "Claude")
        }
        return active
    }
}

/// A terminal window with an agent session in it (drawn, not a screenshot).
private struct MockTerminal: View {
    let phase: HowItWorksStep.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.25)).frame(width: 7, height: 7) }
                Spacer()
                Text("breakpoint — zsh").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.white.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 20)
            VStack(alignment: .leading, spacing: 5) {
                line("~/code/breakpoint", opacity: 0.45)
                line("› fix the login redirect after OAuth callback", opacity: 0.9)
                if phase == .back {
                    line("Allow edit to auth/callback.swift? (y/n)", opacity: 1, tint: Theme.Colors.amber)
                } else {
                    line("✻ Working… reading auth/callback.swift", opacity: 0.6, tint: Theme.Colors.indigo)
                }
                line("", opacity: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0x0E1116).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }

    private func line(_ text: String, opacity: Double, tint: Color = .white) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(tint.opacity(opacity))
            .lineLimit(1)
    }
}
