import BreakpointCore
import BreakpointRuntime
import Foundation

/// The tray flyout (SPEC §3.8): the macOS popover's content, drawn the Windows way. What it says
/// comes from the shared `PopoverModel`, so both apps read the same in every state.
///
/// Top to bottom: the top bar (mark, name, menu button); the status block (ring, caption, big
/// value, detail, "Why not now?"); Take a break ▾ / Pause ▾ (or Resume now); the automatic
/// decision with Undo; Agents; all-time totals; the footer; the tour's strip or the first-use hint.
@MainActor
public enum FlyoutView {
    public static let width: Float = Theme.Size.popoverWidth
    static let padding = Theme.Spacing.m
    static let ring: Float = 44
    static let agentRowHeight: Float = 36
    static let maxAgentRows = 4

    /// What the flyout's controls do; `anchor` is the control's rect (menus open under it).
    public struct Handlers {
        public var takeBreak: (RectF) -> Void = { _ in }
        public var pause: (RectF) -> Void = { _ in }
        public var resume: () -> Void = {}
        public var undo: () -> Void = {}
        public var connect: () -> Void = {}
        public var menu: (RectF) -> Void = { _ in }
        /// The tour's strip (SPEC §3.12) when the tour names the popover's parts; draws at the
        /// given origin and width and returns its height (nil canvas: measure only).
        public var tourStrip: ((Canvas?, Controls?, PointF, Float) -> Float)?
        public init() {}
    }

    /// The flyout's height for `state`.
    public static func height(_ state: AppState, handlers: Handlers = Handlers()) -> Float {
        layout(nil, nil, state, handlers)
    }

    public static func draw(_ canvas: Canvas, _ controls: Controls, _ state: AppState, handlers: Handlers) {
        _ = layout(canvas, controls, state, handlers)
    }

