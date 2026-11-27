import BreakpointCore
import BreakpointRuntime
import Foundation

/// The update prompt (SPEC §2.11, §3.5), as `UpdateCardView` draws it: the resume card's shape,
/// 360 DIPs wide, padding 14.
///
/// - Row 1: the 28 DIP brand badge with an arrow (grey with "!" after a failure) · the title
///   (13 semibold).
/// - Row 2: what's new in one line, the step while installing ("Downloading…", 60%), or why it
///   stopped (12, 85%, up to two lines).
/// - Buttons, right-aligned, 28 DIPs: Later · Update (or Download page when this copy cannot
///   install itself); none while installing; Close · Open download page after a failure.
/// - An offer hides itself after 20 s (its lit edge is its timer); × on hover except while
///   installing.
@MainActor
enum PopupUpdateCard {
    static let width = Theme.Size.resumeCardWidth

    static func layout(_ canvas: Canvas?, _ controls: Controls?, _ card: UpdateCardContent, _ look: PopupCardLook,
                       _ handlers: PopupCardHandlers) -> SizeF {
        let padding = Theme.Size.cardPadding
        let badge = Theme.Size.sourceBadge
        let x = padding + badge + 10
        let column = width - x - padding - 4
        let failed: Bool
        let installing: Bool
        switch card.stage {
        case .offer: (failed, installing) = (false, false)
        case .installing: (failed, installing) = (false, true)
        case .failed: (failed, installing) = (true, false)
        }
        let titleStyle = TextStyle(size: 13, weight: 600)
        let detailStyle = TextStyle(size: 12, wrap: true)
        var y = padding + 3
        let rowHeight = badge - 6
        if let canvas {
            PopupBadge.draw(canvas, centre: PointF(x: padding + badge / 2, y: padding + badge / 2), diameter: badge,
                            symbol: failed ? "exclamationmark" : "arrow.down", tone: failed ? .neutral : .brand)
            let line = PopupText.lineHeight(titleStyle)
            canvas.text(PopupText.tail(card.title, titleStyle, column), at: PointF(x: x, y: y + (rowHeight - line) / 2),
                        style: titleStyle, Theme.Palette.white(.title))
        }
        y += rowHeight + 3
        let detail = PopupText.lines(card.detail, detailStyle, column, max: 2)
        let detailSize = Canvas.measure(detail, style: detailStyle, width: column)
        canvas?.text(detail, at: PointF(x: x, y: y), width: column, style: detailStyle,
                     Colour.white.opacity((installing ? Theme.TextStep.secondary : Theme.TextStep.body).opacity))
        y += detailSize.height
        y = max(y, padding + badge)
        if !installing {
            y += Theme.Spacing.s
            let buttons: [(String, PopupPill.Role, () -> Void)]
            if failed {
                buttons = [("Close", .secondary, handlers.close), ("Open download page", .primary, handlers.openPage)]
            } else if card.canInstall {
                buttons = [("Later", .secondary, handlers.close), ("Update", .primary, handlers.update)]
            } else {
                buttons = [("Later", .secondary, handlers.close), ("Download page", .primary, handlers.openPage)]
            }
            // Right-aligned, drawn left to right so Tab goes in reading order.
            let widths = buttons.map { PopupPill.width($0.0, role: $0.1, size: .small) }
            var left = width - padding - widths.reduce(0, +) - Float(buttons.count - 1) * 8
            for (index, button) in buttons.enumerated() {
                PopupPill.draw(canvas, controls, id: "button\(index)", at: PointF(x: left, y: y), button.0, role: button.1,
                               size: .small, action: button.2)
                left += widths[index] + 8
            }
            y += Theme.Size.smallButtonHeight
        }
        PopupCardView.closeButton(canvas, controls, visible: look.hovering && !installing, action: handlers.close)
        return SizeF(width: width, height: y + padding)
    }
}
