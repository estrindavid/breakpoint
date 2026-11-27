import BreakpointCore
import BreakpointRuntime
import Foundation

// The settings building blocks on Windows (SPEC §3.9), the counterparts of the macOS
// `SettingsSection`, `SettingRow`, `SentenceRow`, `PresetCard` and friends
// (Sources/BreakpointKit/Design/SettingsComponents.swift, Settings/SettingsSupport.swift):
// 13 DIP bold section titles over rounded cards 24 DIPs apart, rows at least 40 tall with a 24 DIP
// grey round icon, a 13 DIP title, an 11 DIP description and the control on the right.
//
// Everything is laid out by one cursor (`SettingsPage.y`) that both measures (no canvas) and
// draws, so a pane's height always matches what it draws.

/// Sizes of the settings window (SPEC §3.9; the window's default size is `Theme.Size.settingsSize`).
enum SettingsMetrics {
    static let sidebarWidth: Float = 200
    static let headerHeight: Float = 52
    static let minimumSize = SizeF(width: 720, height: 560)
    static let paneMaxWidth: Float = 640
    static let paneInset: Float = 24
    static let paneTop: Float = 20
    static let paneBottom: Float = 32
    static let sectionGap: Float = 24
    static let rowMinHeight: Float = 40
    static let rowIcon: Float = 24
    static let rowInset: Float = 12
    static let tile: Float = 20
    static let smallButtonHeight: Float = 26
}

/// One trailing control of a row, with the width it takes.
@MainActor
struct SettingsTrailing {
    let width: Float
    let height: Float
    /// The control's id, for scrolling it into view when it takes the focus.
    let id: String?
    let draw: (Canvas, Controls, RectF) -> Void

    init(width: Float, height: Float, id: String? = nil, draw: @escaping (Canvas, Controls, RectF) -> Void) {
        self.width = width; self.height = height; self.id = id; self.draw = draw
    }

    static func toggle(_ id: String, isOn: Bool, enabled: Bool = true, action: @escaping (Bool) -> Void) -> SettingsTrailing {
        SettingsTrailing(width: 40, height: 20, id: id) { canvas, controls, rect in
            controls.toggle(canvas, id: id, at: PointF(x: rect.x, y: rect.y), isOn: isOn, enabled: enabled, action: action)
        }
    }

    static func button(_ id: String, _ title: String, role: Controls.Role = .secondary, enabled: Bool = true,
                       minWidth: Float = 0, action: @escaping () -> Void) -> SettingsTrailing {
        let width = max(minWidth, Canvas.measure(title, style: Theme.Typography.smallButton).width + 28)
        return SettingsTrailing(width: width, height: SettingsMetrics.smallButtonHeight, id: id) { canvas, controls, rect in
            controls.button(canvas, id: id, rect, title, role: role, enabled: enabled, action: action)
        }
    }

    static func checkbox(_ id: String, isOn: Bool, enabled: Bool, action: @escaping (Bool) -> Void) -> SettingsTrailing {
        SettingsTrailing(width: 18, height: 20, id: id) { canvas, controls, rect in
            if enabled {
                controls.checkbox(canvas, id: id, at: PointF(x: rect.x, y: rect.y), label: "", isOn: isOn, action: action)
            } else {
                canvas.withOpacity(0.45) {
                    let box = RectF(x: rect.x, y: rect.y + 1, width: 18, height: 18)
                    SettingsDraw.checkbox(canvas, box, isOn: isOn, look: controls.look)
                }
            }
        }
    }

    /// ▶ that previews a sound or a routine.
    static func play(_ id: String, action: @escaping () -> Void) -> SettingsTrailing {
        SettingsTrailing(width: 24, height: 24, id: id) { canvas, controls, rect in
            let look = controls.look
            let hot = controls.isHovered(id)
            let centre = PointF(x: rect.midX, y: rect.midY)
            canvas.circle(centre, radius: 12, hot ? look.fillHover : look.fill)
            canvas.ring(centre, radius: 11.5, width: 1, look.stroke)
            canvas.path("MLLZ", [centre.x - 3, centre.y - 4.5, centre.x + 4.5, centre.y, centre.x - 3, centre.y + 4.5], look.text)
            controls.region(id, rect, focusable: true, action: action)
            SettingsDraw.focusRing(canvas, controls, id: id, rect, radius: 12)
        }
    }

