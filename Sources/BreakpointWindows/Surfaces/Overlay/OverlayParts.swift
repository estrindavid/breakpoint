import BreakpointCore
import BreakpointRuntime
import Foundation

/// The overlay's own small parts (SPEC §3.3, §3.4, §3.12): the luminous ring, the completion
/// check, the agent chip, the key hint, the coach line. Same sizes and colours as the macOS
/// `LuminousRing`, `CompletionMark`, `AgentChip`, `KeyHint` and `OverlayCoachLine`.
@MainActor
enum OverlayParts {
    // MARK: Luminous ring

    /// A quiet track, a mint arc brightening from 30% at its tail to full at its head, and a soft
    /// glow at the head (SPEC §3.4). `tail` moves the arc's start off 12 o'clock (turns, may be
    /// negative). High contrast: a solid arc and no glow.
    ///
    /// Direct2D has no angular gradient: the arc is drawn as short segments in colours stepped from
    /// the tail's to the head's, mixed over the scrim opaque so their round caps never stack.
    static func luminousRing(_ canvas: Canvas, centre: PointF, diameter: Float, lineWidth: Float, progress: Double,
                             tail: Double = 0, highContrast: Bool) {
        let radius = (diameter - lineWidth) / 2
        canvas.ring(centre, radius: radius, width: lineWidth, Colour.white.opacity(Theme.TextStep.outline.opacity))
        var head = min(max(progress, tail), tail + 1)
        if tail == 0 { head = min(max(head, 0), 1) }
        let length = Float(min(max(head - tail, 0), 1))
        guard length > 0.0005 else { return }
        let mint = Theme.Palette.mint
        if highContrast || length >= 0.9995 {
            if length >= 0.9995 {
                canvas.ring(centre, radius: radius, width: lineWidth, mint)
            } else {
                arc(canvas, centre, radius, from: Float(tail), to: Float(head), lineWidth, mint)
            }
        } else {
            let dim = Theme.Palette.scrim.mixed(with: mint, 0.3)
            let segments = max(1, Int((length * 40).rounded(.up)))
            let step = length / Float(segments)
            for i in 0..<segments {
                let from = Float(tail) + Float(i) * step
                let t = Float(i + 1) / Float(segments)
                arc(canvas, centre, radius, from: from, to: from + step, lineWidth, dim.mixed(with: mint, t))
            }
        }
        guard !highContrast, length > 0.005 else { return }
        let angle = Float(head) * 2 * .pi - .pi / 2
        let point = PointF(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        canvas.glow(point, rx: lineWidth * 3.2, ry: lineWidth * 3.2, mint.opacity(0.6))
    }

    /// An arc in turns that may start before 12 o'clock (negative) or pass it.
    private static func arc(_ canvas: Canvas, _ centre: PointF, _ radius: Float, from: Float, to: Float, _ width: Float,
                            _ colour: Colour) {
        var a = from, b = to
        while a < 0 { a += 1; b += 1 }
        if b <= 1 {
            canvas.arc(centre, radius: radius, from: a, to: b, width: width, colour)
        } else {
            canvas.arc(centre, radius: radius, from: a, to: 1, width: width, colour)
            canvas.arc(centre, radius: radius, from: 0, to: b - 1, width: width, colour)
        }
    }

    /// The ring closing into a mint check (SPEC §3.3 Closing moment): the ring from
    /// `startProgress` to full, then a check over a 20% mint disc.
    static func completionMark(_ canvas: Canvas, centre: PointF, diameter: Float, lineWidth: Float, startProgress: Double,
                               frame: OverlayCompletionFrame, highContrast: Bool) {
        canvas.withOpacity(Float(frame.mark)) {
            let closed = startProgress + (1 - startProgress) * frame.ring
            luminousRing(canvas, centre: centre, diameter: diameter, lineWidth: lineWidth, progress: min(max(closed, 0), 1),
                         highContrast: highContrast)
            canvas.circle(centre, radius: diameter / 2 - lineWidth, Theme.Palette.mint.opacity(Float(0.20 * frame.check)))
            guard frame.check > 0.001 else { return }
            let w = diameter * OverlayMetrics.completionCheckWidth, h = w * 0.75
            let x = centre.x - w / 2, y = centre.y - h / 2
            let points = [PointF(x: x, y: y + h * 0.55), PointF(x: x + w * 0.36, y: y + h), PointF(x: x + w, y: y)]
            let path = trimmed(points, Float(frame.check))
            var numbers: [Float] = []
            for p in path { numbers += [p.x, p.y] }
            canvas.path("M" + String(repeating: "L", count: path.count - 1), numbers, Theme.Palette.mint,
                        stroke: lineWidth * OverlayMetrics.completionCheckStroke)
        }
    }

    /// The first `fraction` of a polyline's length.
    private static func trimmed(_ points: [PointF], _ fraction: Float) -> [PointF] {
        var lengths: [Float] = []
        for i in 1..<points.count { lengths.append(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        var remaining = lengths.reduce(0, +) * min(max(fraction, 0), 1)
        var out = [points[0]]
        for i in 1..<points.count {
            let segment = lengths[i - 1]
            if remaining >= segment {
                out.append(points[i])
                remaining -= segment
            } else {
                let t = segment > 0 ? remaining / segment : 0
                out.append(PointF(x: points[i - 1].x + (points[i].x - points[i - 1].x) * t,
                                  y: points[i - 1].y + (points[i].y - points[i - 1].y) * t))
                break
            }
        }
        if out.count == 1 { out.append(points[0]) }
        return out
    }

    // MARK: Agent chip

    /// The agent chip (SPEC §3.3 row 1): capsule 28, an 8 DIP dot and 13 pt semibold at 85%.
    /// No dot (the time of day): plain 60% text. Returns its width (nil canvas: measure only).
    @discardableResult
    static func agentChip(_ canvas: Canvas?, centreX: Float, top: Float, chip: AgentChipState, dotOpacity: Float,
                          tone: Tone?) -> Float {
        let style = TextStyle(size: 13, weight: 600, monospacedDigits: true)
        let text = chip.text
        let size = Canvas.measure(text, style: style)
        let height = Theme.Size.agentChipHeight
        guard let tone else {
            canvas?.text(text, at: PointF(x: centreX - size.width / 2, y: top + (height - size.height) / 2), style: style,
                         Colour.white.opacity(Theme.TextStep.secondary.opacity))
            return size.width
        }
        let dot = Theme.Size.agentChipDot
        let width = 12 + dot + 8 + size.width + 12
        guard let canvas else { return width }
        let rect = RectF(x: centreX - width / 2, y: top, width: width, height: height)
        canvas.fill(rect, radius: height / 2, Colour.white.opacity(0.10))
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: height / 2, width: 1, Colour.white.opacity(0.08))
        StatusDot.draw(canvas, centre: PointF(x: rect.x + 12 + dot / 2, y: rect.midY), diameter: dot, tone: tone, opacity: dotOpacity)
        canvas.text(text, at: PointF(x: rect.x + 12 + dot + 8, y: rect.midY - size.height / 2), style: style,
                    Colour.white.opacity(0.85))
        return width
    }

    // MARK: Key hint

    enum Piece: Equatable {
        case text(String)
        case key(String)
    }

    nonisolated static let hintStyle = TextStyle(size: 11)
    nonisolated static let keycapStyle = TextStyle(size: 11, weight: 500, monospacedDigits: true)

    /// A line of words and keycaps ("[Esc] [Esc] to skip · [Enter] I'm back"), centred on
    /// `centreX`, its top at `top`. Returns its size.
    @discardableResult
    static func keyHint(_ canvas: Canvas?, pieces: [Piece], centreX: Float, top: Float, colour: Colour,
                        style: TextStyle = hintStyle, capStyle: TextStyle = keycapStyle, capHeight: Float = 18,
                        highContrast: Bool) -> SizeF {
        let gap: Float = 4
        let widths: [Float] = pieces.map { piece in
            switch piece {
            case .text(let text): return Canvas.measure(text, style: style).width
            case .key(let key): return max(capHeight, Canvas.measure(key, style: capStyle).width + 10)
            }
        }
        let total = widths.reduce(0, +) + gap * Float(max(0, pieces.count - 1))
        let height = max(capHeight, Canvas.measure("Ag", style: style).height)
        guard let canvas else { return SizeF(width: total, height: height) }
        var x = centreX - total / 2
        for (piece, width) in zip(pieces, widths) {
            switch piece {
            case .text(let text):
                let size = Canvas.measure(text, style: style)
                canvas.text(text, at: PointF(x: x, y: top + (height - size.height) / 2), style: style, colour)
            case .key(let key):
                let cap = RectF(x: x, y: top + (height - capHeight) / 2, width: width, height: capHeight)
                canvas.fill(cap, radius: Theme.Radius.keycap, Colour.white.opacity(0.08))
                canvas.stroke(cap.insetBy(0.5, 0.5), radius: Theme.Radius.keycap, width: 1,
                              Colour.white.opacity(highContrast ? 0.45 : 0.22))
                canvas.text(key, in: cap, style: TextStyle(size: capStyle.size, weight: capStyle.weight,
                                                           monospacedDigits: true, align: .center),
                            Colour.white.opacity(highContrast ? 0.85 : 0.75))
            }
            x += width + gap
        }
        return SizeF(width: total, height: height)
    }

    // MARK: Coach line

    enum Pointing { case up, leading }

    static let coachStyle = TextStyle(size: 16)

    /// The size of a coach line with its pointer.
    static func coachSize(_ text: String, pointing: Pointing) -> SizeF {
        let words = Canvas.measure(text, style: coachStyle)
        let capsule = SizeF(width: words.width + 2 * Theme.Spacing.m, height: OverlayMetrics.coachHeight)
        switch pointing {
        case .up: return SizeF(width: capsule.width, height: OverlayMetrics.coachStem + capsule.height)
        case .leading: return SizeF(width: OverlayMetrics.coachStem + capsule.width, height: capsule.height)
        }
    }

    /// A coach line on the break screen (SPEC §3.12): a capsule of 16 pt words on a dark scrim, with
    /// a hairline pointer ending in the coach dot, up to the agent chip or left to the controls.
    /// `origin` is the top left of the whole (pointer included).
    static func coachLine(_ canvas: Canvas, _ text: String, pointing: Pointing, origin: PointF, highContrast: Bool) {
        let size = coachSize(text, pointing: pointing)
        let stem = OverlayMetrics.coachStem
        let line = Colour.white.opacity(highContrast ? 0.8 : 0.55)
        let capsule: RectF
        switch pointing {
        case .up:
            let cx = origin.x + size.width / 2
            canvas.line(PointF(x: cx, y: origin.y + 7), PointF(x: cx, y: origin.y + stem), width: 1, line, round: false)
            HintLine.dot(canvas, centre: PointF(x: cx, y: origin.y + 4.5))
            capsule = RectF(x: origin.x, y: origin.y + stem, width: size.width, height: OverlayMetrics.coachHeight)
        case .leading:
            let cy = origin.y + size.height / 2
            canvas.line(PointF(x: origin.x + 7, y: cy), PointF(x: origin.x + stem, y: cy), width: 1, line, round: false)
            HintLine.dot(canvas, centre: PointF(x: origin.x + 4.5, y: cy))
            capsule = RectF(x: origin.x + stem, y: origin.y, width: size.width - stem, height: OverlayMetrics.coachHeight)
        }
        let radius = capsule.height / 2
        canvas.fill(capsule, radius: radius, Theme.Palette.scrim.opacity(highContrast ? 0.85 : 0.42))
        canvas.stroke(capsule.insetBy(0.5, 0.5), radius: radius, width: 1, Colour.white.opacity(highContrast ? 0.40 : 0.16))
        canvas.text(text, in: capsule, style: TextStyle(size: coachStyle.size, align: .center),
                    Colour.white.opacity(highContrast ? 1 : Theme.TextStep.body.opacity))
    }

    // MARK: Cue chip

    /// The `move` cue chip and the `walk` idea chip (SPEC §3.4): capsule 24, 12% white, 12 pt
    /// semibold at 85%. Returns its width.
    @discardableResult
    static func cueChip(_ canvas: Canvas?, _ text: String, centreX: Float, top: Float) -> Float {
        let style = TextStyle(size: 12, weight: 600)
        let size = Canvas.measure(text, style: style)
        let width = size.width + 20
        guard let canvas else { return width }
        let rect = RectF(x: centreX - width / 2, y: top, width: width, height: OverlayMetrics.cueChipHeight)
        canvas.fill(rect, radius: rect.height / 2, Colour.white.opacity(0.12))
        canvas.text(text, at: PointF(x: rect.x + 10, y: rect.midY - size.height / 2), style: style,
                    Colour.white.opacity(Theme.TextStep.body.opacity))
        return width
    }

    /// The small mint "Rehearsal" chip (20 DIPs, 11 pt semibold, mint text on 16% mint).
    @discardableResult
    static func smallMintChip(_ canvas: Canvas?, _ text: String, at origin: PointF) -> Float {
        let style = TextStyle(size: 11, weight: 600)
        let size = Canvas.measure(text, style: style)
        let width = size.width + 16
        guard let canvas else { return width }
        let rect = RectF(x: origin.x, y: origin.y, width: width, height: OverlayMetrics.smallChipHeight)
        canvas.fill(rect, radius: rect.height / 2, Theme.Palette.mint.opacity(0.16))
        canvas.text(text, at: PointF(x: rect.x + 8, y: rect.midY - size.height / 2), style: style, Theme.Palette.mint)
        return width
    }
}
