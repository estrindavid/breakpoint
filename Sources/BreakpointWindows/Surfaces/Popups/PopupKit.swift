import BreakpointCore
import BreakpointRuntime
import Foundation
import WinSDK

// The pop-ups' own parts on Windows (SPEC §3.0, §3.5, §4.4): the macOS pop-ups' capsule buttons
// and keycaps (`PillButton`, `Keycap`), their badge glyphs, cached text fitting, and the pointer
// model of `PopupModel` (hover that ignores a parked pointer, the 300 ms reveal).

/// A pop-up's capsule buttons, as `PillButton` draws them on dark glass:
/// - `primary`: 10% white fill (Start, Update);
/// - `secondary`: a 1 DIP outline at 14% white (30% under high contrast);
/// - `tertiary`: text only at 75% (Undo, Resume);
/// - `mint`: mint fill with the dark label (Wrap up, Copy note).
/// Hover adds 6% white; pressed darkens a little. Regular 34 DIPs / 15 semibold, small 28 / 13.
@MainActor
enum PopupPill {
    enum Role { case primary, secondary, tertiary, mint }
    enum Size {
        case regular, small
        var height: Float { self == .regular ? Theme.Size.buttonHeight : Theme.Size.smallButtonHeight }
        var font: TextStyle { TextStyle(size: self == .regular ? 15 : 13, weight: 600) }
        var padding: Float { self == .regular ? Theme.Size.buttonPadding : 12 }
    }

    /// A resting keycap: laid out, so nothing moves when it comes forward, but faint.
    static let quietKeycapOpacity: Float = 0.4

    static func width(_ title: String, role: Role = .primary, size: Size, keycap: String? = nil, icon: Bool = false) -> Float {
        var width = Canvas.measure(title, style: size.font).width
        if icon { width += 12 + 6 }
        if let keycap { width += 6 + PopupKeycap.width(keycap, compact: true) }
        let padding = role == .tertiary ? 6 : size.padding
        return max(role == .tertiary ? 0 : size.height, (width + 2 * padding).rounded(.up))
    }

    /// Draws the button with its left edge at `origin.x`, vertically from `origin.y`; returns its
    /// rect. `canvas` nil only measures. `keycapQuiet` draws the keycap faint.
    @discardableResult
    static func draw(_ canvas: Canvas?, _ controls: Controls?, id: String, at origin: PointF, _ title: String,
                     role: Role = .primary, size: Size = .regular, keycap: String? = nil, keycapQuiet: Bool = false,
                     icon: String? = nil, action: @escaping () -> Void) -> RectF {
        let rect = RectF(x: origin.x, y: origin.y, width: width(title, role: role, size: size, keycap: keycap, icon: icon != nil),
                         height: size.height)
        guard let canvas else { return rect }
        let hot = controls?.isHovered(id) ?? false
        let down = controls?.isPressed(id) ?? false
        let radius = rect.height / 2
        let contrast = Appearance.highContrast
        let label: Colour = role == .mint ? Theme.Palette.onMint : Colour.white.opacity(Theme.TextStep.label.opacity)
        switch role {
        case .primary:
            canvas.fill(rect, radius: radius, Colour.white.opacity(0.10 + (hot ? 0.06 : 0) + (down ? 0.04 : 0)))
            canvas.stroke(rect.insetBy(0.5, 0.5), radius: radius - 0.5, width: 1, Colour.white.opacity(contrast ? 0.30 : 0.06))
        case .secondary:
            if hot || down { canvas.fill(rect, radius: radius, Colour.white.opacity(down ? 0.10 : 0.06)) }
            canvas.stroke(rect.insetBy(0.5, 0.5), radius: radius - 0.5, width: 1, Colour.white.opacity(contrast ? 0.30 : 0.14))
        case .tertiary:
            if hot || down { canvas.fill(rect, radius: radius, Colour.white.opacity(down ? 0.06 : 0.03)) }
        case .mint:
            let mint = Theme.Palette.mint
            canvas.fill(rect, radius: radius, down ? mint.mixed(with: .black, 0.12) : (hot ? mint.mixed(with: .white, 0.12) : mint))
        }
        // Title, icon and keycap centred together.
        let titleSize = Canvas.measure(title, style: size.font)
        var content = titleSize.width
        if icon != nil { content += 18 }
        let capWidth = keycap.map { PopupKeycap.width($0, compact: true) } ?? 0
        if keycap != nil { content += 6 + capWidth }
        var x = rect.midX - content / 2
        if let icon {
            PopupGlyph.draw(icon, on: canvas, centre: PointF(x: x + 6, y: rect.midY), size: 11, label)
            x += 18
        }
        canvas.text(title, at: PointF(x: x, y: rect.midY - titleSize.height / 2), style: size.font, label)
        x += titleSize.width
        if let keycap {
            let cap = RectF(x: x + 6, y: rect.midY - 8, width: capWidth, height: 16)
            PopupKeycap.draw(canvas, cap, keycap, compact: true, tint: label, opacity: keycapQuiet ? quietKeycapOpacity : 1)
        }
        if let controls {
            PopupFocus.ring(canvas, controls, id: id, rect, radius: radius)
            controls.region(id, rect, focusable: true, action: action)
        }
        return rect
    }
}