    /// A small busy spinner (a row's install running, an update being checked).
    static func spinner(phase: Double) -> SettingsTrailing {
        SettingsTrailing(width: 20, height: 20) { canvas, controls, rect in
            SettingsDraw.spinner(canvas, centre: PointF(x: rect.midX, y: rect.midY), radius: 7, colour: controls.look.secondary,
                                 phase: phase)
        }
    }

    static func custom(width: Float, height: Float, id: String? = nil,
                       draw: @escaping (Canvas, Controls, RectF) -> Void) -> SettingsTrailing {
        SettingsTrailing(width: width, height: height, id: id, draw: draw)
    }
}

/// One piece of a sentence row: words, or a pop-up of values inside the sentence.
@MainActor
enum SentencePart {
    case text(String)
    case menu(id: String, title: String, items: [(String, Bool, () -> Void)])
    /// Any other control, `width` wide and 28 tall (the stop time's stepper).
    case control(id: String, width: Float, draw: (Canvas, Controls, RectF) -> Void)

    var width: Float {
        switch self {
        case .text(let words): return Canvas.measure(words, style: Theme.Typography.row).width
        case .menu(_, let title, _): return SettingsDraw.menuWidth(title)
        case .control(_, let width, _): return width
        }
    }
}

/// The layout cursor of one pane (or one section's inside): a column `width` wide at `x`, with
/// `y` moving down. With `canvas` nil it only measures.
@MainActor
struct SettingsPage {
    let canvas: Canvas?
    let controls: Controls?
    /// Draws controls that take no input (a dimmed section, what lies under a sheet).
    let inert: Controls?
    let look: Look
    let x: Float
    let width: Float
    var y: Float
    /// Where each control was drawn, in content coordinates (for scrolling the focus into view).
    let frames: SettingsFrames?
    let scroll: Float
    /// The top of the visible pane: a control scrolled above it (under the header) takes no input.
    let viewportTop: Float

    var isDrawing: Bool { canvas != nil }

    init(canvas: Canvas?, controls: Controls?, inert: Controls?, look: Look, x: Float, width: Float, y: Float,
         frames: SettingsFrames? = nil, scroll: Float = 0, viewportTop: Float = -.greatestFiniteMagnitude) {
        self.canvas = canvas; self.controls = controls; self.inert = inert; self.look = look
        self.x = x; self.width = width; self.y = y; self.frames = frames; self.scroll = scroll; self.viewportTop = viewportTop
    }

    func inset(_ dx: Float, y: Float? = nil, disabled: Bool = false) -> SettingsPage {
        SettingsPage(canvas: canvas, controls: disabled ? inert : controls, inert: inert, look: look, x: x + dx,
                     width: width - 2 * dx, y: y ?? self.y, frames: frames, scroll: scroll, viewportTop: viewportTop)
    }

    /// The controls a control at `rect` registers with: the live ones while it is fully visible,
    /// else the inert ones (it is drawn, but under the header it must not take clicks).
    func live(_ rect: RectF) -> Controls? {
        guard let controls else { return nil }
        return rect.minY >= viewportTop - 0.5 ? controls : (inert ?? controls)
    }

    mutating func gap(_ height: Float) { y += height }

    func record(_ id: String, _ rect: RectF) {
        frames?.rects[id] = RectF(x: rect.x, y: rect.y + scroll, width: rect.width, height: rect.height)
    }

    // MARK: Text

    var secondary: Colour { look.secondary }

