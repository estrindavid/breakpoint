import SwiftUI
import BreakpointCore

// SPEC §3.5 resume card.

/// "What happened while I was away", at a glance. 360 pt wide, radius 28, padding 14.
///
/// - Row 1: source badge 28 pt (indigo; amber if anything needs you) · the one strong line, 13 pt
///   semibold ("Claude finished · ran 6 min", "Claude hit the usage limit", "swift failed after
///   4 min") · on one row only, the project folder, 12 pt 60%, trailing and middle-truncated.
/// - Row 2 (one row only, optional): the one supporting line, 12 pt 85%, one line, tail-truncated:
///   the agent's last message, what a waiting agent asks for ("Wants to run `npm install`", the
///   command in monospaced type), the prompt snippet, or counts ("7 edits · 12 commands").
/// - Several rows: the title says how many ("3 agents finished", "Claude needs you"), then rows of
///   name · folder with a short status on the right ("6 min", "usage limit", "needs you"), needs
///   you first; max 3, then "+N more".
/// - While it hides itself, its lit edge is its timer (`timeRim`, §3.5).
/// - Click anywhere dismisses; × on hover. While the dismiss hotkey is live (`dismissKey`), hover
///   also shows it as a keycap on row 1.
///
/// One colour moment: the badge. Its glyph says what happened (✓ finished, ! stopped with an error
/// or a command failed, raised hand needs you) so the state never rests on colour alone.
public struct ResumeCardView: View {
    private let card: ResumeCardContent
    private let hovering: Bool
    private let dismissKey: String?
    private let timeRim: TimeRimSource?
    private let onDismiss: () -> Void

    public init(card: ResumeCardContent, hovering: Bool = false, dismissKey: String? = nil,
                timeRim: TimeRimSource? = nil, onDismiss: @escaping () -> Void) {
        self.card = card
        self.hovering = hovering
        self.dismissKey = dismissKey
        self.timeRim = timeRim
        self.onDismiss = onDismiss
    }

    static let maxRows = 3

    public var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 10) {
                KindBadge(symbol: badgeSymbol, tone: card.needsYou ? .needsYou : .agent, diameter: Theme.Layout.sourceBadge)
                VStack(alignment: .leading, spacing: 3) {
                    titleRow
                        // Centre the title line on the 28 pt badge.
                        .frame(minHeight: Theme.Layout.sourceBadge - 6, alignment: .center)
                        .padding(.top, 3)
                    if card.items.count == 1 {
                        if let detail = card.detail { DetailLine(line: detail) }
                    } else {
                        several
                    }
                    if let hint = card.hint {
                        // The first real resume card only (SPEC §3.12).
                        HintLine(hint)
                            .padding(.top, Theme.Spacing.xs)
                    }
                }
                .padding(.trailing, 4)
                Spacer(minLength: 0)
            }
        }
        .frame(width: Theme.Layout.resumeCardWidth)
        .timeRim(timeRim, cornerRadius: Theme.Radius.card)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .cornerCloseButton(visible: hovering, action: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismisses")
    }

    private var badgeSymbol: String {
        if card.needsYou { return "hand.raised.fill" }
        if card.items.count == 1, card.items[0].facts.failed { return "exclamationmark" }
        return "checkmark"
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Text(card.title)
                .font(Theme.Typography.bodySemibold)
                .foregroundStyle(Theme.Colors.white(.title))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 0)
            let folder = card.items.count == 1 ? card.items[0].facts.folder : nil
            if hovering, let dismissKey {
                // The keycap joins the folder when both fit, and takes its place when they do not.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        if let folder { folderText(folder).fixedSize() }
                        Keycap(dismissKey)
                    }
                    Keycap(dismissKey)
                }
            } else if let folder {
                folderText(folder)
            }
        }
    }

    private func folderText(_ folder: String) -> some View {
        Text(folder)
            .font(Theme.Typography.detail)
            .foregroundStyle(Theme.Colors.white(.secondary))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var several: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(card.items.prefix(Self.maxRows))) { item in
                HStack(spacing: 6) {
                    HStack(spacing: 0) {
                        Text(item.facts.name)
                            .foregroundStyle(Theme.Colors.white(.body))
                            .fontWeight(.semibold)
                        if let folder = item.facts.folder {
                            Text(" · \(folder)")
                                .foregroundStyle(Theme.Colors.white(.secondary))
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(item.facts.shortStatus)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.white(.secondary))
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(Theme.Typography.detail)
            }
            if card.items.count > Self.maxRows {
                Text("+\(card.items.count - Self.maxRows) more")
                    .font(Theme.Typography.detail)
                    .foregroundStyle(Theme.Colors.white(.secondary))
            }
        }
        .padding(.top, 1)
    }
}

/// The supporting line: plain text, or text followed by a command, file or host in monospaced type
/// (the code part truncates first, so "Wants to run" always shows).
private struct DetailLine: View {
    let line: ResumeLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(line.text)
                .font(Theme.Typography.detail)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(line.code == nil ? 0 : 1)
            if let code = line.code {
                Text(code)
                    .font(Theme.Typography.note)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(Theme.Colors.white(.body))
    }
}
