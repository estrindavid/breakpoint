import SwiftUI
import BreakpointCore

// SPEC §3.1.

/// The nudge card: kind badge · title / subtitle · Start / Not now (SPEC §3.1). 410 × ~122 pt,
/// radius 28, padding 14.
///
/// - Row 1: 44 pt badge (Breakpoint gradient, white glyph) · 12 · title (20 semibold, 100%, the
///   offer: kind and length, question form) over the subtitle (15 regular, 60%, context).
/// - Row 2, 12 pt below and aligned to the text column: Start (primary) · Not now (secondary).
/// - Hover (after the pointer rests 300 ms): the × appears at the top-leading corner, the subtitle
///   cross-fades (0.2 s) to the why-now line in the same slot (one line, so the buttons never move
///   under the pointer; an unusually long agent name falls back to one clause per line), and the
///   hotkey keycaps inside the buttons come forward (they are always laid out, faint at rest, so
///   the buttons keep their size and place).
/// - Eye-rest auto-start: the title counts down with rolling digits ("20-sec eye rest in 7") while
///   a 2 pt white ring sweeps around the badge.
///
/// `forceHover` renders the hover state (snapshots). `revealed` is the live hover state.
public struct NudgeCardView: View {
    private let nudge: NudgeState
    private let actions: AppActions
    private let forceHover: Bool
    private let revealed: Bool
    private let onClose: (() -> Void)?
    private let traits = DesignTraits()

    public init(nudge: NudgeState, actions: AppActions, forceHover: Bool = false) {
        self.init(nudge: nudge, actions: actions, forceHover: forceHover, revealed: false, onClose: nil)
    }

    public init(nudge: NudgeState, actions: AppActions, forceHover: Bool = false, revealed: Bool,
                onClose: (() -> Void)?) {
        self.nudge = nudge
        self.actions = actions
        self.forceHover = forceHover
        self.revealed = revealed
        self.onClose = onClose
    }

    private var hover: Bool { revealed || forceHover }
    private var autoStarting: Bool { nudge.phase == .autoStartCard && nudge.autoStartRemaining != nil }
    /// The whole second the countdown shows (drives the digit roll).
    private var countdownSecond: Int { Int(max(0, nudge.autoStartRemaining ?? 0).rounded(.up)) }

    public var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: Theme.Layout.badgeToText) {
                KindBadge(kind: nudge.kind, ringProgress: autoStarting ? nudge.autoStartProgress : nil)
                    .animation(.linear(duration: BreakTiming.autoStartRingStep), value: nudge.autoStartProgress)
                VStack(alignment: .leading, spacing: 0) {
                    Text(nudge.title)
                        .font(Theme.Typography.nudgeTitle)
                        .foregroundStyle(Theme.Colors.white(.title))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(traits.reduceMotion ? .opacity : .numericText(countsDown: true))
                        .animation(traits.animation(.digitRoll), value: countdownSecond)
                        .animation(traits.animation(.subtitleSwap), value: autoStarting)
                    subtitle
                        .padding(.top, 2)
                    buttons
                        .padding(.top, Theme.Layout.rowGap)
                    if let hint = nudge.hint {
                        // The first real nudge only (SPEC §3.12).
                        HintLine(hint)
                            .padding(.top, Theme.Spacing.s)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: Theme.Layout.nudgeSize.width)
        .cornerCloseButton(visible: hover, action: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.nudgeAnnouncement(kind: nudge.kind, length: nudge.offer.length, hotkeysOn: false))
    }

    /// Subtitle and why-now share one slot and cross-fade; the why-now line may take two lines.
    private var subtitle: some View {
        ZStack(alignment: .topLeading) {
            if hover {
                // One line when it fits; otherwise one clause per line, never a ragged wrap.
                ViewThatFits(in: .horizontal) {
                    Text(nudge.whyNow).lineLimit(1)
                    Text(nudge.whyNow.replacingOccurrences(of: " · ", with: "\n"))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            } else {
                Text(nudge.subtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .transition(.opacity)
            }
        }
        .font(Theme.Typography.nudgeSubtitle)
        .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(traits.animation(.subtitleSwap), value: hover)
    }

    private var buttons: some View {
        HStack(spacing: Theme.Layout.buttonGap) {
            // The keycaps are always laid out and only come forward on hover, so the buttons keep
            // their size and place: nothing moves under the pointer as it arrives.
            PillButton("Start", role: .primary, keycap: HotKeyCombo.nudgeStart.display,
                       showsKeycap: nudge.hotkeysEnabled, keycapQuiet: !hover) {
                actions.acceptNudge()
            }
            PillButton("Not now", role: .secondary, keycap: HotKeyCombo.nudgeDismiss.display,
                       showsKeycap: nudge.hotkeysEnabled, keycapQuiet: !hover) {
                if nudge.phase == .autoStartCard { actions.cancelAutoStart() }
                actions.declineNudge()
            }
        }
    }
}