    /// A paragraph in the column; returns its height.
    @discardableResult
    mutating func paragraph(_ text: String, style: TextStyle = TextStyle(size: 13, wrap: true), colour: Colour? = nil,
                            indent: Float = 4) -> Float {
        let size = Canvas.measure(text, style: style, width: width - 2 * indent)
        canvas?.text(text, at: PointF(x: x + indent, y: y), width: width - 2 * indent, style: style, colour ?? look.secondary)
        y += size.height
        return size.height
    }

    // MARK: Sections

    /// "Pace"…: 13 DIP bold, with an optional detail on the right.
    mutating func sectionHeader(_ title: String, detail: String? = nil) {
        if let canvas {
            canvas.text(title, at: PointF(x: x + 4, y: y), style: Theme.Typography.sectionTitle, look.text)
            if let detail {
                let style = TextStyle(size: 11, align: .trailing)
                canvas.text(detail, at: PointF(x: x + 4, y: y + 2), width: width - 8, style: style, look.secondary)
            }
        }
        y += 17 + 8
    }

    /// An inset grouped section: an optional title, then `rows` on a rounded card; 24 DIPs follow.
    /// A disabled section is drawn at half opacity and takes no input.
    mutating func section(_ title: String? = nil, enabled: Bool = true, _ rows: (inout SettingsPage) -> Void) {
        if let title { sectionHeader(title) }
        var measure = SettingsPage(canvas: nil, controls: nil, inert: nil, look: look, x: x + SettingsMetrics.rowInset,
                                   width: width - 2 * SettingsMetrics.rowInset, y: 0)
        rows(&measure)
        let height = measure.y
        if let canvas {
            let card = RectF(x: x, y: y, width: width, height: height)
            SettingsDraw.card(canvas, card, look: look)
            var inner = inset(SettingsMetrics.rowInset, disabled: !enabled)
            canvas.withOpacity(enabled ? 1 : 0.5) { rows(&inner) }
        }
        y += height + SettingsMetrics.sectionGap
    }

    /// A quiet 11 DIP line under a section, aligned with its text.
    mutating func footnote(_ text: String, symbol: String? = nil) {
        y -= 16
        let indent: Float = symbol == nil ? 4 : 20
        let style = Theme.Typography.rowDescription
        let size = Canvas.measure(text, style: style, width: width - indent - 4)
        if let canvas {
            if let symbol {
                SettingsGlyph.draw(symbol, on: canvas, centre: PointF(x: x + 10, y: y + 7), size: 10, look.secondary)
            }
            canvas.text(text, at: PointF(x: x + indent, y: y), width: width - indent - 4, style: style, look.secondary)
        }
        y += size.height + SettingsMetrics.sectionGap
    }

    /// The hairline between rows of a section.
    mutating func divider() {
        canvas?.fill(RectF(x: x, y: y, width: width, height: 1), look.text.opacity(look.dark ? 0.08 : 0.07))
        y += 1
    }

    // MARK: Rows

