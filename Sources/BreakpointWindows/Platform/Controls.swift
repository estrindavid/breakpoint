import CBreakpointWin32
import Foundation
import WinSDK

/// The colours controls are drawn in: the always-dark pop-ups and overlay, or Settings and
/// Onboarding, which follow the system's light or dark mode (SPEC §4.2).
public struct Look: Sendable {
    public var dark: Bool
    public var text: Colour
    public var secondary: Colour
    public var hint: Colour
    public var fill: Colour
    public var fillHover: Colour
    public var stroke: Colour
    public var accent: Colour
    public var onAccent: Colour
    public var surface: Colour
    public var raised: Colour

    public static let dark = Look(dark: true, text: Colour.white, secondary: Colour.white.opacity(0.6),
                                  hint: Colour.white.opacity(Theme.TextStep.hint.opacity),
                                  fill: Colour.white.opacity(0.10), fillHover: Colour.white.opacity(0.16),
                                  stroke: Colour.white.opacity(0.14), accent: Theme.Palette.mint, onAccent: Theme.Palette.onMint,
                                  surface: Theme.Palette.solidPopup, raised: Colour.white.opacity(0.06))

    public static let light = Look(dark: false, text: Colour(0.08, 0.09, 0.11), secondary: Colour(0.08, 0.09, 0.11, 0.62),
                                   hint: Colour(0.08, 0.09, 0.11, 0.5), fill: Colour(0, 0, 0, 0.06),
                                   fillHover: Colour(0, 0, 0, 0.10), stroke: Colour(0, 0, 0, 0.12),
                                   accent: Theme.Palette.mintLight, onAccent: Colour.white,
                                   surface: Colour(0.97, 0.97, 0.98), raised: Colour(1, 1, 1, 0.7))

    /// Settings and Onboarding: the system's app mode.
    public static var system: Look { Appearance.isDarkMode ? .dark : .light }
}

/// Immediate-mode controls for one window: each frame, `draw` calls the widget functions, which
/// draw themselves (in their hover, pressed and focus states) and register where they can be
/// clicked. Pointer and keyboard input then go to the region under the pointer or with the focus.
///
/// Keyboard: Tab and Shift+Tab move the focus through focusable controls in drawing order; Space
/// and Enter press the focused control; the arrow keys change a focused segmented control or
/// slider. A focus ring shows only once the keyboard has been used (as Windows does).
@MainActor
public final class Controls {
    public enum Role { case primary, secondary, quiet, destructive }

    struct Region {
        let id: String
        let rect: RectF
        let focusable: Bool
        let action: (() -> Void)?
        let drag: ((PointF) -> Void)?
        let arrows: ((Int) -> Void)?
    }

    public private(set) var hovered: String?
    public private(set) var pressed: String?
    public var focused: String?
    public private(set) var keyboardUsed = false
    private var regions: [Region] = []
    private weak var window: Window?
    /// Called for keys no control used (Esc, shortcuts).
    public var onKey: ((UInt32) -> Bool)?
    /// The pointer moved over or off any part of the window (pop-ups reveal their × on hover).
    public var onHoverChange: ((Bool) -> Void)?
    public private(set) var pointerInside = false
    public var look: Look

    public init(look: Look) { self.look = look }

    /// Takes over the window's pointer and keyboard handlers.
    public func attach(to window: Window) {
        self.window = window
        window.onMouseMove = { [weak self] point in self?.mouseMoved(point) }
        window.onMouseLeave = { [weak self] in self?.mouseLeft() }
        window.onMouseDown = { [weak self] point in self?.mouseDown(point) }
        window.onMouseUp = { [weak self] point in self?.mouseUp(point) }
        window.onKeyDown = { [weak self] key in self?.keyDown(key) ?? false }
    }

    /// Call at the start of each frame.
    public func begin() { regions.removeAll(keepingCapacity: true) }

    private func redraw() { window?.setNeedsDisplay() }

    // MARK: Regions

    /// A clickable area with no drawing of its own.
    public func region(_ id: String, _ rect: RectF, focusable: Bool = false, action: @escaping () -> Void) {
        regions.append(Region(id: id, rect: rect, focusable: focusable, action: action, drag: nil, arrows: nil))
    }

