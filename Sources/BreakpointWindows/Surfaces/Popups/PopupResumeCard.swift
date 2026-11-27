import BreakpointCore
import BreakpointRuntime
import Foundation

/// The resume card (SPEC §3.5), as `ResumeCardView` draws it: "what happened while I was away",
/// at a glance. 360 DIPs wide, padding 14.
///
/// - Row 1: the 28 DIP source badge (indigo; amber when anything needs you; ✓ finished, !
///   failed, a raised hand when it needs you) · the one strong line (13 semibold) · on one row
///   only, the project folder (12, 60%, middle-truncated) at the trailing end. On hover, while
///   the dismiss shortcut reaches the card, its keycap joins the folder (or takes its place).
/// - One row: the supporting line (12, 85%, one line), a command or file in monospaced type that
///   truncates first.
/// - Several rows: name · folder with a short status on the right, at most 3, then "+N more".
/// - The first real resume card's hint at the bottom.
/// - A click anywhere dismisses; the × on hover; the lit edge is its timer while it hides itself.
@MainActor
enum PopupResumeCard {
    static let width = Theme.Size.resumeCardWidth
    static let maxRows = 3
    static let titleStyle = TextStyle(size: 13, weight: 600)
    static let detailStyle = TextStyle(size: 12)
    static let rowNameStyle = TextStyle(size: 12, weight: 600)
    static let codeStyle = TextStyle(size: 12, family: "Cascadia Mono")

    static func badgeSymbol(_ card: ResumeCardContent) -> String {
        if card.needsYou { return "hand.raised.fill" }
        if card.items.count == 1, card.items[0].facts.failed { return "exclamationmark" }
        return "checkmark"
    }

    static func layout(_ canvas: Canvas?, _ controls: Controls?, _ card: ResumeCardContent, _ look: PopupCardLook,
                       _ handlers: PopupCardHandlers) -> SizeF {
        let padding = Theme.Size.cardPadding
        let badge = Theme.Size.sourceBadge
        let x = padding + badge + 10
        let column = width - x - padding - 4
        let body = Colour.white.opacity(Theme.TextStep.body.opacity)
        let secondary = Colour.white.opacity(Theme.TextStep.secondary.opacity)

        // The whole card dismisses on click; the controls drawn after it take their own clicks.
        if let controls { controls.region("card", RectF(x: 0, y: 0, width: width, height: 2000), action: handlers.close) }

        var y = padding + 3
        // Row 1, centred on the badge.
        let rowHeight = badge - 6
        titleRow(canvas, card, look, x: x, y: y, width: column, height: rowHeight)
        y += rowHeight

        if card.items.count == 1 {
            if let detail = card.detail {
                y += 3
                let line = PopupText.lineHeight(detailStyle)
                if let canvas { detailLine(canvas, detail, at: PointF(x: x, y: y), width: column, body) }
                y += line
            }
        } else {
            y += 3 + 1
            let line = PopupText.lineHeight(detailStyle)
            for (index, item) in card.items.prefix(maxRows).enumerated() {
                if index > 0 { y += 4 }
                if let canvas { severalRow(canvas, item.facts, at: PointF(x: x, y: y), width: column, body: body, secondary: secondary) }
                y += line
            }
            if card.items.count > maxRows {
                y += 4
                canvas?.text("+\(card.items.count - maxRows) more", at: PointF(x: x, y: y), style: detailStyle, secondary)
                y += line
            }
        }

        if let hint = card.hint {
            y += 3 + Theme.Spacing.xs
            if let canvas {
                y += HintLine.draw(canvas, at: PointF(x: x, y: y), width: column, text: hint)
            } else {
                y += HintLine.height(width: column, text: hint)
            }
        }
        let height = max(padding + badge, y) + padding

        if let canvas {
            PopupBadge.draw(canvas, centre: PointF(x: padding + badge / 2, y: padding + badge / 2), diameter: badge,
                            symbol: badgeSymbol(card), tone: card.needsYou ? .needsYou : .agent)
        }
        PopupCardView.closeButton(canvas, controls, visible: look.hovering, action: handlers.close)
        return SizeF(width: width, height: height)
    }