    /// A setting row: grey round icon, title, description, trailing controls (right to left).
    mutating func row(_ title: String, description: String? = nil, symbol: String? = nil, titleColour: Colour? = nil,
                      trailing: [SettingsTrailing] = [], dimmed: Bool = false, quiet: Bool = false,
                      minHeight: Float = SettingsMetrics.rowMinHeight) {
        let iconWidth: Float = symbol == nil ? 0 : SettingsMetrics.rowIcon + 10
        let trailingWidth = trailing.reduce(Float(0)) { $0 + $1.width } + Float(max(0, trailing.count - 1)) * 10
        let textX = x + iconWidth
        let textWidth = max(80, width - iconWidth - (trailing.isEmpty ? 0 : trailingWidth + 12))
        let titleStyle = quiet ? Theme.Typography.rowDescription : TextStyle(size: 13, wrap: true)
        let titleColour = titleColour ?? (quiet ? look.secondary : look.text)
        let titleSize = Canvas.measure(title, style: titleStyle, width: textWidth)
        let descriptionSize = description.map { Canvas.measure($0, style: Theme.Typography.rowDescription, width: textWidth) }
        let textHeight = titleSize.height + (descriptionSize.map { $0.height + 2 } ?? 0)
        let height = max(minHeight, textHeight + 16, (trailing.map(\.height).max() ?? 0) + 16)
        if let canvas {
            let rowRect = RectF(x: x, y: y, width: width, height: height)
            canvas.withOpacity(dimmed ? 0.5 : 1) {
                if let symbol {
                    SettingsDraw.rowIcon(canvas, centre: PointF(x: x + SettingsMetrics.rowIcon / 2, y: rowRect.midY), symbol: symbol,
                                         look: look)
                }
                var ty = rowRect.midY - textHeight / 2
                canvas.text(title, at: PointF(x: textX, y: ty), width: textWidth, style: titleStyle, titleColour)
                ty += titleSize.height + 2
                if let description {
                    canvas.text(description, at: PointF(x: textX, y: ty), width: textWidth, style: Theme.Typography.rowDescription,
                                look.secondary)
                }
            }
            if let controls = live(rowRect) {
                var right = x + width
                for item in trailing.reversed() {
                    let rect = RectF(x: right - item.width, y: (rowRect.midY - item.height / 2).rounded(), width: item.width,
                                     height: item.height)
                    canvas.withOpacity(dimmed ? 0.5 : 1) { item.draw(canvas, controls, rect) }
                    if let id = item.id { record(id, rowRect) }
                    right -= item.width + 10
                }
            }
        }
        y += height
    }

    /// A toggle row (SPEC §3.9): icon, title, what will happen, optional Options…, the switch.
    mutating func toggleRow(_ id: String, title: String, description: String, symbol: String, isOn: Bool,
                            enabled: Bool = true, options: (() -> Void)? = nil, optionsEnabled: Bool = true,
                            action: @escaping (Bool) -> Void) {
        var trailing: [SettingsTrailing] = []
        if let options { trailing.append(.button("\(id).options", "Options…", enabled: optionsEnabled, action: options)) }
        trailing.append(.toggle(id, isOn: isOn, enabled: enabled, action: action))
        row(title, description: description, symbol: symbol, trailing: trailing)
    }

    /// A sentence row: the control sits inside the sentence ("Offer an eye rest after [20 ⌄] min").
    mutating func sentence(_ parts: [SentencePart], disabled: Bool = false) {
        let height = SettingsMetrics.rowMinHeight
        if let canvas {
            var cx = x
            let midY = y + height / 2
            for part in parts {
                switch part {
                case .text(let words):
                    let size = Canvas.measure(words, style: Theme.Typography.row)
                    canvas.text(words, at: PointF(x: cx, y: midY - size.height / 2), style: Theme.Typography.row, look.text)
                    cx += size.width + 6
                case .menu(let id, let title, let items):
                    let rect = RectF(x: cx, y: midY - 13, width: SettingsDraw.menuWidth(title), height: 26)
                    if let controls = live(rect), !disabled {
                        controls.menu(canvas, id: id, rect, title: title, items: items)
                    } else {
                        SettingsDraw.menuFace(canvas, rect, title: title, look: look)
                    }
                    record(id, rect)
                    cx += rect.width + 6
                case .control(let id, let width, let draw):
                    let rect = RectF(x: cx, y: midY - 14, width: width, height: 28)
                    if let controls = live(rect), !disabled {
                        draw(canvas, controls, rect)
                    } else if let inert {
                        draw(canvas, inert, rect)
                    }
                    record(id, rect)
                    cx += width + 6
                }
            }
        }
        y += height
    }

    // MARK: Cards