    // One pass that both measures (canvas nil) and draws, so the height always matches.
    private static func layout(_ canvas: Canvas?, _ controls: Controls?, _ state: AppState, _ handlers: Handlers) -> Float {
        let inner = width - 2 * padding
        let x = padding
        var y: Float = Theme.Spacing.s
        let secondary = Colour.white.opacity(Theme.TextStep.secondary.opacity)

        // Top bar.
        if let canvas {
            BrandMark.drawMark(in: RectF(x: x, y: y + 9, width: 16, height: 10), on: canvas,
                               tag: Colour.white.opacity(0.6), eyes: Theme.Palette.solidPopup)
            canvas.text("Breakpoint", at: PointF(x: x + 22, y: y + 6), style: TextStyle(size: 12, weight: 600), secondary)
            if let controls {
                let gear = RectF(x: width - padding - 26, y: y + 1, width: 26, height: 26)
                iconButton(canvas, controls, id: "gear", gear, symbol: "gearshape") { handlers.menu(gear) }
            }
        }
        y += 28

        // Status block.
        y += Theme.Spacing.xs
        let status = PopoverModel.status(state)
        let textX = x + ring + 14
        let textWidth = inner - ring - 14
        var block: Float = 0
        let captionSize = Canvas.measure(status.caption, style: Theme.Typography.captionWrapped, width: textWidth)
        let numberHeight: Float = status.number == nil ? 0 : 44
        let detailSize = Canvas.measure(status.detail, style: Theme.Typography.detailWrapped, width: textWidth)
        let why = PopoverModel.whyNotNow(state)
        let whySize = why.map { Canvas.measure($0, style: Theme.Typography.detailWrapped, width: textWidth - 16) }
        block = captionSize.height + numberHeight + (status.number == nil ? 4 : 0) + detailSize.height
            + (whySize.map { $0.height + Theme.Spacing.xxs } ?? 0)
        let blockHeight = max(ring, block)
        if let canvas {
            let ringCentre = PointF(x: x + ring / 2, y: y + blockHeight / 2)
            canvas.withOpacity(status.ringDimmed ? 0.55 : 1) {
                ProgressRing.draw(canvas, centre: ringCentre, radius: ring / 2 - 2, width: 4, progress: status.ringProgress)
                Glyphs.draw(status.ringSymbol, on: canvas, centre: ringCentre, size: 16, secondary)
            }
            var ty = y + (blockHeight - block) / 2
            canvas.text(status.caption, at: PointF(x: textX, y: ty), width: textWidth, style: Theme.Typography.captionWrapped, secondary)
            ty += captionSize.height
            if let number = status.number {
                bigValue(canvas, at: PointF(x: textX, y: ty - 2), width: textWidth, prefix: status.prefix, number: number, unit: status.unit)
                ty += numberHeight
            } else {
                ty += 4
            }
            canvas.text(status.detail, at: PointF(x: textX, y: ty), width: textWidth, style: Theme.Typography.detailWrapped, secondary)
            ty += detailSize.height
            if let why, let whySize {
                ty += Theme.Spacing.xxs
                Glyphs.draw("clock", on: canvas, centre: PointF(x: textX + 5, y: ty + 8), size: 10, secondary)
                canvas.text(why, at: PointF(x: textX + 16, y: ty), width: textWidth - 16, style: Theme.Typography.detailWrapped, secondary)
                ty += whySize.height
            }
        }
        y += blockHeight

        // Actions.
        y += Theme.Spacing.m
        let half = (inner - Theme.Spacing.xs) / 2
        let left = RectF(x: x, y: y, width: half, height: Theme.Size.buttonHeight)
        let right = RectF(x: x + half + Theme.Spacing.xs, y: y, width: half, height: Theme.Size.buttonHeight)
        if let canvas, let controls {
            if state.status.isPaused {
                controls.button(canvas, id: "resume", left, "Resume now", role: .primary) { handlers.resume() }
                chevronButton(canvas, controls, id: "takeBreak", right, "Take a break", role: .secondary) { handlers.takeBreak(right) }
            } else {
                chevronButton(canvas, controls, id: "takeBreak", left, "Take a break", role: .primary) { handlers.takeBreak(left) }
                chevronButton(canvas, controls, id: "pause", right, "Pause", role: .secondary) { handlers.pause(right) }
            }
        }
        y += Theme.Size.buttonHeight

        // The automatic decision, with Undo.
        if let decision = state.undoableDecision {
            y += Theme.Spacing.s
            let line = Copy.decisionLine(decision)
            let undoWidth = Canvas.measure("Undo", style: Theme.Typography.smallButton).width + 24
            let lineWidth = inner - 12 - 20 - undoWidth - 10
            let lineSize = Canvas.measure(line, style: Theme.Typography.bodyWrapped, width: lineWidth)
            let height = max(36, lineSize.height + 8)
            if let canvas, let controls {
                let card = RectF(x: x, y: y, width: inner, height: height)
                Chrome.insetCard(canvas, card)
                Glyphs.draw("arrow.clockwise", on: canvas, centre: PointF(x: x + 18, y: card.midY), size: 12, secondary)
                canvas.text(line, at: PointF(x: x + 32, y: card.midY - lineSize.height / 2), width: lineWidth,
                            style: Theme.Typography.bodyWrapped, Colour.white.opacity(Theme.TextStep.body.opacity))
                let undo = RectF(x: card.maxX - 6 - undoWidth, y: card.midY - 14, width: undoWidth, height: 28)
                controls.button(canvas, id: "undo", undo, "Undo", role: .quiet) { handlers.undo() }
            }
            y += height
        }

        // Agents.
        y += Theme.Spacing.l
        canvas?.text("Agents", at: PointF(x: x + 4, y: y), style: TextStyle(size: 12, weight: 600), secondary)
        y += 16 + 6
        let rows = PopoverModel.agentRows(state)
        let visible = Array(rows.prefix(maxAgentRows))
        let cardTop = y
        var cardHeight: Float
        if rows.isEmpty {
            if PopoverModel.showsConnectPrompt(state) {
                cardHeight = connectPrompt(canvas, controls, at: PointF(x: x, y: y), width: inner, handlers: handlers, measureOnly: true)
            } else {
                let text = "No agent is running. Runs show up here as they start."
                cardHeight = max(agentRowHeight, Canvas.measure(text, style: Theme.Typography.detailWrapped, width: inner - 24).height + 12)
            }
        } else {
            cardHeight = Float(visible.count) * agentRowHeight + Float(max(0, visible.count - 1))
            if rows.count > visible.count { cardHeight += 1 + 28 }
        }
        if let canvas {
            let card = RectF(x: x, y: cardTop, width: inner, height: cardHeight)
            Chrome.insetCard(canvas, card)
            if rows.isEmpty {
                if PopoverModel.showsConnectPrompt(state) {
                    _ = connectPrompt(canvas, controls, at: PointF(x: x, y: y), width: inner, handlers: handlers, measureOnly: false)
                } else {
                    canvas.text("No agent is running. Runs show up here as they start.", in: card.insetBy(12, 0),
                                style: Theme.Typography.detailWrapped, secondary)
                }
            } else {
                var ry = cardTop
                for (index, row) in visible.enumerated() {
                    if index > 0 {
                        canvas.fill(RectF(x: x + 12, y: ry, width: inner - 12, height: 1), Colour.white.opacity(0.07))
                        ry += 1
                    }
                    agentRow(canvas, row, RectF(x: x, y: ry, width: inner, height: agentRowHeight), now: state.now)
                    ry += agentRowHeight
                }
                if rows.count > visible.count {
                    canvas.fill(RectF(x: x + 12, y: ry, width: inner - 12, height: 1), Colour.white.opacity(0.07))
                    ry += 1
                    canvas.text("+\(rows.count - visible.count) more", in: RectF(x: x + 12 + 20 + 10, y: ry, width: inner - 42, height: 28),
                                style: Theme.Typography.detail, secondary)
                }
            }
        }
        y += cardHeight

        // Totals.
        y += Theme.Spacing.m
        y += totals(canvas, state, at: PointF(x: x, y: y), width: inner)

        // Footer.
        y += Theme.Spacing.m
        let footer = PopoverModel.footer(state)
        if let canvas {
            var fx = x + 4
            if let tone = footer.tone {
                StatusDot.draw(canvas, centre: PointF(x: fx + 3, y: y + 7), diameter: 6, tone: tone, style: tone == .mint ? .filled : .hollow)
                fx += 12
            }
            canvas.text(footer.text, at: PointF(x: fx, y: y), width: inner - (fx - x), style: TextStyle(size: 11), secondary)
        }
        y += 15

        // The tour's strip, or the first-use hint.
        let tourOnPopover = state.tour.map { $0.step == .popover } ?? false
        if tourOnPopover, let strip = handlers.tourStrip {
            y += Theme.Spacing.m
            y += strip(canvas, controls, PointF(x: x, y: y), inner)
        } else if let hint = state.popoverHint {
            y += Theme.Spacing.s
            if let canvas {
                y += HintLine.draw(canvas, at: PointF(x: x + 4, y: y), width: inner - 8, text: hint)
            } else {
                y += HintLine.height(width: inner - 8, text: hint)
            }
        }
        return (y + Theme.Spacing.m).rounded(.up)
    }

