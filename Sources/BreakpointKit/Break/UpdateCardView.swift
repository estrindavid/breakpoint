import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §2.11, §3.5 update prompt.

/// "A new version exists", calmly. The resume card's shape: 360 pt wide, radius 28, padding 14.
///
/// - Row 1: the brand badge 28 pt with an arrow (the one colour moment: it is Breakpoint's own
///   news; grey with "!" after a failure) · the title, 13 pt semibold.
/// - Row 2: what's new in one line from the release, the step while installing ("Downloading…"),
///   or why it stopped (12 pt 85%, up to two lines).
/// - Buttons, right-aligned, 28 pt:
///   - offer: Later (secondary) · Update (primary; downloads, verifies, replaces and reopens), or
///     Download page when this copy cannot install itself;
///   - installing: none (the card stays until Breakpoint reopens);
///   - failed: Close · Open download page.
/// - An offer hides itself after 20 s (hover holds it; its lit edge is its timer). Later, × or the
///   timeout put the question off for three days.
public struct UpdateCardView: View {
    private let card: UpdateCardContent
    private let hovering: Bool
    private let timeRim: TimeRimSource?
    private let onUpdate: () -> Void
    private let onOpenPage: () -> Void
    private let onLater: () -> Void

    public init(card: UpdateCardContent, hovering: Bool = false, timeRim: TimeRimSource? = nil,
                onUpdate: @escaping () -> Void, onOpenPage: @escaping () -> Void, onLater: @escaping () -> Void) {
        self.card = card
        self.hovering = hovering
        self.timeRim = timeRim
        self.onUpdate = onUpdate
        self.onOpenPage = onOpenPage
        self.onLater = onLater
    }

    private var failed: Bool {
        if case .failed = card.stage { return true }
        return false
    }

    private var installing: Bool {
        if case .installing = card.stage { return true }
        return false
    }

    public var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    KindBadge(symbol: failed ? "exclamationmark" : "arrow.down", tone: failed ? .neutral : .brand,
                              diameter: Theme.Layout.sourceBadge)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title)
                            .font(Theme.Typography.bodySemibold)
                            .foregroundStyle(Theme.Colors.white(.title))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minHeight: Theme.Layout.sourceBadge - 6, alignment: .center)
                            .padding(.top, 3)
                        Text(card.detail)
                            .font(Theme.Typography.detail)
                            .foregroundStyle(Theme.Colors.white(installing ? .secondary : .body))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.trailing, 4)
                    Spacer(minLength: 0)
                }
                if !installing {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if failed {
                            PillButton("Close", role: .secondary, size: .small, showsKeycap: false, action: onLater)
                            PillButton("Open download page", role: .primary, size: .small, showsKeycap: false, action: onOpenPage)
                        } else {
                            PillButton("Later", role: .secondary, size: .small, showsKeycap: false, action: onLater)
                            if card.canInstall {
                                PillButton("Update", role: .primary, size: .small, showsKeycap: false, action: onUpdate)
                                    .accessibilityHint("Downloads the new version, checks its signature, and reopens Breakpoint")
                            } else {
                                PillButton("Download page", role: .primary, size: .small, showsKeycap: false, action: onOpenPage)
                                    .accessibilityHint("Opens the release page in your browser")
                            }
                        }
                    }
                    .padding(.top, Theme.Spacing.s)
                }
            }
        }
        .frame(width: Theme.Layout.resumeCardWidth)
        .timeRim(timeRim, cornerRadius: Theme.Radius.card)
        .cornerCloseButton(visible: hovering && !installing, action: installing ? nil : onLater)
    }
}
