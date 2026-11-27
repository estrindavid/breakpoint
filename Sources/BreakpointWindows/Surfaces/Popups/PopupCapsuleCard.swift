import BreakpointCore
import BreakpointRuntime
import Foundation

/// The single-line card of the away note and the toasts (SPEC §3.5), as `ToastShell` draws it:
/// 44 DIPs high, the optional 32 DIP kind badge inset 6 · 10 · the text (13, 85%) · 10 · the
/// optional tertiary action (28). 18 at an end without a badge or action, 8 after an action.
/// On Windows it is the window's own rounded rectangle (the system rounds every pop-up alike).
///
/// - Away note: "Counted your 6 min away as a break" · Undo.
/// - Toast: "Timers restored"; the call-pause toast with Resume.
/// - The first call pause: the line, then the hint under it on the same card (`ToastView`).
/// - × on hover; the lit edge is its timer.
@MainActor
enum PopupCapsuleCard {
    static let height: Float = 44
    static let badge: Float = 32
    static let badgeInset: Float = 6
    static let textStyle = TextStyle(size: 13)
    /// The widest a toast with a hint grows before its hint wraps.
    static let maxHintWidth: Float = 360

    static func layout(_ canvas: Canvas?, _ controls: Controls?, text: String, badge kind: BreakKind?,
                       action: (String, () -> Void)?, hint: String?, _ look: PopupCardLook,
                       _ handlers: PopupCardHandlers) -> SizeF {
        let body = Colour.white.opacity(Theme.TextStep.body.opacity)
        let textSize = Canvas.measure(text, style: textStyle)
        let actionWidth = action.map { PopupPill.width($0.0, role: .tertiary, size: .small) } ?? 0
        if let hint {
            return withHint(canvas, controls, text: text, action: action, hint: hint, look, handlers)
        }
        let leading = kind == nil ? 18 : badgeInset
        let trailing: Float = action == nil ? 18 : 8
        var x = leading
        if kind != nil { x += badge + 10 }
        let textX = x
        x += textSize.width
        if action != nil { x += 10 + actionWidth }
        let width = (x + trailing).rounded(.up)
        if let canvas {
            if let kind {
                PopupBadge.draw(canvas, centre: PointF(x: badgeInset + badge / 2, y: height / 2), diameter: badge,
                                symbol: kind.symbolName, tone: .brand)
            }
            canvas.text(text, at: PointF(x: textX, y: (height - textSize.height) / 2), style: textStyle, body)
        }
        if let action {
            PopupPill.draw(canvas, controls, id: "action", at: PointF(x: width - trailing - actionWidth, y: (height - 28) / 2),
                           action.0, role: .tertiary, size: .small, action: action.1)
        }
        PopupCardView.closeButton(canvas, controls, visible: look.hovering, action: handlers.close)
        return SizeF(width: width, height: height)
    }

    /// The line and its hint on one card: padding 8 / 18 / 12 / 8, 4 between.
    private static func withHint(_ canvas: Canvas?, _ controls: Controls?, text: String, action: (String, () -> Void)?,
                                 hint: String, _ look: PopupCardLook, _ handlers: PopupCardHandlers) -> SizeF {
        let (top, leading, bottom, trailing): (Float, Float, Float, Float) = (8, 18, 12, 8)
        let textSize = Canvas.measure(text, style: textStyle)
        let actionWidth = action.map { PopupPill.width($0.0, role: .tertiary, size: .small) } ?? 0
        let rowWidth = textSize.width + (action == nil ? 0 : 10 + actionWidth)
        let hintNatural = Canvas.measure(hint, style: TextStyle(size: Theme.Typography.coach.size)).width + 22
        let inner = max(rowWidth, min(hintNatural, maxHintWidth - leading - trailing - 10))
        let width = (leading + inner + trailing + (hintNatural > rowWidth ? 10 : 0)).rounded(.up)
        let rowHeight: Float = 28
        var y = top
        if let canvas {
            canvas.text(text, at: PointF(x: leading, y: y + (rowHeight - textSize.height) / 2), style: textStyle,
                        Colour.white.opacity(Theme.TextStep.body.opacity))
        }
        if let action {
            PopupPill.draw(canvas, controls, id: "action", at: PointF(x: width - trailing - actionWidth, y: y), action.0,
                           role: .tertiary, size: .small, action: action.1)
        }
        y += rowHeight + 4
        let hintWidth = width - leading - trailing - 10
        if let canvas {
            y += HintLine.draw(canvas, at: PointF(x: leading, y: y), width: hintWidth, text: hint)
        } else {
            y += HintLine.height(width: hintWidth, text: hint)
        }
        PopupCardView.closeButton(canvas, controls, visible: look.hovering, action: handlers.close)
        return SizeF(width: width, height: (y + bottom).rounded(.up))
    }
}
