import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.12, the popover step: the tour opens the popover and names its parts one at a time. The
// part being named keeps its full strength on a soft lit plate, with the coach dot at its leading
// edge; the rest of the popover steps back. The coach line is a strip at the bottom of the popover, led by the
// same dot, with Next (Return) and Skip tour.

extension View {
    /// Spotlight for the tour: `part` is lit when the tour names it, the rest steps back; `nil`
    /// parts (agents, footer) only step back. No effect outside the tour.
    func tourSpotlight(_ part: TourPopoverPart?, tour: TourPresentation?) -> some View {
        modifier(TourSpotlight(part: part, tour: tour))
    }
}

private struct TourSpotlight: ViewModifier {
    let part: TourPopoverPart?
    let tour: TourPresentation?
    private let traits = DesignTraits()

    private var lit: Bool { tour != nil && part != nil && tour?.popoverPart == part }

    func body(content: Content) -> some View {
        content
            // Stepped back, not washed out: the parts stay legible, only quieter.
            .opacity(tour == nil || lit ? 1 : (traits.increaseContrast ? 0.65 : 0.45))
            .saturation(tour == nil || lit ? 1 : 0.5)
            // The part named sits on a soft lit plate, the strip's own fill and rim.
            .background {
                if lit {
                    RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                            .strokeBorder(Color.white.opacity(traits.increaseContrast ? 0.30 : 0.10), lineWidth: 1))
                        .padding(-6)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .leading) {
                if lit {
                    CoachDot()
                        .offset(x: -Theme.Spacing.m / 2 - Theme.Layout.coachDot / 2)
                        .transition(.opacity)
                }
            }
    }
}

/// The coach line inside the popover: progress and Skip tour, then the coach dot, the part's
/// sentence and Next (Return).
public struct TourPopoverStrip: View {
    let tour: TourPresentation
    let actions: AppActions
    private let traits = DesignTraits()

    public init(tour: TourPresentation, actions: AppActions) {
        self.tour = tour
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                if let index = tour.progressIndex { TourProgressDots(index: index, count: tour.progressCount) }
                Spacer(minLength: 0)
                SkipTourButton { actions.tour(.skip) }
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                CoachDot()
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(tour.coach.text)
                    .font(Theme.Typography.coach)
                    .foregroundStyle(Theme.Colors.white(.body))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(tour.popoverPart)
                    .transition(.opacity)
            }
            HStack {
                Spacer(minLength: 0)
                PillButton(tour.coach.primary ?? "Next", role: .primary, size: .small, keycap: "return",
                           keycapQuiet: true) { actions.tour(.next) }
                    .fixedSize()
                    .accessibilityHint("Return")
            }
        }
        .padding(Theme.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
            .strokeBorder(Color.white.opacity(traits.increaseContrast ? 0.30 : 0.10), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TourCopy.progress(tour.progressIndex ?? 5, of: tour.progressCount))
    }
}
