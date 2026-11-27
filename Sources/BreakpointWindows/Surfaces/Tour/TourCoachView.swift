import BreakpointCore
import BreakpointRuntime
import Foundation

// The tour's coach lines (SPEC §3.12) drawn the Windows way: the macOS `CoachCaption`,
// `TourProgressDots`, `MarkLegend`, `TourPopoverStrip` and `OverlayCoachLine` as pure layout
// functions over `Canvas` (a nil canvas measures only, so a window's height always matches what
// it draws). Always dark, like every pop-up.

/// What a coach line's controls do.
struct TourCoachHandlers {
    var primary: () -> Void = {}
    var secondary: () -> Void = {}
    var skip: () -> Void = {}
}

/// Where a coach card's mark points: at the card's top or bottom edge, `x` DIPs from its leading
/// edge (`nil`: the centre). A pop-up is one rounded window on Windows, so the pointer cannot hang
/// outside it: the coach dot sits on the edge that faces what it explains.
enum TourPointer: Equatable {
    case none
    case up(x: Float?)
    case down(x: Float?)
}

@MainActor
enum TourCoachView {
    /// A standalone card's width (as `CoachCaption.width` on macOS).
    nonisolated static let width: Float = 340
    static let padding = Theme.Size.cardPadding
    /// The band the coach dot takes on a pointing edge.
    static let pointerBand: Float = 12
    static let dotSize: Float = 9

    private static let titleStyle = TextStyle(size: 13, weight: 600, wrap: true)
    private static let textStyle = Theme.Typography.coach
    nonisolated private static let skipStyle = TextStyle(size: 11)

    // MARK: The coach dot

    /// The coach family's mark: a 4 DIP mint dot in a 1 DIP ring, 9 across, on a faint dark halo.
    static func dot(_ canvas: Canvas, centre: PointF) {
        canvas.circle(centre, radius: dotSize / 2 + 1, Theme.Palette.scrim.opacity(0.35))
        canvas.ring(centre, radius: dotSize / 2 - 0.5, width: 1, Theme.Palette.mint.opacity(Appearance.highContrast ? 1 : 0.7))
        canvas.circle(centre, radius: 2, Theme.Palette.mint)
    }

    // MARK: The coach card

    /// A coach card: progress dots and Skip tour, a short title, one or two sentences, the mark's
    /// legend on the mark step, then the buttons that move the tour on. Returns its height.
    @discardableResult
    static func card(_ canvas: Canvas?, _ controls: Controls?, tour: TourPresentation, width: Float = width,
                     pointer: TourPointer = .none, origin: PointF = PointF(x: 0, y: 0), handlers: TourCoachHandlers) -> Float {
        let coach = windowsCoach(tour)
        let inner = width - 2 * padding
        let x = origin.x + padding
        var top = origin.y + padding
        if case .up = pointer { top += pointerBand - 4 }
        var y = top
        let showsSkip = tour.step != .offer
        if tour.progressIndex != nil || showsSkip {
            if let canvas {
                if let index = tour.progressIndex {
                    progressDots(canvas, at: PointF(x: x, y: y + 5.5), index: index, count: tour.progressCount)
                }
                if showsSkip, let controls {
                    skipButton(canvas, controls, trailing: PointF(x: x + inner, y: y), handlers: handlers)
                }
            }
            y += 16 + Theme.Spacing.xs
        }
        if let title = coach.title {
            let size = canvas?.text(title, at: PointF(x: x, y: y), width: inner, style: titleStyle, Theme.Palette.white(.title))
                ?? Canvas.measure(title, style: titleStyle, width: inner)
            y += size.height + 3
        }
        let textSize = canvas?.text(coach.text, at: PointF(x: x, y: y), width: inner, style: textStyle, Theme.Palette.white(.body))
            ?? Canvas.measure(coach.text, style: textStyle, width: inner)
        y += textSize.height
        if tour.step == .mark {
            y += Theme.Spacing.s
            y += markLegend(canvas, at: PointF(x: x, y: y), width: inner)
        }
        if coach.primary != nil || coach.secondary != nil {
            y += Theme.Spacing.s
            if let canvas, let controls {
                var right = x + inner
                if let primary = coach.primary {
                    let w = buttonWidth(primary)
                    controls.button(canvas, id: "tour.primary", RectF(x: right - w, y: y, width: w, height: Theme.Size.smallButtonHeight),
                                    primary, role: .primary) { handlers.primary() }
                    right -= w + Theme.Size.buttonGap
                }
                if let secondary = coach.secondary {
                    let w = buttonWidth(secondary)
                    controls.button(canvas, id: "tour.secondary", RectF(x: right - w, y: y, width: w, height: Theme.Size.smallButtonHeight),
                                    secondary, role: .secondary) { handlers.secondary() }
                }
            }
            y += Theme.Size.smallButtonHeight
        }
        y += padding
        if case .down = pointer { y += pointerBand - 4 }
        let height = (y - origin.y).rounded(.up)
        if let canvas {
            switch pointer {
            case .none: break
            case .up(let px): pointerMark(canvas, x: origin.x + (px ?? width / 2), y: origin.y + 2 + dotSize / 2, minX: origin.x, width: width, towardsTop: true)
            case .down(let px): pointerMark(canvas, x: origin.x + (px ?? width / 2), y: origin.y + height - 2 - dotSize / 2, minX: origin.x, width: width, towardsTop: false)
            }
        }
        return height
    }