    // MARK: Pieces

    /// "until 15:30" / "6 min" / "Now": the number 38 bold, prefix and unit 20 semibold.
    private static func bigValue(_ canvas: Canvas, at origin: PointF, width: Float, prefix: String?, number: String, unit: String?) {
        let small = TextStyle(size: 20, weight: 600)
        let secondary = Colour.white.opacity(Theme.TextStep.secondary.opacity)
        var x = origin.x
        let numberSize = Canvas.measure(number, style: Theme.Typography.popoverNumber)
        let baseline = origin.y + numberSize.height * 0.8
        if let prefix {
            let size = Canvas.measure(prefix, style: small)
            canvas.text(prefix, at: PointF(x: x, y: baseline - size.height * 0.8), style: small, secondary)
            x += size.width + 5
        }
        canvas.text(number, at: PointF(x: x, y: origin.y), style: Theme.Typography.popoverNumber, Colour.white)
        x += numberSize.width + 5
        if let unit {
            let size = Canvas.measure(unit, style: small)
            canvas.text(unit, at: PointF(x: x, y: baseline - size.height * 0.8), style: small, secondary)
        }
    }

    private static func agentRow(_ canvas: Canvas, _ row: PopoverModel.AgentRow, _ rect: RectF, now: Date) {
        let secondary = Colour.white.opacity(Theme.TextStep.secondary.opacity)
        SourceTile.draw(canvas, RectF(x: rect.x + 12, y: rect.midY - 10, width: 20, height: 20), symbol: row.symbol)
        let elapsedStyle = TextStyle(size: 12, weight: 500, monospacedDigits: true, align: .trailing)
        let elapsedWidth = Canvas.measure(row.elapsed, style: elapsedStyle).width
        let chipStyle = Theme.Typography.smallChip
        let chipWidth = Chip.width(text: row.chip, hasDot: true, height: 20, style: chipStyle)
        let titleX = rect.x + 12 + 20 + 10
        let titleMax = rect.maxX - 12 - elapsedWidth - 8 - chipWidth - 8 - titleX
        let title = Truncate.middle(row.title, style: Theme.Typography.body, width: titleMax)
        let titleSize = Canvas.measure(title, style: Theme.Typography.body)
        canvas.text(title, at: PointF(x: titleX, y: rect.midY - titleSize.height / 2), style: Theme.Typography.body,
                    Colour.white.opacity(Theme.TextStep.body.opacity))
        let pulse = row.tone == .agent ? StatusDot.pulseOpacity(at: now) : 1
        Chip.draw(canvas, at: PointF(x: titleX + titleSize.width + 8, y: rect.midY - 10), text: row.chip, tone: row.tone, height: 20,
                  style: chipStyle, dotOpacity: pulse, dotStyle: row.tone == .needsYou ? .hollow : .filled)
        canvas.text(row.elapsed, in: RectF(x: rect.maxX - 12 - elapsedWidth, y: rect.y, width: elapsedWidth, height: rect.height),
                    style: elapsedStyle, secondary)
    }

