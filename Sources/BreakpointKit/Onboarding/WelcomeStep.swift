import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.10 step 1.

/// The mark arrives with its signature motion; a ≤ 6-word headline, one sentence, and
/// "No permissions needed."
public struct WelcomeStep: View {
    @State private var arrived = false
    @Environment(\.colorScheme) private var scheme
    private let traits = DesignTraits()

    public init() {}

    private var atRest: Bool { arrived || !traits.runsContinuousAnimations }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            BrandMark(.brand)
                .foregroundStyle(Theme.Colors.brandGradient)
                .frame(height: 64)
                .offset(x: atRest ? 0 : -Theme.Motion.markArrivalOffset)
                .opacity(atRest ? 1 : 0)
                .onAppear { withAnimation(traits.animation(.markArrival).delay(0.1)) { arrived = true } }
            Text("Breaks that wait for your agent")
                .font(Theme.Typography.onboardingHero)
                .multilineTextAlignment(.center)
                .padding(.top, 28)
                .accessibilityAddTraits(.isHeader)
            Text("Breakpoint offers a short stretch or eye rest while your coding agent works, and calls you back when it needs you.")
                .font(Theme.Typography.onboardingLead)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, 12)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Theme.Colors.accent(for: scheme))
                Text("No permissions needed.")
                    .font(Theme.Typography.bodySemibold)
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule(style: .circular)
                .fill(Theme.Colors.accent(for: scheme).opacity(scheme == .dark ? 0.14 : 0.10)))
            .padding(.top, 24)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
    }
}