    /// The coach line under the sample nudge or the sample resume card, inside that pop-up's own
    /// window (`NudgeController.tourCaption`, `CardsController.tourCaption`): a hairline across the
    /// window with the coach dot on it, then the step's caption. Returns its height.
    static func attached(_ canvas: Canvas?, _ controls: Controls?, tour: TourPresentation, at origin: PointF, width: Float,
                         handlers: TourCoachHandlers) -> Float {
        if let canvas {
            canvas.fill(RectF(x: origin.x, y: origin.y + 2 + dotSize / 2 - 0.5, width: width, height: 1),
                        Colour.white.opacity(Appearance.highContrast ? 0.30 : 0.10))
        }
        return card(canvas, controls, tour: tour, width: width, pointer: .up(x: nil), origin: origin, handlers: handlers)
    }

    /// The dot on the edge that faces the target, with a short hairline toward the card's content.
    private static func pointerMark(_ canvas: Canvas, x: Float, y: Float, minX: Float, width: Float, towardsTop: Bool) {
        let cx = min(max(x, minX + 12), minX + width - 12)
        let line = Colour.white.opacity(Appearance.highContrast ? 0.8 : 0.55)
        let from = towardsTop ? y + dotSize / 2 : y - dotSize / 2
        let to = towardsTop ? from + 5 : from - 5
        canvas.line(PointF(x: cx, y: from), PointF(x: cx, y: to), width: 1, line, round: false)
        dot(canvas, centre: PointF(x: cx, y: y))
    }

    static func buttonWidth(_ title: String) -> Float {
        (Canvas.measure(title, style: Theme.Typography.smallButton).width + 2 * Theme.Size.buttonPadding).rounded(.up)
    }

    /// Windows' words where the shared copy names the Mac's menu bar (SPEC §3.11 holds the rest).
    static func windowsCoach(_ tour: TourPresentation) -> TourCoach {
        var coach = tour.coach
        coach.text = windowsWording(coach.text)
        coach.title = coach.title.map(windowsWording)
        return coach
    }

    /// The shared copy already names the notification area (`BreakpointPlatform.markHome`); this
    /// stays as a guard for any future sentence that names the menu bar.
    static func windowsWording(_ text: String) -> String {
        text.replacingOccurrences(of: "your menu bar", with: "the notification area")
            .replacingOccurrences(of: "the menu bar", with: "the notification area")
            .replacingOccurrences(of: "menu bar", with: "notification area")
    }

    // MARK: Progress and Skip tour

