import BreakpointCore
import BreakpointRuntime
import Foundation

// The design system's small parts on Windows (SPEC §4), drawn by every surface: the pop-up
// chrome, the kind badge, the progress ring, status dots and chips, the source tile, the hint
// line. Same sizes and colours as the macOS components in BreakpointKit/Design.

@MainActor
public enum Chrome {
    /// A pop-up's or the flyout's background. Over the Acrylic backdrop a dark tint keeps white
    /// text legible on any wallpaper; opaque (transparency effects off, Windows 10) the solid
    /// pop-up colour. A faint top light gives the glass its edge, as on the Mac.
    public static func popupBackground(_ canvas: Canvas, tint: Colour? = nil) {
        let bounds = canvas.bounds
        if Appearance.prefersOpaque || canvas.isOffscreen {
            canvas.fill(bounds, Theme.Palette.solidPopup)
        } else {
            canvas.fill(bounds, Theme.Palette.solidPopup.opacity(Appearance.highContrast ? 0.92 : 0.58))
        }
        if let tint { canvas.fill(bounds, tint) }
        canvas.gradient(RectF(x: 0, y: 0, width: bounds.width, height: min(56, bounds.height)), radius: 0,
                        from: Colour.white.opacity(0.06), to: Colour.white.opacity(0), angle: 90)
    }

    /// An inset card inside the flyout (agents list, decision line).
    public static func insetCard(_ canvas: Canvas, _ rect: RectF) {
        canvas.fill(rect, radius: Theme.Radius.insetCard, Colour.white.opacity(0.06))
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: Theme.Radius.insetCard, width: 1, Colour.white.opacity(0.07))
    }
}

/// The single coloured badge of a pop-up (SPEC §3.0, §3.1): a circle in the Breakpoint gradient
/// (break kinds), indigo (agent working) or amber (needs you), with a white glyph; optionally the
/// 2 DIP white ring sweeping around it during eye-rest auto-start.
@MainActor
public enum KindBadge {
    public static func draw(_ canvas: Canvas, centre: PointF, diameter: Float = Theme.Size.badge, symbol: String,
                            tone: Tone = .brand, ringProgress: Double? = nil) {
        let radius = diameter / 2
        let rect = RectF(x: centre.x - radius, y: centre.y - radius, width: diameter, height: diameter)
        switch tone {
        case .brand:
            canvas.gradient(rect, radius: radius, from: Theme.Palette.mint, to: Theme.Palette.indigo, angle: 45)
        default:
            canvas.circle(centre, radius: radius, Theme.Palette.solid(for: tone))
        }
        let glyphColour = tone == .needsYou || tone == .mint ? Theme.Palette.onAccent : Colour.white
        Glyphs.draw(symbol, on: canvas, centre: centre, size: diameter * Theme.Size.badgeSymbol / Theme.Size.badge,
                    glyphColour, weight: 1.15)
        if let ringProgress {
            ProgressRing.draw(canvas, centre: centre, radius: radius + 4, width: 2, progress: ringProgress,
                              tint: Colour.white.opacity(0.8), track: .clear)
        }
    }
}

@MainActor
public enum ProgressRing {
    /// A ring from 12 o'clock, clockwise, with round caps over a track.
    public static func draw(_ canvas: Canvas, centre: PointF, radius: Float, width: Float, progress: Double,
                            tint: Colour = Theme.Palette.mint, track: Colour = Colour.white.opacity(0.14)) {
        if track.a > 0 { canvas.ring(centre, radius: radius, width: width, track) }
        let p = Float(min(max(progress, 0), 1))
        guard p > 0.001 else { return }
        if p > 0.999 {
            canvas.ring(centre, radius: radius, width: width, tint)
        } else {
            canvas.arc(centre, radius: radius, from: 0, to: p, width: width, tint)
        }
    }
}

@MainActor
public enum StatusDot {
    public enum Style { case filled, hollow }

    /// The working dot's pulse at 0.5 Hz (SPEC §4.6), 0.4…1; steady under Reduce Motion.
    public static func pulseOpacity(at date: Date) -> Float {
        guard !Appearance.reduceMotion else { return 1 }
        let phase = date.timeIntervalSinceReferenceDate * 0.5 * 2 * .pi
        return Float(0.7 + 0.3 * cos(phase))
    }