/// A key drawn as a keycap (`Keycap`): a rounded rectangle with a 1 DIP rim; compact 16 DIPs tall
/// (10 medium) inside buttons, regular 18 (11 medium).
@MainActor
enum PopupKeycap {
    static func style(compact: Bool) -> TextStyle { TextStyle(size: compact ? 10 : 11, weight: 500, monospacedDigits: true) }

    static func width(_ label: String, compact: Bool) -> Float {
        let minimum: Float = compact ? 16 : 18
        return max(minimum, (Canvas.measure(label, style: style(compact: compact)).width + 2 * (compact ? 3 : 5)).rounded(.up))
    }

    static func draw(_ canvas: Canvas, _ rect: RectF, _ label: String, compact: Bool, tint: Colour = .white, opacity: Float = 1) {
        let contrast = Appearance.highContrast
        canvas.withOpacity(opacity) {
            canvas.fill(rect, radius: Theme.Radius.keycap, tint.opacity(0.10))
            canvas.stroke(rect.insetBy(0.5, 0.5), radius: Theme.Radius.keycap - 0.5, width: 1, tint.opacity(contrast ? 0.45 : 0.22))
            var style = style(compact: compact)
            style.align = .center
            canvas.text(label, in: rect, style: style, tint.opacity(contrast ? 0.95 : 0.85))
        }
    }
}

@MainActor
enum PopupFocus {
    /// The 2 DIP mint keyboard-focus ring (60%), 3 DIPs outside, once the keyboard has been used.
    static func ring(_ canvas: Canvas, _ controls: Controls, id: String, _ rect: RectF, radius: Float) {
        guard controls.isFocusVisible(id) else { return }
        canvas.stroke(rect.insetBy(-3, -3), radius: radius + 3, width: 2, Theme.Palette.mint.opacity(0.6))
    }
}

/// Glyphs the pop-ups need beyond `Glyphs` (the resume card's raised hand and "!", the update
/// card's arrow), drawn as vectors; everything else goes to `Glyphs.draw`.
@MainActor
enum PopupGlyph {
    static func draw(_ symbol: String, on canvas: Canvas, centre c: PointF, size: Float, _ colour: Colour) {
        switch symbol {
        case "exclamationmark":
            let w = max(1.6, size * 0.16)
            canvas.line(PointF(x: c.x, y: c.y - size * 0.42), PointF(x: c.x, y: c.y + size * 0.14), width: w, colour)
            canvas.circle(PointF(x: c.x, y: c.y + size * 0.4), radius: w * 0.62, colour)
        case "arrow.down":
            let w = max(1.6, size * 0.15)
            canvas.line(PointF(x: c.x, y: c.y - size * 0.42), PointF(x: c.x, y: c.y + size * 0.4), width: w, colour)
            canvas.path("MLL", [c.x - size * 0.32, c.y + size * 0.1, c.x, c.y + size * 0.42, c.x + size * 0.32, c.y + size * 0.1],
                        colour, stroke: w)
        case "hand.raised.fill":
            hand(canvas, c, size, colour)
        default:
            Glyphs.draw(symbol, on: canvas, centre: c, size: size, colour, weight: 1.15)
        }
    }

