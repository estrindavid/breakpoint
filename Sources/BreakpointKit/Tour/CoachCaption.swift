import SwiftUI
import BreakpointCore
import BreakpointRuntime

// The tour's coach lines (SPEC §3.12), in the pop-ups' language: dark glass, the neutral text
// steps, capsule buttons, keycaps. Each caption hangs from the surface it explains by a hairline
// pointer that ends in a small mint dot on that surface (the caption's one colour moment, with
// the current progress dot).

/// Where a caption's hairline points.
public enum CoachPointer: Equatable, Sendable {
    case none
    /// Up from the caption's top edge, at `x` points from its leading edge (`nil`: the centre).
    case up(x: CGFloat?)
}

/// A coach card: progress dots and Skip tour, a short title, one or two sentences, an optional
/// accessory (the mark's states), then keycaps and the buttons that move the tour on.
public struct CoachCaption: View {
    private let coach: TourCoach
    private let progress: (index: Int, count: Int)?
    private let pointer: CoachPointer
    private let keys: [KeyHint.Piece]
    private let accessory: AnyView?
    private let width: CGFloat
    private let onPrimary: () -> Void
    private let onSecondary: () -> Void
    private let onSkip: (() -> Void)?
    private let traits = DesignTraits()

    /// The caption's width when it stands alone (under the mark, in the stack).
    public static let width: CGFloat = 340
    /// The pointer's length, from the caption's top edge to the dot.
    public static let pointerLength: CGFloat = 18

    public init(_ coach: TourCoach, progress: (index: Int, count: Int)?, pointer: CoachPointer = .none,
                keys: [KeyHint.Piece] = [], accessory: AnyView? = nil, width: CGFloat = CoachCaption.width,
                onPrimary: @escaping () -> Void = {}, onSecondary: @escaping () -> Void = {},
                onSkip: (() -> Void)? = nil) {
        self.coach = coach
        self.progress = progress
        self.pointer = pointer
        self.keys = keys
        self.accessory = accessory
        self.width = width
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onSkip = onSkip
    }

    /// A step's caption as the app shows it, with its progress and Skip tour.
    public init(_ tour: TourPresentation, pointer: CoachPointer = .none, keys: [KeyHint.Piece] = [],
                accessory: AnyView? = nil, width: CGFloat = CoachCaption.width, actions: AppActions) {
        self.init(tour.coach, progress: tour.progressIndex.map { ($0, tour.progressCount) }, pointer: pointer,
                  keys: keys, accessory: accessory, width: width,
                  onPrimary: { actions.tour(.next) }, onSecondary: { actions.tour(.skip) },
                  onSkip: tour.step == .offer ? nil : { actions.tour(.skip) })
    }

    public var body: some View {
        VStack(spacing: 0) {
            if case .up(let x) = pointer {
                CoachStem(length: Self.pointerLength)
                    .frame(width: width, alignment: .leading)
                    .offset(x: (x ?? width / 2) - Theme.Layout.coachDot / 2)
                    .frame(width: width, alignment: .leading)
            }
            GlassCard(radius: Theme.Radius.coach, padding: Theme.Layout.cardPadding) {
                VStack(alignment: .leading, spacing: 0) {
                    if progress != nil || onSkip != nil {
                        HStack(spacing: Theme.Spacing.xs) {
                            if let progress { TourProgressDots(index: progress.index, count: progress.count) }
                            Spacer(minLength: 0)
                            if let onSkip { SkipTourButton(action: onSkip) }
                        }
                        .padding(.bottom, Theme.Spacing.xs)
                    }
                    if let title = coach.title {
                        Text(title)
                            .font(Theme.Typography.coachTitle)
                            .foregroundStyle(Theme.Colors.white(.title))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(coach.text)
                        .font(Theme.Typography.coach)
                        .foregroundStyle(Theme.Colors.white(.body))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, coach.title == nil ? 0 : 3)
                    if let accessory {
                        accessory.padding(.top, Theme.Spacing.s)
                    }
                    if !keys.isEmpty || coach.primary != nil || coach.secondary != nil {
                        HStack(spacing: Theme.Layout.buttonGap) {
                            if !keys.isEmpty { KeyHint(keys) }
                            Spacer(minLength: 0)
                            if let secondary = coach.secondary {
                                PillButton(secondary, role: .secondary, size: .small, action: onSecondary)
                            }
                            if let primary = coach.primary {
                                PillButton(primary, role: .primary, size: .small, action: onPrimary)
                            }
                        }
                        .padding(.top, Theme.Spacing.s)
                    }
                }
            }
            .frame(width: width)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progress.map { TourCopy.progress($0.index, of: $0.count) } ?? "Tour")
    }
}