    public func isHovered(_ id: String) -> Bool { hovered == id }
    public func isPressed(_ id: String) -> Bool { pressed == id && hovered == id }
    func isFocusVisible(_ id: String) -> Bool { keyboardUsed && focused == id }

    private func focusRing(_ canvas: Canvas, _ rect: RectF, radius: Float, id: String) {
        guard isFocusVisible(id) else { return }
        canvas.stroke(rect.insetBy(-3, -3), radius: radius + 3, width: 2, look.accent)
    }

    // MARK: Widgets

    /// A capsule button. `keycap` (e.g. "Ctrl+Alt+Win+B") is drawn small after the title.
    public func button(_ canvas: Canvas, id: String, _ rect: RectF, _ title: String, role: Role = .secondary,
                       keycap: String? = nil, keycapBright: Bool = false, enabled: Bool = true, style: TextStyle? = nil,
                       action: @escaping () -> Void) {
        let hot = enabled && isHovered(id), down = enabled && isPressed(id)
        let radius = rect.height / 2
        let background: Colour
        let foreground: Colour
        switch role {
        case .primary:
            background = down ? look.accent.mixed(with: .black, 0.15) : (hot ? look.accent.mixed(with: .white, 0.12) : look.accent)
            foreground = look.onAccent
        case .secondary:
            background = down ? look.fillHover.opacity(1.4) : (hot ? look.fillHover : look.fill)
            foreground = look.text.opacity(Theme.TextStep.label.opacity / (look.dark ? 1 : 0.85))
        case .quiet:
            background = down ? look.fill : (hot ? look.fill.opacity(0.7) : .clear)
            foreground = look.secondary
        case .destructive:
            background = down ? Colour(0.75, 0.18, 0.18) : (hot ? Colour(0.86, 0.26, 0.26) : Colour(0.80, 0.22, 0.22))
            foreground = .white
        }
        canvas.withOpacity(enabled ? 1 : 0.45) {
            canvas.fill(rect, radius: radius, background)
            let titleStyle = style ?? (rect.height >= 32 ? Theme.Typography.button : Theme.Typography.smallButton)
            if let keycap {
                let capStyle = Theme.Typography.keycap
                let titleSize = Canvas.measure(title, style: titleStyle)
                let capSize = Canvas.measure(keycap, style: capStyle)
                let total = titleSize.width + 8 + capSize.width + 10
                let x = rect.midX - total / 2
                canvas.text(title, at: PointF(x: x, y: rect.midY - titleSize.height / 2), style: TextStyle(size: titleStyle.size, weight: titleStyle.weight), foreground)
                let cap = RectF(x: x + titleSize.width + 8, y: rect.midY - 9, width: capSize.width + 10, height: 18)
                canvas.fill(cap, radius: Theme.Radius.keycap, foreground.opacity(keycapBright ? 0.22 : 0.10))
                canvas.text(keycap, in: cap, style: capStyle, foreground.opacity(keycapBright ? 0.95 : 0.55))
            } else {
                canvas.text(title, in: rect.insetBy(8, 0), style: titleStyle, foreground)
            }
        }
        focusRing(canvas, rect, radius: radius, id: id)
        if enabled { regions.append(Region(id: id, rect: rect, focusable: true, action: action, drag: nil, arrows: nil)) }
    }

    /// The round × at a card's corner.
    public func closeButton(_ canvas: Canvas, id: String, centre: PointF, visible: Bool = true, action: @escaping () -> Void) {
        let size = Theme.Size.closeButton + 4
        let rect = RectF(x: centre.x - size / 2, y: centre.y - size / 2, width: size, height: size)
        guard visible else { return }
        let hot = isHovered(id)
        canvas.circle(centre, radius: size / 2, hot ? look.fillHover.opacity(1.5) : look.fill.opacity(1.3))
        let d: Float = 3.5
        let colour = look.text.opacity(hot ? 0.9 : 0.6)
        canvas.line(PointF(x: centre.x - d, y: centre.y - d), PointF(x: centre.x + d, y: centre.y + d), width: 1.5, colour)
        canvas.line(PointF(x: centre.x + d, y: centre.y - d), PointF(x: centre.x - d, y: centre.y + d), width: 1.5, colour)
        focusRing(canvas, rect, radius: size / 2, id: id)
        regions.append(Region(id: id, rect: rect.insetBy(-4, -4), focusable: true, action: action, drag: nil, arrows: nil))
    }