    /// A preset card (SPEC §3.9 "show, don't tell"): content, title, detail, and the selection
    /// shown with a checkmark and the accent border.
    func presetCard(_ id: String, _ rect: RectF, title: String, detail: String, selected: Bool, contentHeight: Float,
                    action: @escaping () -> Void, content: (Canvas, RectF) -> Void) {
        guard let canvas, let controls = live(rect) else { return }
        let hot = controls.isHovered(id)
        canvas.fill(rect, radius: 10, look.dark ? Colour.white.opacity(hot ? 0.08 : 0.05) : Colour.white.opacity(hot ? 1 : 0.85))
        if selected {
            canvas.stroke(rect.insetBy(1, 1), radius: 9, width: 2, look.accent)
        } else {
            canvas.stroke(rect.insetBy(0.5, 0.5), radius: 10, width: 1, look.text.opacity(0.12))
        }
        let inner = rect.insetBy(12, 12)
        content(canvas, RectF(x: inner.x, y: inner.y, width: inner.width, height: contentHeight))
        let textY = inner.y + contentHeight + 10
        let textWidth = inner.width - 22
        let titleSize = canvas.text(title, at: PointF(x: inner.x, y: textY), width: textWidth,
                                    style: TextStyle(size: 13, weight: 600, wrap: true), look.text)
        canvas.text(detail, at: PointF(x: inner.x, y: textY + titleSize.height + 2), width: textWidth,
                    style: Theme.Typography.rowDescription, look.secondary)
        let check = PointF(x: inner.maxX - 8, y: textY + 8)
        if selected {
            canvas.circle(check, radius: 8, look.accent)
            canvas.path("MLL", [check.x - 3.5, check.y, check.x - 1, check.y + 2.6, check.x + 3.6, check.y - 2.6], look.onAccent, stroke: 1.6)
        } else {
            canvas.ring(check, radius: 7.5, width: 1, look.secondary.opacity(0.8))
        }
        controls.region(id, rect, focusable: true, action: action)
        SettingsDraw.focusRing(canvas, controls, id: id, rect, radius: 10)
        record(id, rect)
    }

    /// The height a preset card needs for its text at `width`.
    static func presetCardHeight(width: Float, title: String, detail: String, contentHeight: Float) -> Float {
        let textWidth = width - 24 - 22
        let titleHeight = Canvas.measure(title, style: TextStyle(size: 13, weight: 600, wrap: true), width: textWidth).height
        let detailHeight = Canvas.measure(detail, style: Theme.Typography.rowDescription, width: textWidth).height
        return 12 + contentHeight + 10 + titleHeight + 2 + detailHeight + 12
    }
}

/// Where controls were drawn (content coordinates), so a Tab to one below the fold scrolls it in.
@MainActor
final class SettingsFrames {
    var rects: [String: RectF] = [:]
}