/// "● ● ○ ○ ○ ○": done dots at 60%, the current one a short mint capsule, the rest at 20% (shape,
/// not only colour).
public struct TourProgressDots: View {
    let index: Int
    let count: Int
    private let traits = DesignTraits()

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 5) {
            ForEach(1...max(1, count), id: \.self) { dot in
                Capsule(style: .circular)
                    .fill(dot == index ? Theme.Colors.mint
                          : Color.white.opacity(dot < index ? traits.secondaryOpacity : (traits.increaseContrast ? 0.35 : 0.2)))
                    .frame(width: dot == index ? 14 : 5, height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TourCopy.progress(index, of: count))
    }
}

/// "Skip tour": quiet text, always there.
struct SkipTourButton: View {
    var font: Font = Theme.Typography.hint
    let action: () -> Void
    @State private var hovering = false
    private let traits = DesignTraits()

    var body: some View {
        Button(action: action) {
            Text("Skip tour")
                .font(font)
                .foregroundStyle(Color.white.opacity(hovering ? Theme.TextStep.body.opacity : traits.secondaryOpacity))
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Theme.Motion.hoverAnimation(inside, reduceMotion: traits.reduceMotion)) { hovering = inside }
        }
        .accessibilityHint("Ends the tour. Settings, General, can play it again.")
    }
}

/// The mark's states, drawn with the real mark: what each shape means.
public struct MarkLegend: View {
    private let traits = DesignTraits()

    public init() {}

    private static let items: [(BrandMark.Variant, BrandMark.Badge, String)] = [
        (.idle, .working, TourCopy.legendWorking),
        (.idle, .needsYou, TourCopy.legendNeedsYou),
        (.due, .none, TourCopy.legendDue),
        (.onBreak, .none, TourCopy.legendOnBreak),
        (.paused, .none, TourCopy.legendPaused),
    ]

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(Self.items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 5) {
                    BrandMark(item.0, badge: item.1)
                        .foregroundStyle(Theme.Colors.white(.body))
                        .frame(height: 15)
                    Text(item.2)
                        .font(Theme.Typography.hint)
                        .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.2)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.keycap * 2, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }
}

/// A coach line that hangs under the pop-up it explains, in the same panel (the sample nudge, the
/// sample resume card): it arrives after the card has opened and leaves with it.
public struct TourAttachedCaption: View {
    let tour: TourPresentation
    let phase: PopupPhase
    let actions: AppActions
    private let traits = DesignTraits()

    public init(tour: TourPresentation, phase: PopupPhase = .shown, actions: AppActions) {
        self.tour = tour
        self.phase = phase
        self.actions = actions
    }

    public var body: some View {
        // The nudge's keys are on its buttons now (faint until the pointer arrives); the coach line
        // names them instead of repeating them.
        CoachCaption(tour, pointer: .up(x: nil), actions: actions)
            // The pointer's dot sits on the card's bottom edge.
            .padding(.top, -Theme.Layout.coachDot / 2)
            // Faded as one picture: glass, rim and shadow never show through each other mid-fade.
            .compositingGroup()
            .opacity(phase == .shown ? 1 : 0)
            .offset(y: phase == .shown || traits.reduceMotion ? 0 : -4)
            .animation(phase == .shown ? traits.animation(.popupIn).delay(0.15) : traits.animation(.popupOutAction), value: phase)
    }
}

private struct PopupPhaseKey: EnvironmentKey {
    static let defaultValue: PopupPhase = .shown
}

extension EnvironmentValues {
    /// The phase of the pop-up a view is drawn in (an accessory under a card follows it).
    var popupPhase: PopupPhase {
        get { self[PopupPhaseKey.self] }
        set { self[PopupPhaseKey.self] = newValue }
    }
}

/// `TourAttachedCaption` under a card drawn by `CardPanelSurface` (which passes its phase down).
struct TourAttachedCaptionInCard: View {
    let tour: TourPresentation
    let actions: AppActions
    @Environment(\.popupPhase) private var phase

    var body: some View {
        TourAttachedCaption(tour: tour, phase: phase, actions: actions)
    }
}