    /// An on/off switch (40 × 20).
    public func toggle(_ canvas: Canvas, id: String, at origin: PointF, isOn: Bool, enabled: Bool = true,
                       action: @escaping (Bool) -> Void) {
        let rect = RectF(x: origin.x, y: origin.y, width: 40, height: 20)
        let hot = isHovered(id)
        canvas.withOpacity(enabled ? 1 : 0.45) {
            if isOn {
                canvas.fill(rect, radius: 10, hot ? look.accent.mixed(with: .white, 0.1) : look.accent)
            } else {
                canvas.fill(rect, radius: 10, hot ? look.fillHover : look.fill)
                canvas.stroke(rect, radius: 10, width: 1, look.text.opacity(0.45))
            }
            let knob: Float = isOn ? 14 : 12
            let cx = isOn ? rect.maxX - 10 : rect.minX + 10
            canvas.circle(PointF(x: cx, y: rect.midY), radius: knob / 2, isOn ? look.onAccent : look.text.opacity(0.75))
        }
        focusRing(canvas, rect, radius: 10, id: id)
        if enabled { regions.append(Region(id: id, rect: rect.insetBy(-4, -4), focusable: true, action: { action(!isOn) }, drag: nil, arrows: nil)) }
    }

    /// A checkbox with its label; the label is clickable too.
    public func checkbox(_ canvas: Canvas, id: String, at origin: PointF, label: String, isOn: Bool, width: Float = 0,
                         action: @escaping (Bool) -> Void) {
        let box = RectF(x: origin.x, y: origin.y + 1, width: 18, height: 18)
        let hot = isHovered(id)
        if isOn {
            canvas.fill(box, radius: 4, look.accent)
            canvas.path("MLL", [box.x + 4.5, box.midY, box.x + 7.8, box.maxY - 5, box.maxX - 4, box.y + 5], look.onAccent, stroke: 2)
        } else {
            canvas.fill(box, radius: 4, hot ? look.fillHover : look.fill)
            canvas.stroke(box, radius: 4, width: 1, look.text.opacity(0.45))
        }
        let size = canvas.text(label, at: PointF(x: box.maxX + 8, y: origin.y), width: width > 0 ? width - 26 : 0,
                               style: width > 0 ? Theme.Typography.bodyWrapped : Theme.Typography.body, look.text)
        focusRing(canvas, box, radius: 4, id: id)
        let hit = RectF(x: origin.x, y: origin.y, width: 26 + size.width, height: max(20, size.height))
        regions.append(Region(id: id, rect: hit, focusable: true, action: { action(!isOn) }, drag: nil, arrows: nil))
    }

    /// One choice of several, side by side.
    public func segmented(_ canvas: Canvas, id: String, _ rect: RectF, options: [String], selected: Int,
                          action: @escaping (Int) -> Void) {
        canvas.fill(rect, radius: 7, look.fill)
        guard !options.isEmpty else { return }
        let width = rect.width / Float(options.count)
        for (index, option) in options.enumerated() {
            let cell = RectF(x: rect.x + Float(index) * width, y: rect.y, width: width, height: rect.height).insetBy(2, 2)
            let cellID = "\(id).\(index)"
            if index == selected {
                canvas.fill(cell, radius: 5, look.dark ? Colour.white.opacity(0.18) : Colour.white)
            } else if isHovered(cellID) {
                canvas.fill(cell, radius: 5, look.fill)
            }
            canvas.text(option, in: cell.insetBy(4, 0), style: TextStyle(size: 12, weight: index == selected ? 600 : 400, align: .center),
                        index == selected ? look.text : look.secondary)
            regions.append(Region(id: cellID, rect: cell, focusable: false, action: { action(index) }, drag: nil, arrows: nil))
        }
        focusRing(canvas, rect, radius: 7, id: id)
        let count = options.count
        regions.append(Region(id: id, rect: RectF(x: 0, y: 0, width: 0, height: 0), focusable: true, action: nil, drag: nil,
                              arrows: { step in action(min(max(0, selected + step), count - 1)) }))
    }