    /// A raised open hand: four fingers, the thumb, the palm.
    private static func hand(_ canvas: Canvas, _ c: PointF, _ size: Float, _ colour: Colour) {
        let u = size / 24
        let finger = 3.4 * u
        let tops: [Float] = [6.2, 3.6, 4.2, 6.6]
        for (index, top) in tops.enumerated() {
            let x = c.x + (Float(index) * 3.9 - 5.8) * u
            canvas.fill(RectF(x: x - finger / 2, y: c.y + (top - 12) * u, width: finger, height: (14 - top) * u + finger),
                        radius: finger / 2, colour)
        }
        // Thumb, leaning out.
        canvas.line(PointF(x: c.x - 6.6 * u, y: c.y + 5.6 * u), PointF(x: c.x - 10.4 * u, y: c.y + 0.6 * u), width: finger, colour)
        canvas.fill(RectF(x: c.x - 7.6 * u, y: c.y + 0.4 * u, width: 15.4 * u, height: 11 * u), radius: 4.6 * u, colour)
    }
}

/// The single coloured badge, as `KindBadge` on the Mac: brand gradient, indigo, amber or grey,
/// a faint 0.5 DIP rim, the glyph in white (dark on amber), and the optional auto-start ring.
@MainActor
enum PopupBadge {
    static func draw(_ canvas: Canvas, centre: PointF, diameter: Float, symbol: String, tone: Tone, ringProgress: Double? = nil) {
        let radius = diameter / 2
        let rect = RectF(x: centre.x - radius, y: centre.y - radius, width: diameter, height: diameter)
        switch tone {
        case .brand: canvas.gradient(rect, radius: radius, from: Theme.Palette.mint, to: Theme.Palette.indigo, angle: 45)
        case .neutral: canvas.circle(centre, radius: radius, Colour.white.opacity(0.22))
        default: canvas.circle(centre, radius: radius, Theme.Palette.solid(for: tone))
        }
        canvas.ring(centre, radius: radius - 0.25, width: 0.5, Colour.white.opacity(0.18))
        let glyph = tone == .needsYou || tone == .mint ? Theme.Palette.onAccent : Colour.white
        PopupGlyph.draw(symbol, on: canvas, centre: centre, size: (diameter * Theme.Size.badgeSymbol / Theme.Size.badge).rounded(), glyph)
        if let ringProgress {
            ProgressRing.draw(canvas, centre: centre, radius: radius + 3, width: 2, progress: ringProgress,
                              tint: Colour.white.opacity(0.8), track: .clear)
        }
    }
}

/// Text fitted to a width (`Truncate`), remembered so a redraw measures nothing new.
@MainActor
enum PopupText {
    private struct Key: Hashable {
        let text: String
        let style: TextStyle
        let width: Float
        let mode: Int
    }

    private static var cache: [Key: String] = [:]

    static func tail(_ text: String, _ style: TextStyle, _ width: Float) -> String { fit(text, style, width, mode: 0) }
    static func middle(_ text: String, _ style: TextStyle, _ width: Float) -> String { fit(text, style, width, mode: 1) }

    /// At most `lines` wrapped lines, the last ending in "…" when the text runs on.
    static func lines(_ text: String, _ style: TextStyle, _ width: Float, max lines: Int) -> String {
        let key = Key(text: text, style: style, width: width, mode: 10 + lines)
        if let found = cache[key] { return found }
        let lineHeight = Canvas.measure("Ag", style: TextStyle(size: style.size, weight: style.weight)).height
        let limit = lineHeight * Float(lines) + 1
        var result = text
        if Canvas.measure(text, style: style, width: width).height > limit {
            var words = text.split(separator: " ").map(String.init)
            while words.count > 1 {
                words.removeLast()
                let candidate = words.joined(separator: " ") + "…"
                if Canvas.measure(candidate, style: style, width: width).height <= limit {
                    result = candidate
                    break
                }
            }
        }
        remember(key, result)
        return result
    }