    /// "● ● ▬ ○ ○ ○": done dots at 60%, the current one a short mint capsule, the rest at 20%.
    static func progressDots(_ canvas: Canvas, at origin: PointF, index: Int, count: Int) {
        var x = origin.x
        for dot in 1...max(1, count) {
            let current = dot == index
            let w: Float = current ? 14 : 5
            let colour = current ? Theme.Palette.mint
                : Colour.white.opacity(dot < index ? Theme.TextStep.secondary.opacity : (Appearance.highContrast ? 0.35 : 0.2))
            canvas.fill(RectF(x: x, y: origin.y - 2.5, width: w, height: 5), radius: 2.5, colour)
            x += w + 5
        }
    }

    static func progressWidth(count: Int) -> Float { Float(max(1, count) - 1) * 10 + 14 }

    /// "Skip tour": quiet text, always there; its trailing edge at `trailing.x`.
    static func skipButton(_ canvas: Canvas, _ controls: Controls, trailing: PointF, style: TextStyle = skipStyle,
                           handlers: TourCoachHandlers) {
        let title = "Skip tour"
        let size = Canvas.measure(title, style: style)
        let rect = RectF(x: trailing.x - size.width, y: trailing.y + (16 - size.height) / 2, width: size.width, height: size.height)
        let hot = controls.isHovered("tour.skip")
        canvas.text(title, at: PointF(x: rect.x, y: rect.y), style: style,
                    Colour.white.opacity(hot ? Theme.TextStep.body.opacity : Theme.TextStep.secondary.opacity))
        controls.region("tour.skip", rect.insetBy(-4, -3), focusable: true) { handlers.skip() }
        if controls.isFocusVisible("tour.skip") {
            canvas.stroke(rect.insetBy(-4, -2), radius: 4, width: 2, controls.look.accent)
        }
    }

    // MARK: The mark's legend

    static let legend: [(MarkVariant, MarkBadge, String)] = [
        (.idle, .working, TourCopy.legendWorking),
        (.idle, .needsYou, TourCopy.legendNeedsYou),
        (.due, .none, TourCopy.legendDue),
        (.onBreak, .none, TourCopy.legendOnBreak),
        (.paused, .none, TourCopy.legendPaused),
    ]

    /// The mark's states drawn with the real mark, each with its name; returns its height.
    static func markLegend(_ canvas: Canvas?, at origin: PointF, width: Float) -> Float {
        let height: Float = 8 + 15 + 5 + 14 + 8
        guard let canvas else { return height }
        let plate = RectF(x: origin.x, y: origin.y, width: width, height: height)
        canvas.fill(plate, radius: Theme.Radius.keycap * 2, Colour.white.opacity(0.05))
        let column = width / Float(legend.count)
        let cutout = Theme.Palette.solidPopup.mixed(with: .white, 0.05)
        for (index, item) in legend.enumerated() {
            let cx = origin.x + column * (Float(index) + 0.5)
            let markWidth: Float = 15 * BrandMark.bounds.width / BrandMark.bounds.height
            TourMarkDrawing.draw(canvas, in: RectF(x: cx - markWidth / 2, y: origin.y + 8, width: markWidth, height: 15),
                                 variant: item.0, badge: item.1, colour: Theme.Palette.white(.body), cutout: cutout)
            canvas.text(item.2, in: RectF(x: cx - column / 2, y: origin.y + 8 + 15 + 5, width: column, height: 14),
                        style: TextStyle(size: 11, align: .center), Colour.white.opacity(Theme.TextStep.secondary.opacity))
        }
        return height
    }

    // MARK: The popover's strip