    public static func draw(_ canvas: Canvas, centre: PointF, diameter: Float = Theme.Size.agentChipDot, tone: Tone,
                            style: Style = .filled, opacity: Float = 1) {
        let colour = Theme.Palette.solid(for: tone).opacity(opacity)
        switch style {
        case .filled: canvas.circle(centre, radius: diameter / 2, colour)
        case .hollow:
            let width = max(1.5, diameter / 5)
            canvas.ring(centre, radius: diameter / 2 - width / 2, width: width, colour)
        }
    }
}

@MainActor
public enum Chip {
    /// A capsule with an optional dot and a label; returns its width. `height` 28 (agent chip) or
    /// 20 (small status chips).
    @discardableResult
    public static func draw(_ canvas: Canvas, at origin: PointF, text: String, tone: Tone?, height: Float = Theme.Size.agentChipHeight,
                            style: TextStyle = Theme.Typography.agentChip, dotOpacity: Float = 1, dotStyle: StatusDot.Style = .filled,
                            fill: Colour = Colour.white.opacity(0.10)) -> Float {
        let style = TextStyle(size: style.size, weight: style.weight)
        let textSize = Canvas.measure(text, style: style)
        let dot: Float = tone == nil ? 0 : (height >= 24 ? Theme.Size.agentChipDot : 6)
        let padding: Float = height >= 24 ? 12 : 8
        let width = padding * 2 + textSize.width + (dot > 0 ? dot + 7 : 0)
        let rect = RectF(x: origin.x, y: origin.y, width: width, height: height)
        canvas.fill(rect, radius: height / 2, fill)
        var x = rect.x + padding
        if let tone {
            StatusDot.draw(canvas, centre: PointF(x: x + dot / 2, y: rect.midY), diameter: dot, tone: tone, style: dotStyle,
                           opacity: dotOpacity)
            x += dot + 7
        }
        canvas.text(text, at: PointF(x: x, y: rect.midY - textSize.height / 2), style: style,
                    tone.map { Theme.Palette.solid(for: $0).mixed(with: .white, 0.35) } ?? Colour.white.opacity(0.85))
        return width
    }

    public static func width(text: String, hasDot: Bool, height: Float = Theme.Size.agentChipHeight,
                             style: TextStyle = Theme.Typography.agentChip) -> Float {
        let padding: Float = height >= 24 ? 12 : 8
        let dot: Float = hasDot ? (height >= 24 ? Theme.Size.agentChipDot : 6) + 7 : 0
        return padding * 2 + Canvas.measure(text, style: TextStyle(size: style.size, weight: style.weight)).width + dot
    }
}

@MainActor
public enum SourceTile {
    /// A rounded-square tile holding a source glyph (SPEC §3.8 agent rows), neutral.
    public static func draw(_ canvas: Canvas, _ rect: RectF, symbol: String, look: Look = .dark) {
        let radius = rect.width * Theme.Radius.sourceTile / 20
        canvas.fill(rect, radius: radius, look.dark ? Colour.white.opacity(0.12) : Colour.black.opacity(0.06))
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: radius, width: 1, look.dark ? Colour.white.opacity(0.08) : Colour.black.opacity(0.06))
        Glyphs.draw(symbol, on: canvas, centre: PointF(x: rect.midX, y: rect.midY), size: (rect.width * 0.55).rounded(),
                    look.dark ? Colour.white.opacity(0.85) : look.text.opacity(0.75))
    }
}

@MainActor
public enum HintLine {
    /// The coach dot (SPEC §3.12): a mint dot in a faint ring.
    public static func dot(_ canvas: Canvas, centre: PointF) {
        canvas.circle(centre, radius: 7, Theme.Palette.scrim.opacity(0.35))
        canvas.ring(centre, radius: 6.5, width: 1, Theme.Palette.mint.opacity(Appearance.highContrast ? 1 : 0.7))
        canvas.circle(centre, radius: 2, Theme.Palette.mint)
    }

    /// A first-use hint: the coach dot and one or two lines; returns its height.
    @discardableResult
    public static func draw(_ canvas: Canvas, at origin: PointF, width: Float, text: String) -> Float {
        let style = Theme.Typography.coach
        let size = Canvas.measure(text, style: style, width: width - 22)
        dot(canvas, centre: PointF(x: origin.x + 7, y: origin.y + min(9, size.height / 2)))
        canvas.text(text, at: PointF(x: origin.x + 22, y: origin.y), width: width - 22, style: style,
                    Colour.white.opacity(Appearance.highContrast ? 0.95 : Theme.TextStep.body.opacity))
        return max(18, size.height)
    }

    public static func height(width: Float, text: String) -> Float {
        max(18, Canvas.measure(text, style: Theme.Typography.coach, width: width - 22).height)
    }
}
