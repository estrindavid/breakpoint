import BreakpointCore
import BreakpointRuntime
import Foundation

/// The nudge card (SPEC §3.1), as `NudgeCardView` draws it on the Mac: kind badge · title over
/// subtitle · Start / Not now. 410 DIPs wide, about 122 tall, padding 14.
///
/// - Row 1: the 44 DIP badge · 12 · the title (20 semibold, the offer, shrinking to fit one line)
///   over the subtitle (15, 60%, middle-truncated).
/// - Row 2, 12 below and on the text column: Start (primary) · Not now (secondary), each with its
///   shortcut's keycap when the nudge shortcuts are on: always laid out, faint at rest, coming
///   forward on hover, so nothing moves under the pointer.
/// - Revealed (the pointer rested 300 ms): the × at the top-left corner, and the subtitle
///   cross-fades to the why-now line in the same slot (one clause per line if it is too long).
/// - Eye-rest auto-start: the title counts down ("20-sec eye rest in 7") while a 2 DIP ring
///   sweeps around the badge.
/// - The first real nudge carries its hint under the buttons; the tour's sample nudge carries
///   the coach line under the card (`Handlers.tourCaption`).
@MainActor
enum PopupNudgeView {
    static let width = Theme.Size.nudgeSize.width
    static let padding = Theme.Size.cardPadding

    struct Look {
        /// The pointer rested on the card: ×, why-now and bright keycaps.
        var revealed = false
        /// 0…1, how far the subtitle has cross-faded to the why-now line.
        var whyNow: Float = 0
        /// The auto-start ring, as drawn now (the controller eases it between engine ticks).
        var ring: Double?
        /// Keycap labels when the nudge's shortcuts are on; nil: `HotKeys.display` ("Ctrl+Alt+Win+B").
        var startKey: String?
        var dismissKey: String?
    }

    struct Handlers {
        var start: () -> Void = {}
        var notNow: () -> Void = {}
        var close: (() -> Void)?
        /// The tour's coach line under the sample nudge: draws at the origin and width given and
        /// returns its height (nil canvas: measure only).
        var tourCaption: ((Canvas?, Controls?, PointF, Float) -> Float)?
    }

    static func height(_ nudge: NudgeState, look: Look, handlers: Handlers = Handlers()) -> Float {
        layout(nil, nil, nudge, look, handlers)
    }

    static func draw(_ canvas: Canvas, _ controls: Controls?, _ nudge: NudgeState, look: Look, handlers: Handlers) {
        _ = layout(canvas, controls, nudge, look, handlers)
    }

    /// The card alone, without the tour's caption (where the caption starts).
    static func cardHeight(_ nudge: NudgeState, look: Look) -> Float {
        layout(nil, nil, nudge, look, Handlers())
    }

    private static let titleSizes: [Float] = [20, 19, 18, 17, 16]

    private static func layout(_ canvas: Canvas?, _ controls: Controls?, _ nudge: NudgeState, _ look: Look,
                               _ handlers: Handlers) -> Float {
        let column = padding + Theme.Size.badge + Theme.Size.badgeToText
        let columnWidth = width - column - padding
        var y = padding

        // Title: one line, shrinking to 80% before it truncates.
        var titleStyle = Theme.Typography.nudgeTitle
        titleStyle.monospacedDigits = true
        for size in titleSizes {
            titleStyle.size = size
            if Canvas.measure(nudge.title, style: titleStyle).width <= columnWidth { break }
        }
        let title = PopupText.tail(nudge.title, titleStyle, columnWidth)
        let titleHeight = PopupText.lineHeight(Theme.Typography.nudgeTitle)

        // Subtitle and why-now share one slot.
        let subtitleStyle = Theme.Typography.nudgeSubtitle
        let subtitle = PopupText.middle(nudge.subtitle, subtitleStyle, columnWidth)
        let whyLines: [String] = Canvas.measure(nudge.whyNow, style: subtitleStyle).width <= columnWidth
            ? [nudge.whyNow]
            : Array(nudge.whyNow.components(separatedBy: " · ").prefix(2)).map { PopupText.tail($0, subtitleStyle, columnWidth) }
        let line = PopupText.lineHeight(subtitleStyle)
        let showsWhy = look.whyNow > 0
        let slot = line * Float(showsWhy ? max(1, whyLines.count) : 1)

        if let canvas {
            let badgeCentre = PointF(x: padding + Theme.Size.badge / 2, y: padding + Theme.Size.badge / 2)
            PopupBadge.draw(canvas, centre: badgeCentre, diameter: Theme.Size.badge, symbol: nudge.kind.symbolName, tone: .brand,
                            ringProgress: nudge.phase == .autoStartCard ? look.ring : nil)
            canvas.text(title, at: PointF(x: column, y: y + (titleHeight - PopupText.lineHeight(titleStyle)) / 2), style: titleStyle,
                        Theme.Palette.white(.title))
            let secondary = Colour.white.opacity(Theme.TextStep.secondary.opacity)
            let subtitleY = y + titleHeight + 2
            if look.whyNow < 1 {
                canvas.text(subtitle, at: PointF(x: column, y: subtitleY), style: subtitleStyle, secondary.opacity(1 - look.whyNow))
            }
            if showsWhy {
                for (index, text) in whyLines.enumerated() {
                    canvas.text(text, at: PointF(x: column, y: subtitleY + Float(index) * line), style: subtitleStyle,
                                secondary.opacity(look.whyNow))
                }
            }
        }
        y += titleHeight + 2 + slot

        // Start · Not now.
        y += Theme.Size.rowGap
        let keys = nudge.hotkeysEnabled
        let start = PopupPill.draw(canvas, controls, id: "start", at: PointF(x: column, y: y), "Start", role: .primary,
                                   keycap: keys ? (look.startKey ?? HotKeys.display(.nudgeStart)) : nil, keycapQuiet: !look.revealed) { handlers.start() }
        PopupPill.draw(canvas, controls, id: "notNow", at: PointF(x: start.maxX + Theme.Size.buttonGap, y: y), "Not now",
                       role: .secondary, keycap: keys ? (look.dismissKey ?? HotKeys.display(.nudgeDismiss)) : nil, keycapQuiet: !look.revealed) { handlers.notNow() }
        y += Theme.Size.buttonHeight

        // The first real nudge's hint (SPEC §3.12).
        if let hint = nudge.hint {
            y += Theme.Spacing.s
            if let canvas {
                y += HintLine.draw(canvas, at: PointF(x: column, y: y), width: columnWidth, text: hint)
            } else {
                y += HintLine.height(width: columnWidth, text: hint)
            }
        }
        y += padding

        // The hover ×, centred on the corner inside the window.
        if let close = handlers.close {
            PopupClose.draw(canvas, controls, centre: PointF(x: 11, y: 11), visible: look.revealed, action: close)
        }

        if let caption = handlers.tourCaption {
            y += caption(canvas, controls, PointF(x: 0, y: y), width)
        }
        return y.rounded(.up)
    }
}