/// Drawing helpers shared by the panes.
@MainActor
enum SettingsDraw {
    static func card(_ canvas: Canvas, _ rect: RectF, look: Look) {
        let radius = Theme.Radius.settingsSection
        canvas.fill(rect, radius: radius, look.dark ? Colour.white.opacity(0.05) : Colour.white.opacity(0.72))
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: radius, width: 1, look.dark ? Colour.white.opacity(0.08) : Colour.black.opacity(0.07))
    }

    /// The 24 DIP grey circle with a glyph that starts a row.
    static func rowIcon(_ canvas: Canvas, centre: PointF, symbol: String, look: Look) {
        canvas.circle(centre, radius: SettingsMetrics.rowIcon / 2, look.text.opacity(0.08))
        SettingsGlyph.draw(symbol, on: canvas, centre: centre, size: 12, look.secondary)
    }

    /// A sidebar tile: 20 DIP rounded square on the mint → indigo ramp, white glyph.
    static func tile(_ canvas: Canvas, _ rect: RectF, symbol: String, index: Int) {
        let ramp = Theme.Palette.sidebarRamp
        let colour = ramp[min(max(index, 0), ramp.count - 1)]
        canvas.gradient(rect, radius: Theme.Radius.sidebarTile, from: colour.mixed(with: .white, 0.12), to: colour, angle: 90)
        SettingsGlyph.draw(symbol, on: canvas, centre: PointF(x: rect.midX, y: rect.midY), size: rect.width * 0.55, Colour.white)
    }

    static func menuWidth(_ title: String) -> Float {
        Canvas.measure(title, style: Theme.Typography.body).width + 40
    }

    /// A menu button's face without input (a disabled sentence).
    static func menuFace(_ canvas: Canvas, _ rect: RectF, title: String, look: Look) {
        canvas.fill(rect, radius: 7, look.fill)
        canvas.text(title, in: RectF(x: rect.x + 10, y: rect.y, width: rect.width - 30, height: rect.height), style: Theme.Typography.body,
                    look.text)
        let cx = rect.maxX - 14, cy = rect.midY
        canvas.path("MLL", [cx - 4, cy - 2, cx, cy + 2, cx + 4, cy - 2], look.secondary, stroke: 1.5)
    }

    static func checkbox(_ canvas: Canvas, _ box: RectF, isOn: Bool, look: Look) {
        if isOn {
            canvas.fill(box, radius: 4, look.accent)
            canvas.path("MLL", [box.x + 4.5, box.midY, box.x + 7.8, box.maxY - 5, box.maxX - 4, box.y + 5], look.onAccent, stroke: 2)
        } else {
            canvas.fill(box, radius: 4, look.fill)
            canvas.stroke(box, radius: 4, width: 1, look.text.opacity(0.45))
        }
    }

    /// The focus ring for a control drawn here (Controls draws its own for its widgets).
    static func focusRing(_ canvas: Canvas, _ controls: Controls, id: String, _ rect: RectF, radius: Float) {
        guard controls.keyboardUsed, controls.focused == id else { return }
        canvas.stroke(rect.insetBy(-3, -3), radius: radius + 3, width: 2, controls.look.accent)
    }

    /// A quarter-turn arc going round (still under Reduce Motion).
    static func spinner(_ canvas: Canvas, centre: PointF, radius: Float, colour: Colour, phase: Double) {
        canvas.ring(centre, radius: radius, width: 2, colour.opacity(0.25))
        let start = Float(phase.truncatingRemainder(dividingBy: 1))
        canvas.arc(centre, radius: radius, from: start, to: start + 0.3, width: 2, colour)
    }

    /// The status pill of an integration row.
    @discardableResult
    static func pill(_ canvas: Canvas?, at origin: PointF, text: String, kind: PillKind, flashing: Bool, look: Look) -> Float {
        let style = TextStyle(size: 11, weight: 500)
        let textWidth = Canvas.measure(text, style: style).width
        let glyph: Float = kind == .plain ? 0 : 14
        let width = 16 + glyph + textWidth
        guard let canvas else { return width }
        let rect = RectF(x: origin.x, y: origin.y, width: width, height: 20)
        let accent = look.accent
        let background: Colour, foreground: Colour
        switch kind {
        case .connected:
            background = flashing ? accent : accent.opacity(0.14)
            foreground = flashing ? Theme.Palette.onMint : (look.dark ? accent : Colour(hex: 0x0B7A63))
        case .problem, .plain:
            background = look.text.opacity(0.06)
            foreground = look.secondary
        }
        canvas.fill(rect, radius: 10, background)
        var tx = rect.x + 8
        switch kind {
        case .connected:
            canvas.path("MLL", [tx + 1, rect.midY, tx + 3.6, rect.midY + 2.6, tx + 8.4, rect.midY - 2.8], foreground, stroke: 1.6)
            tx += glyph
        case .problem:
            SettingsDraw.warning(canvas, centre: PointF(x: tx + 5, y: rect.midY), size: 10)
            tx += glyph
        case .plain:
            break
        }
        let size = Canvas.measure(text, style: style)
        canvas.text(text, at: PointF(x: tx, y: rect.midY - size.height / 2), style: style, foreground)
        return width
    }

    enum PillKind { case connected, problem, plain }

    static let orange = Colour(hex: 0xF7A23B)
    static let orangeLight = Colour(hex: 0xB45F06)

    /// A filled warning triangle with its "!" (the orange of an install problem).
    static func warning(_ canvas: Canvas, centre: PointF, size: Float) {
        let h = size * 0.9, w = size
        canvas.path("MLLZ", [centre.x, centre.y - h / 2, centre.x + w / 2, centre.y + h / 2, centre.x - w / 2, centre.y + h / 2], orange)
        canvas.fill(RectF(x: centre.x - 0.6, y: centre.y - h * 0.18, width: 1.2, height: h * 0.38), Colour(hex: 0x2A1A00))
        canvas.fill(RectF(x: centre.x - 0.6, y: centre.y + h * 0.28, width: 1.2, height: 1.2), Colour(hex: 0x2A1A00))
    }
}