    private static func connectPrompt(_ canvas: Canvas?, _ controls: Controls?, at origin: PointF, width: Float,
                                      handlers: Handlers, measureOnly: Bool) -> Float {
        let textX = origin.x + 12 + 20 + 10
        let textWidth = width - (textX - origin.x) - 12
        let body = "Breaks wait for your agent to start working. Connect one to begin."
        let bodySize = Canvas.measure(body, style: Theme.Typography.detailWrapped, width: textWidth)
        let height: Float = 12 + 17 + 2 + bodySize.height + 8 + 28 + 12
        guard !measureOnly, let canvas else { return height }
        SourceTile.draw(canvas, RectF(x: origin.x + 12, y: origin.y + 12, width: 20, height: 20), symbol: "link")
        canvas.text("No agent connected yet", at: PointF(x: textX, y: origin.y + 12), style: Theme.Typography.bodySemibold,
                    Colour.white.opacity(Theme.TextStep.body.opacity))
        canvas.text(body, at: PointF(x: textX, y: origin.y + 31), width: textWidth, style: Theme.Typography.detailWrapped,
                    Colour.white.opacity(Theme.TextStep.secondary.opacity))
        if let controls {
            let title = "Connect your agent…"
            let buttonWidth = Canvas.measure(title, style: Theme.Typography.smallButton).width + 28
            controls.button(canvas, id: "connect", RectF(x: textX, y: origin.y + 31 + bodySize.height + 8, width: buttonWidth, height: 28),
                            title, role: .secondary) { handlers.connect() }
        }
        return height
    }

    /// The all-time totals (SPEC §3.8): period label, three figures, and one example line.
    private static func totals(_ canvas: Canvas?, _ state: AppState, at origin: PointF, width: Float) -> Float {
        let totals = state.totals
        let secondary = Colour.white.opacity(Theme.TextStep.secondary.opacity)
        var y = origin.y
        canvas?.text(TotalsCopy.period(firstEntry: totals.firstEntry, now: state.now), at: PointF(x: origin.x + 4, y: y),
                     style: TextStyle(size: 12, weight: 600), secondary)
        y += 16 + Theme.Spacing.xs
        let movingColumn: Float = 114
        let countColumn = (width - 2 * Theme.Spacing.xxs - movingColumn) / 2
        if let canvas {
            var cx = origin.x + Theme.Spacing.xxs
            let figures: [([TotalsCopy.Part], String, Float)] = [
                (TotalsCopy.movingParts(totals.movingSeconds), TotalsCopy.movingLabel, movingColumn),
                ([TotalsCopy.Part(TotalsCopy.count(totals.stretches))], TotalsCopy.stretchesLabel(totals.stretches), countColumn),
                ([TotalsCopy.Part(TotalsCopy.count(totals.eyeRests))], TotalsCopy.eyeRestsLabel(totals.eyeRests), countColumn),
            ]
            for (parts, label, column) in figures {
                figure(canvas, parts, at: PointF(x: cx, y: y), width: column - Theme.Spacing.xs)
                canvas.text(label, at: PointF(x: cx, y: y + 32), style: Theme.Typography.body, secondary)
                cx += column
            }
        }
        y += 32 + 17
        if let line = TotalsCopy.exampleLine(totals) {
            y += Theme.Spacing.s
            if let canvas {
                let quiet = Colour.white.opacity(Theme.TextStep.hint.opacity)
                let activity = line.isNew ? Theme.Palette.mint : Colour.white.opacity(Theme.TextStep.label.opacity)
                var lx = origin.x + Theme.Spacing.xxs
                for (text, colour) in [(line.prefix, quiet), (line.activity, activity), (line.suffix, quiet)] where !text.isEmpty {
                    lx += canvas.text(text, at: PointF(x: lx, y: y), style: Theme.Typography.detail, colour).width
                }
            }
            y += 16
        }
        return y - origin.y
    }