    /// The strong line, then the folder and the keycap at the trailing end.
    private static func titleRow(_ canvas: Canvas?, _ card: ResumeCardContent, _ look: PopupCardLook,
                                 x: Float, y: Float, width: Float, height: Float) {
        guard let canvas else { return }
        let gap = Theme.Spacing.xs
        let folder = card.items.count == 1 ? card.items[0].facts.folder : nil
        let key = look.hovering ? look.dismissKey : nil
        let keyWidth = key.map { PopupKeycap.width($0, compact: false) } ?? 0
        let titleWidth = min(Canvas.measure(card.title, style: titleStyle).width, width - (key == nil ? 0 : keyWidth + gap))
        let title = PopupText.tail(card.title, titleStyle, titleWidth.rounded(.up))
        let line = PopupText.lineHeight(titleStyle)
        canvas.text(title, at: PointF(x: x, y: y + (height - line) / 2), style: titleStyle, Theme.Palette.white(.title))
        var trailing = x + width
        if let key {
            let cap = RectF(x: trailing - keyWidth, y: y + (height - 18) / 2, width: keyWidth, height: 18)
            PopupKeycap.draw(canvas, cap, key, compact: false)
            trailing = cap.minX - gap
        }
        guard let folder else { return }
        let room = trailing - (x + titleWidth + gap)
        let folderWidth = Canvas.measure(folder, style: detailStyle).width
        // With the keycap there, the folder shows only when it fits whole (`ViewThatFits`).
        if key != nil, folderWidth > room { return }
        guard room >= 24 else { return }
        let text = PopupText.middle(folder, detailStyle, room)
        let size = Canvas.measure(text, style: detailStyle)
        let baseline = y + (height - line) / 2 + (line - size.height) + 0.5
        canvas.text(text, at: PointF(x: trailing - size.width, y: baseline), style: detailStyle,
                    Colour.white.opacity(Theme.TextStep.secondary.opacity))
    }

    /// Plain text, or text then a command, file or host in monospaced type (the code truncates
    /// first, so "Wants to run" always shows).
    private static func detailLine(_ canvas: Canvas, _ line: ResumeLine, at origin: PointF, width: Float, _ colour: Colour) {
        guard let code = line.code else {
            canvas.text(PopupText.tail(line.text, detailStyle, width), at: origin, style: detailStyle, colour)
            return
        }
        let textWidth = min(Canvas.measure(line.text, style: detailStyle).width, width)
        let text = PopupText.tail(line.text, detailStyle, textWidth.rounded(.up))
        canvas.text(text, at: origin, style: detailStyle, colour)
        let room = width - textWidth - 4
        guard room > 24 else { return }
        let codeText = PopupText.tail(code, codeStyle, room)
        let offset = PopupText.lineHeight(detailStyle) - PopupText.lineHeight(codeStyle)
        canvas.text(codeText, at: PointF(x: origin.x + textWidth + 4, y: origin.y + offset / 2), style: codeStyle, colour)
    }

    /// One row of several: name · folder, the short status at the trailing end.
    private static func severalRow(_ canvas: Canvas, _ facts: ResumeFacts, at origin: PointF, width: Float,
                                   body: Colour, secondary: Colour) {
        let status = facts.shortStatus
        var statusStyle = detailStyle
        statusStyle.monospacedDigits = true
        let statusWidth = Canvas.measure(status, style: statusStyle).width
        canvas.text(status, at: PointF(x: origin.x + width - statusWidth, y: origin.y), style: statusStyle, secondary)
        let room = width - statusWidth - 8
        let nameWidth = min(Canvas.measure(facts.name, style: rowNameStyle).width, room)
        let name = PopupText.tail(facts.name, rowNameStyle, nameWidth.rounded(.up))
        canvas.text(name, at: origin, style: rowNameStyle, body)
        guard let folder = facts.folder else { return }
        let folderRoom = room - nameWidth
        guard folderRoom > 30 else { return }
        let text = PopupText.middle(" · \(folder)", detailStyle, folderRoom)
        canvas.text(text, at: PointF(x: origin.x + nameWidth, y: origin.y), style: detailStyle, secondary)
    }
}