    /// The coach line inside the tray flyout (SPEC §3.12, the popover step): progress and Skip tour,
    /// then the coach dot, the part's sentence, and Next (Enter). Returns its height.
    static func strip(_ canvas: Canvas?, _ controls: Controls?, tour: TourPresentation, at origin: PointF, width: Float,
                      handlers: TourCoachHandlers) -> Float {
        let pad = Theme.Spacing.s
        let inner = width - 2 * pad
        let x = origin.x + pad
        let textX = x + dotSize + Theme.Spacing.xs
        let text = windowsCoach(tour).text
        let size = Canvas.measure(text, style: textStyle, width: inner - (textX - x))
        let height = pad + 16 + Theme.Spacing.xs + size.height + Theme.Spacing.xs + Theme.Size.smallButtonHeight + pad
        guard let canvas, let controls else { return height }
        let plate = RectF(x: origin.x, y: origin.y, width: width, height: height)
        canvas.fill(plate, radius: Theme.Radius.insetCard, Colour.white.opacity(0.07))
        canvas.stroke(plate.insetBy(0.5, 0.5), radius: Theme.Radius.insetCard, width: 1,
                      Colour.white.opacity(Appearance.highContrast ? 0.30 : 0.10))
        var y = origin.y + pad
        if let index = tour.progressIndex {
            progressDots(canvas, at: PointF(x: x, y: y + 8), index: index, count: tour.progressCount)
        }
        skipButton(canvas, controls, trailing: PointF(x: x + inner, y: y), handlers: handlers)
        y += 16 + Theme.Spacing.xs
        dot(canvas, centre: PointF(x: x + dotSize / 2, y: y + min(9, size.height / 2)))
        canvas.text(text, at: PointF(x: textX, y: y), width: inner - (textX - x), style: textStyle, Theme.Palette.white(.body))
        y += size.height + Theme.Spacing.xs
        let primary = tour.coach.primary ?? "Next"
        let keycap = "Enter"
        let buttonWidth = Canvas.measure(primary, style: Theme.Typography.smallButton).width + 8
            + Canvas.measure(keycap, style: Theme.Typography.keycap).width + 10 + 2 * Theme.Size.buttonPadding
        let rect = RectF(x: x + inner - buttonWidth, y: y, width: buttonWidth, height: Theme.Size.smallButtonHeight)
        // Enter presses Next: the flyout gives Enter to the focused control.
        if controls.focused == nil { controls.focused = stripNextID }
        controls.button(canvas, id: stripNextID, rect, primary, role: .primary, keycap: keycap) { handlers.primary() }
        return height
    }

    static let stripNextID = "tour.strip.next"
}

/// The mark drawn onto a card (the legend, the onboarding demo): the tray mark's shapes, with the
/// eyes and the badge's halo painted in the colour underneath instead of punched through, since
/// the card is drawn first.
@MainActor
enum TourMarkDrawing {
    static func draw(_ canvas: Canvas, in rect: RectF, variant: MarkVariant, badge: MarkBadge, colour: Colour, cutout: Colour) {
        let markHeight = rect.width * BrandMark.bounds.height / BrandMark.bounds.width
        let mark = RectF(x: rect.x, y: rect.midY - markHeight / 2, width: rect.width, height: markHeight)
        let s = mark.width / BrandMark.bounds.width
        switch variant {
        case .brand, .onBreak:
            BrandMark.draw(.tag, in: mark, on: canvas, colour)
            BrandMark.draw(.eyes, in: mark, on: canvas, cutout)
        case .idle:
            BrandMark.draw(.tagOutline, in: mark, on: canvas, colour)
            BrandMark.draw(.eyes, in: mark, on: canvas, colour)
        case .due:
            BrandMark.draw(.tagOutline, in: mark, on: canvas, colour)
            BrandMark.draw(.notchBlock, in: mark, on: canvas, colour)
            BrandMark.draw(.eyes, in: mark, on: canvas, cutout)
        case .paused:
            BrandMark.draw(.tagOutline, in: mark, on: canvas, colour)
            BrandMark.draw(.restBar, in: mark, on: canvas, colour)
        }
        guard badge != .none else { return }
        let (centre, diameter) = TrayMark.badgeGeometry(mark, scale: s, pose: .rest)
        canvas.circle(centre, radius: (diameter + 3 * s) / 2, cutout)
        switch badge {
        case .working: canvas.circle(centre, radius: diameter / 2, colour)
        case .needsYou: canvas.ring(centre, radius: diameter / 2 - 0.75 * s, width: 1.5 * s, colour)
        case .none: break
        }
    }
}