    private static func fit(_ text: String, _ style: TextStyle, _ width: Float, mode: Int) -> String {
        let key = Key(text: text, style: style, width: width, mode: mode)
        if let found = cache[key] { return found }
        let result = mode == 0 ? Truncate.tail(text, style: style, width: width) : Truncate.middle(text, style: style, width: width)
        remember(key, result)
        return result
    }

    private static func remember(_ key: Key, _ value: String) {
        if cache.count > 256 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
    }

    /// The height of one line of `style`.
    static func lineHeight(_ style: TextStyle) -> Float {
        Canvas.measure("Ag", style: TextStyle(size: style.size, weight: style.weight, family: style.family)).height
    }
}

/// The pointer over one pop-up (`PopupModel` + `PopupHostingView` on the Mac):
/// - a pop-up that appears under a pointer nobody is moving is not hovered (a parked pointer
///   would hold its timeout forever and cancel an eye-rest auto-start at once): hover counts from
///   the pointer's first real movement;
/// - `revealed` follows after the pointer rests 300 ms (the nudge's ×, why-now and keycaps).
@MainActor
final class PopupHover {
    private(set) var inside = false
    private(set) var revealed = false
    /// Hover changed (true: the pointer came onto the card).
    var onHover: ((Bool) -> Void)?
    /// Anything visible changed (hover or reveal): redraw.
    var onChange: (() -> Void)?
    private var parked: POINT?
    private var revealTimer: Timer?

    init(_ window: DrawnWindow) {
        let forward = window.window.onMouseMove
        window.window.onMouseMove = { [weak self] point in
            forward?(point)
            self?.moved()
        }
        window.controls.onHoverChange = { [weak self] inside in
            if !inside { self?.set(false) }
        }
    }

    /// The card just appeared or moved: a pointer resting where it is now does not count.
    func park() {
        var cursor = POINT()
        GetCursorPos(&cursor)
        parked = cursor
    }

    func cancel() {
        revealTimer?.invalidate()
        revealTimer = nil
    }

    private func moved() {
        guard !inside else { return }
        if let parked {
            var cursor = POINT()
            GetCursorPos(&cursor)
            guard cursor.x != parked.x || cursor.y != parked.y else { return }
            self.parked = nil
        }
        set(true)
    }

    private func set(_ value: Bool) {
        if !value { parked = nil }
        guard value != inside else { return }
        inside = value
        revealTimer?.invalidate()
        revealTimer = nil
        if value {
            let timer = Timer.after(0.3, repeats: false) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.inside else { return }
                    self.revealed = true
                    self.onChange?()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            revealTimer = timer
        } else {
            revealed = false
        }
        onHover?(value)
        onChange?()
    }
}

/// A pop-up's chrome where no window draws it (the stacked snapshot): the solid pop-up colour
/// and the faint top light, in the window's rounded shape.
@MainActor
enum PopupChrome {
    static func card(_ canvas: Canvas, _ rect: RectF) {
        canvas.shadow(rect, radius: Theme.Radius.card, blur: 18, offset: PointF(x: 0, y: 6), Colour.black.opacity(0.35))
        canvas.fill(rect, radius: Theme.Radius.card, Theme.Palette.solidPopup)
        canvas.clipped(to: rect, radius: Theme.Radius.card) {
            canvas.gradient(RectF(x: rect.x, y: rect.y, width: rect.width, height: min(56, rect.height)), radius: 0,
                            from: Colour.white.opacity(0.06), to: Colour.white.opacity(0), angle: 90)
        }
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: Theme.Radius.card, width: 1, Colour.white.opacity(0.10))
    }
}