/// The settings panes' symbols (SF Symbol names, as the macOS panes use) drawn the Windows way:
/// the brand's line glyphs and the icon-font glyphs `Glyphs` knows, plus Segoe Fluent Icons for the
/// rest of the names the settings rows use.
@MainActor
enum SettingsGlyph {
    /// Segoe Fluent Icons / MDL2 code points for the names `Glyphs.fontGlyphs` does not map.
    static let extra: [String: String] = [
        "display.2": "\u{E7F4}",                 // TVMonitor
        "play.rectangle": "\u{E714}",            // Video
        "figure.strengthtraining.functional": "\u{E805}", // Health
        "mic": "\u{E720}",                       // Microphone
        "pause.circle": "\u{E769}",              // Pause
        "figure.walk.departure": "\u{E805}",
        "hand.tap": "\u{E815}",                  // Touch pointer
        "figure.wave": "\u{E77B}",               // Contact (a person)
        "lightbulb": "\u{EA80}",                 // Lightbulb
        "power": "\u{E7E8}",                     // Power
        "command": "\u{E765}",                   // Keyboard
        "bell.and.waves.left.and.right": "\u{EA8F}",
        "metronome": "\u{E916}",
        "text.quote": "\u{E8BD}",                // Message
        "cursorarrow.motionlines": "\u{E962}",   // Mouse
        "tv": "\u{E7F4}",
        "rectangle.dashed": "\u{E7F4}",
        "text.cursor": "\u{E8D2}",               // Font
        "square.grid.2x2": "\u{F0E2}",           // Apps
        "network.slash": "\u{E774}",             // Globe
        "folder": "\u{E8B7}",                    // Folder
        "heart.text.square": "\u{EB51}",         // Heart
        "arrow.triangle.2.circlepath": "\u{E895}", // Sync
        "arrow.down.app": "\u{E896}",            // Download
        "checkmark.circle": "\u{E930}",          // Completed
        "exclamationmark.circle": "\u{E783}",    // Error
        "wifi.slash": "\u{EB5E}",                // Wifi warning
        "bell.badge": "\u{EA8F}",
        "video": "\u{E714}",
        "exclamationmark.circle.small": "\u{E783}",
        "checkmark.shield.fill": "\u{EA18}",     // Shield
        "stop.fill": "\u{E71A}",
        "speaker.fill": "\u{E992}",              // Volume0
        "speaker.wave.3.fill": "\u{E995}",       // Volume3
    ]

    /// The brand's vector glyphs `Glyphs.draw` draws itself.
    static let vectorNames: Set<String> = ["eye", "figure.arms.open", "figure.walk", "wind", "sparkle", "sparkles", "curlybraces",
                                           "circle.hexagongrid"]

    static func draw(_ symbol: String, on canvas: Canvas, centre: PointF, size: Float, _ colour: Colour) {
        if vectorNames.contains(symbol) || Glyphs.fontGlyphs[symbol] != nil {
            Glyphs.draw(symbol, on: canvas, centre: centre, size: size, colour)
            return
        }
        let glyph = extra[symbol] ?? (symbol.unicodeScalars.count == 1 ? symbol : "\u{E7C3}")
        let box = RectF(x: centre.x - size, y: centre.y - size * 0.75, width: size * 2, height: size * 1.5)
        canvas.text(glyph, in: box, style: TextStyle(size: size, align: .center, family: Glyphs.iconFamily), colour)
    }
}