    /// "74 min": numbers bold 30 (scaled down to fit the column), units 15 at the label step.
    private static func figure(_ canvas: Canvas, _ parts: [TotalsCopy.Part], at origin: PointF, width: Float) {
        func measure(_ scale: Float) -> Float {
            parts.enumerated().reduce(Float(0)) { sum, item in
                let (index, part) = item
                var w = Canvas.measure(part.value, style: numberStyle(scale)).width + (index > 0 ? Theme.Spacing.xxs : 0)
                if let unit = part.unit { w += 2 + Canvas.measure(unit, style: unitStyle(scale)).width }
                return sum + w
            }
        }
        var scale: Float = 1
        while scale > 0.6, measure(scale) > width { scale -= 0.05 }
        var x = origin.x
        let numberHeight = Canvas.measure("0", style: numberStyle(scale)).height
        let top = origin.y + (32 - numberHeight) / 2
        for (index, part) in parts.enumerated() {
            if index > 0 { x += Theme.Spacing.xxs }
            x += canvas.text(part.value, at: PointF(x: x, y: top), style: numberStyle(scale), Colour.white).width
            if let unit = part.unit {
                let unitSize = Canvas.measure(unit, style: unitStyle(scale))
                x += 2
                x += canvas.text(unit, at: PointF(x: x, y: top + numberHeight * 0.78 - unitSize.height * 0.78), style: unitStyle(scale),
                                 Colour.white.opacity(Theme.TextStep.label.opacity)).width
            }
        }
    }

    private static func numberStyle(_ scale: Float) -> TextStyle {
        TextStyle(size: (30 * scale).rounded(), weight: 700, monospacedDigits: true)
    }

    private static func unitStyle(_ scale: Float) -> TextStyle {
        TextStyle(size: (15 * scale).rounded(), weight: 600)
    }

    /// A capsule button with a chevron after its title (it opens a menu).
    static func chevronButton(_ canvas: Canvas, _ controls: Controls, id: String, _ rect: RectF, _ title: String,
                              role: Controls.Role, action: @escaping () -> Void) {
        controls.button(canvas, id: id, rect, title, role: role, chevron: true, action: action)
    }

    /// A round 26 DIP icon button (the menu button).
    static func iconButton(_ canvas: Canvas, _ controls: Controls, id: String, _ rect: RectF, symbol: String,
                           action: @escaping () -> Void) {
        let hot = controls.isHovered(id)
        if hot || controls.isPressed(id) {
            canvas.circle(PointF(x: rect.midX, y: rect.midY), radius: rect.width / 2, Colour.white.opacity(controls.isPressed(id) ? 0.16 : 0.10))
        }
        Glyphs.draw(symbol, on: canvas, centre: PointF(x: rect.midX, y: rect.midY), size: 15,
                    Colour.white.opacity(hot ? 0.9 : Theme.TextStep.secondary.opacity))
        controls.region(id, rect, focusable: true, action: action)
        if controls.isFocusVisible(id) {
            canvas.ring(PointF(x: rect.midX, y: rect.midY), radius: rect.width / 2 + 2, width: 2, controls.look.accent)
        }
    }
}

/// Shortens text to fit, keeping its start and end ("my-long…folder").
@MainActor
public enum Truncate {
    public static func middle(_ text: String, style: TextStyle, width: Float) -> String {
        guard width > 0, Canvas.measure(text, style: style).width > width else { return text }
        var characters = Array(text)
        while characters.count > 3 {
            let middle = characters.count / 2
            characters.remove(at: middle)
            let candidate = String(characters[..<(characters.count / 2)]) + "…" + String(characters[(characters.count / 2)...])
            if Canvas.measure(candidate, style: style).width <= width { return candidate }
        }
        return "…"
    }

    public static func tail(_ text: String, style: TextStyle, width: Float) -> String {
        guard width > 0, Canvas.measure(text, style: style).width > width else { return text }
        var characters = Array(text)
        while !characters.isEmpty {
            characters.removeLast()
            let candidate = String(characters).trimmingCharacters(in: .whitespaces) + "…"
            if Canvas.measure(candidate, style: style).width <= width { return candidate }
        }
        return "…"
    }
}