    /// A horizontal slider over `range`, snapping to `step`.
    public func slider(_ canvas: Canvas, id: String, _ rect: RectF, value: Double, range: ClosedRange<Double>, step: Double,
                       action: @escaping (Double) -> Void) {
        let t = Float((value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound))
        let track = RectF(x: rect.x, y: rect.midY - 2, width: rect.width, height: 4)
        canvas.fill(track, radius: 2, look.fill.opacity(2))
        canvas.fill(RectF(x: track.x, y: track.y, width: track.width * t, height: 4), radius: 2, look.accent)
        let knob = PointF(x: rect.x + rect.width * t, y: rect.midY)
        canvas.circle(knob, radius: isHovered(id) || pressed == id ? 9 : 8, look.dark ? Colour.white : Colour.white)
        canvas.ring(knob, radius: 8.5, width: 1, Colour.black.opacity(0.15))
        focusRing(canvas, RectF(x: knob.x - 8, y: knob.y - 8, width: 16, height: 16), radius: 8, id: id)
        let snap: (Double) -> Double = { v in
            let stepped = (v / step).rounded() * step
            return min(max(range.lowerBound, stepped), range.upperBound)
        }
        regions.append(Region(id: id, rect: rect.insetBy(-6, -8), focusable: true, action: nil, drag: { point in
            let fraction = Double(min(max(0, (point.x - rect.x) / rect.width), 1))
            action(snap(range.lowerBound + fraction * (range.upperBound - range.lowerBound)))
        }, arrows: { direction in action(snap(value + Double(direction) * step)) }))
    }

    /// − value + (minutes, times).
    public func stepper(_ canvas: Canvas, id: String, at origin: PointF, value: String, width: Float = 120,
                        minus: @escaping () -> Void, plus: @escaping () -> Void) {
        let rect = RectF(x: origin.x, y: origin.y, width: width, height: 28)
        canvas.fill(rect, radius: 7, look.fill)
        let left = RectF(x: rect.x, y: rect.y, width: 28, height: 28)
        let right = RectF(x: rect.maxX - 28, y: rect.y, width: 28, height: 28)
        for (cell, glyph, suffix) in [(left, "−", "minus"), (right, "+", "plus")] {
            let cellID = "\(id).\(suffix)"
            if isHovered(cellID) { canvas.fill(cell.insetBy(2, 2), radius: 5, look.fillHover) }
            canvas.text(glyph, in: cell, style: TextStyle(size: 15, weight: 600, align: .center), look.text)
            regions.append(Region(id: cellID, rect: cell, focusable: false, action: suffix == "minus" ? minus : plus, drag: nil, arrows: nil))
        }
        canvas.text(value, in: RectF(x: left.maxX, y: rect.y, width: right.minX - left.maxX, height: 28),
                    style: TextStyle(size: 13, weight: 600, monospacedDigits: true, align: .center), look.text)
        focusRing(canvas, rect, radius: 7, id: id)
        regions.append(Region(id: id, rect: RectF(x: 0, y: 0, width: 0, height: 0), focusable: true, action: nil, drag: nil,
                              arrows: { $0 < 0 ? minus() : plus() }))
    }

    /// A button that opens a native menu of `items` under itself.
    public func menu(_ canvas: Canvas, id: String, _ rect: RectF, title: String, items: [(String, Bool, () -> Void)]) {
        let hot = isHovered(id)
        canvas.fill(rect, radius: 7, hot ? look.fillHover : look.fill)
        canvas.text(title, in: RectF(x: rect.x + 10, y: rect.y, width: rect.width - 30, height: rect.height), style: Theme.Typography.body, look.text)
        let cx = rect.maxX - 14, cy = rect.midY
        canvas.path("MLL", [cx - 4, cy - 2, cx, cy + 2, cx + 4, cy - 2], look.secondary, stroke: 1.5)
        focusRing(canvas, rect, radius: 7, id: id)
        regions.append(Region(id: id, rect: rect, focusable: true, action: { [weak self] in
            self?.popUpMenu(items, under: rect)
        }, drag: nil, arrows: nil))
    }

