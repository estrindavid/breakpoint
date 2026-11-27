import BreakpointCore
import BreakpointRuntime
import Foundation

/// The wind-down card (SPEC §3.6), as `WindDownCardView` draws it: 410 DIPs wide, padding 20.
///
/// - Asking: "It's 23:20." (17 semibold) over "You planned to stop at 23:00." (13, 85%), then
///   right-aligned 28 DIP buttons: "15 more minutes" (a secondary capsule labelled with its hold,
///   "Hold 3 s"; held, a 20% mint fill sweeps across at linear speed) · Wrap up (mint).
/// - Note: "Where you left off", one monospaced line per open session on an inset panel (or "No
///   open agent sessions."), then Done (Esc keycap once the card has the keyboard) · Copy note
///   (mint; "Copied" with a check for 1.6 s).
/// No badge, so the mint button is the colour moment.
@MainActor
enum PopupWindDownCard {
    static let width = Theme.Size.windDownWidth
    static let padding = Theme.Size.windDownPadding
    static let holdID = "hold"
    static let noteStyle = TextStyle(size: 12, family: "Cascadia Mono")

    static func layout(_ canvas: Canvas?, _ controls: Controls?, _ card: WindDownCardContent, _ look: PopupCardLook,
                       _ handlers: PopupCardHandlers) -> SizeF {
        let inner = width - 2 * padding
        var y = padding
        let titleStyle = Theme.Typography.windDownTitle
        switch card.phase {
        case .asking:
            let title = Copy.windDownTitle(now: card.now)
            canvas?.text(title, at: PointF(x: padding, y: y), style: titleStyle, Theme.Palette.white(.title))
            y += PopupText.lineHeight(titleStyle) + 4
            let body = Copy.windDownBody(stopTime: card.stopTime, on: card.now)
            let bodyStyle = Theme.Typography.bodyWrapped
            let bodySize = Canvas.measure(body, style: bodyStyle, width: inner)
            canvas?.text(body, at: PointF(x: padding, y: y), width: inner, style: bodyStyle,
                         Colour.white.opacity(Theme.TextStep.body.opacity))
            y += bodySize.height + Theme.Spacing.m
            let wrap = PopupPill.width("Wrap up", role: .mint, size: .small)
            let wrapX = width - padding - wrap
            let holdWidth = holdCapsuleWidth(card.holdDuration)
            holdCapsule(canvas, controls, RectF(x: wrapX - 8 - holdWidth, y: y, width: holdWidth, height: Theme.Size.smallButtonHeight),
                        hold: card.holdDuration, look: look, action: handlers.holdClick)
            PopupPill.draw(canvas, controls, id: "wrapUp", at: PointF(x: wrapX, y: y), "Wrap up", role: .mint, size: .small,
                           action: handlers.wrapUp)
            y += Theme.Size.smallButtonHeight
        case .note(let lines):
            canvas?.text("Where you left off", at: PointF(x: padding, y: y), style: titleStyle, Theme.Palette.white(.title))
            y += PopupText.lineHeight(titleStyle) + Theme.Spacing.s
            let line = PopupText.lineHeight(noteStyle)
            let rows = max(1, lines.count)
            let panel = RectF(x: padding, y: y, width: inner, height: 20 + Float(rows) * line + Float(rows - 1) * 4)
            if let canvas {
                canvas.fill(panel, radius: 6, Colour.white.opacity(0.06))
                var ty = panel.y + 10
                if lines.isEmpty {
                    canvas.text("No open agent sessions.", at: PointF(x: panel.x + 12, y: ty), style: noteStyle,
                                Colour.white.opacity(Theme.TextStep.secondary.opacity))
                }
                for text in lines {
                    canvas.text(PopupText.tail(text, noteStyle, inner - 24), at: PointF(x: panel.x + 12, y: ty), style: noteStyle,
                                Colour.white.opacity(Theme.TextStep.body.opacity))
                    ty += line + 4
                }
            }
            y += panel.height + Theme.Spacing.m
            let copyTitle = look.copied ? "Copied" : "Copy note"
            let copy = PopupPill.width(copyTitle, role: .mint, size: .small, icon: look.copied)
            let copyX = width - padding - copy
            let doneKey = look.isKey ? "Esc" : nil
            let done = PopupPill.width("Done", role: .secondary, size: .small, keycap: doneKey)
            PopupPill.draw(canvas, controls, id: "done", at: PointF(x: copyX - 8 - done, y: y), "Done", role: .secondary,
                           size: .small, keycap: doneKey, action: handlers.close)
            PopupPill.draw(canvas, controls, id: "copy", at: PointF(x: copyX, y: y), copyTitle, role: .mint, size: .small,
                           icon: look.copied ? "checkmark" : nil, action: handlers.copyNote)
            y += Theme.Size.smallButtonHeight
        }
        return SizeF(width: width, height: y + padding)
    }

    static let holdTitleStyle = TextStyle(size: 13, weight: 600)
    static let holdHintStyle = TextStyle(size: 11, monospacedDigits: true)

    static func holdCapsuleWidth(_ hold: TimeInterval) -> Float {
        var width = Canvas.measure("15 more minutes", style: holdTitleStyle).width
        if hold > 0 { width += 6 + Canvas.measure(Copy.windDownHold(hold), style: holdHintStyle).width }
        return (width + 24).rounded(.up)
    }

    /// "15 more minutes" as a press-and-hold capsule (`HoldCapsule`).
    private static func holdCapsule(_ canvas: Canvas?, _ controls: Controls?, _ rect: RectF, hold: TimeInterval,
                                    look: PopupCardLook, action: @escaping () -> Void) {
        guard let canvas else { return }
        let hot = controls?.isHovered(holdID) ?? false
        let radius = rect.height / 2
        let pressed = look.holding && !Appearance.reduceMotion
        canvas.transformed(scale: pressed ? 0.97 : 1, about: PointF(x: rect.midX, y: rect.midY)) {
            canvas.clipped(to: rect, radius: radius) {
                if hot { canvas.fill(rect, Colour.white.opacity(0.06)) }
                let fill = Float(min(1, max(0, look.holdProgress)))
                if fill > 0 {
                    canvas.fill(RectF(x: rect.x, y: rect.y, width: rect.width * fill, height: rect.height), Theme.Palette.mint.opacity(0.20))
                }
            }
            canvas.stroke(rect.insetBy(0.5, 0.5), radius: radius - 0.5, width: 1,
                          Colour.white.opacity(Appearance.highContrast ? 0.30 : Theme.TextStep.outline.opacity))
            let title = "15 more minutes"
            let titleSize = Canvas.measure(title, style: holdTitleStyle)
            let hintText = Copy.windDownHold(hold)
            let hintSize = hold > 0 ? Canvas.measure(hintText, style: holdHintStyle) : SizeF(width: 0, height: 0)
            let total = titleSize.width + (hold > 0 ? 6 + hintSize.width : 0)
            let x = rect.midX - total / 2
            canvas.text(title, at: PointF(x: x, y: rect.midY - titleSize.height / 2), style: holdTitleStyle,
                        Colour.white.opacity(Theme.TextStep.label.opacity))
            if hold > 0 {
                canvas.text(hintText, at: PointF(x: x + titleSize.width + 6, y: rect.midY - hintSize.height / 2 + 0.5),
                            style: holdHintStyle, Colour.white.opacity(Theme.TextStep.secondary.opacity))
            }
        }
        if let controls {
            PopupFocus.ring(canvas, controls, id: holdID, rect, radius: radius)
            controls.region(holdID, rect, focusable: true, action: action)
        }
    }
}