    /// Shows a native menu below `rect` and runs the chosen item.
    public func popUpMenu(_ items: [(String, Bool, () -> Void)], under rect: RectF) {
        guard let hwnd = window?.hwnd, let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        for (index, item) in items.enumerated() {
            if item.0 == "-" {
                AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
            } else {
                AppendMenuW(menu, UINT(MF_STRING) | (item.1 ? UINT(MF_CHECKED) : 0), UINT_PTR(index + 1), item.0.wide)
            }
        }
        let scale = window?.scale ?? 1
        var point = POINT(x: LONG(rect.x * scale), y: LONG(rect.maxY * scale))
        ClientToScreen(hwnd, &point)
        SetForegroundWindow(hwnd)  // so the menu closes when the person clicks elsewhere
        let chosen = bp_track_popup_menu(UnsafeMutableRawPointer(menu), UInt32(TPM_LEFTALIGN | TPM_TOPALIGN | TPM_RIGHTBUTTON),
                                         point.x, point.y, UnsafeMutableRawPointer(hwnd))
        if chosen > 0, Int(chosen) <= items.count { items[Int(chosen) - 1].2() }
    }

    /// Text that runs `action` when clicked (an underline on hover).
    public func link(_ canvas: Canvas, id: String, at origin: PointF, _ text: String, style: TextStyle = Theme.Typography.body,
                     action: @escaping () -> Void) {
        let size = canvas.text(text, at: origin, style: style, isHovered(id) ? look.accent.mixed(with: .white, 0.15) : look.accent)
        if isHovered(id) { canvas.line(PointF(x: origin.x, y: origin.y + size.height - 1), PointF(x: origin.x + size.width, y: origin.y + size.height - 1), width: 1, look.accent, round: false) }
        let rect = RectF(x: origin.x, y: origin.y, width: size.width, height: size.height)
        focusRing(canvas, rect, radius: 3, id: id)
        regions.append(Region(id: id, rect: rect, focusable: true, action: action, drag: nil, arrows: nil))
    }

    // MARK: Input

    private func region(at point: PointF) -> Region? {
        regions.last { $0.rect.contains(point) && ($0.action != nil || $0.drag != nil) }
    }

    private func mouseMoved(_ point: PointF) {
        if !pointerInside {
            pointerInside = true
            onHoverChange?(true)
        }
        if let pressedID = pressed, let drag = regions.first(where: { $0.id == pressedID })?.drag {
            drag(point)
            return
        }
        let id = region(at: point)?.id
        if id != hovered {
            hovered = id
            Window.cursor = id == nil ? IDC.arrow : IDC.hand
            redraw()
        }
    }

    private func mouseLeft() {
        pointerInside = false
        onHoverChange?(false)
        if hovered != nil {
            hovered = nil
            Window.cursor = IDC.arrow
            redraw()
        }
    }

    private func mouseDown(_ point: PointF) {
        keyboardUsed = false
        guard let target = region(at: point) else { return }
        pressed = target.id
        hovered = target.id
        if target.focusable { focused = target.id }
        target.drag?(point)
        redraw()
    }

    private func mouseUp(_ point: PointF) {
        defer {
            pressed = nil
            redraw()
        }
        guard let pressedID = pressed, let target = regions.last(where: { $0.id == pressedID }) else { return }
        if target.drag == nil, target.rect.contains(point) { target.action?() }
    }

    private func keyDown(_ key: UInt32) -> Bool {
        let focusables = regions.filter(\.focusable)
        switch Int32(key) {
        case VK_TAB:
            keyboardUsed = true
            guard !focusables.isEmpty else { return false }
            let back = GetKeyState(Int32(VK_SHIFT)) < 0
            let index = focusables.firstIndex { $0.id == focused }
            let next = index.map { (back ? $0 - 1 + focusables.count : $0 + 1) % focusables.count } ?? (back ? focusables.count - 1 : 0)
            focused = focusables[next].id
            redraw()
            return true
        case VK_SPACE, VK_RETURN:
            if let focused, let target = focusables.first(where: { $0.id == focused }), let action = target.action {
                keyboardUsed = true
                action()
                redraw()
                return true
            }
        case VK_LEFT, VK_DOWN, VK_RIGHT, VK_UP:
            if let focused, let target = focusables.first(where: { $0.id == focused }), let arrows = target.arrows {
                keyboardUsed = true
                arrows(Int32(key) == VK_LEFT || Int32(key) == VK_DOWN ? -1 : 1)
                redraw()
                return true
            }
        default:
            break
        }
        return onKey?(key) ?? false
    }
}
