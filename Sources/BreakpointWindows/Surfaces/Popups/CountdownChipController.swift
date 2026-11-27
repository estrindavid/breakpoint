import BreakpointCore
import BreakpointRuntime
import Foundation
import WinSDK

/// The countdown chip (SPEC §3.2), as `CountdownChipView` draws it: a 32 DIP capsule, the 22 DIP
/// kind badge inset 5 · 8 · "Eye rest in 5" (13 semibold, tabular digits) · 13. It is the last
/// rung of the warning ladder, so it says what is coming and when, nothing else.
///
/// Unlike the other pop-ups the chip draws its own capsule (no system backdrop or corners): it
/// is small, moves every frame and must not catch the pointer.
@MainActor
enum PopupChipView {
    static let height = Theme.Size.countdownChipHeight
    static let badgeInset: Float = 5
    static let trailingInset: Float = 13
    static let style = TextStyle(size: 13, weight: 600, monospacedDigits: true)

    static func text(kind: BreakKind, remaining: TimeInterval) -> String { Copy.countdownChip(kind: kind, remaining: remaining) }

    static func size(kind: BreakKind, remaining: TimeInterval) -> SizeF {
        let textWidth = Canvas.measure(text(kind: kind, remaining: remaining), style: style).width
        return SizeF(width: (badgeInset + Theme.Size.countdownChipBadge + 8 + textWidth + trailingInset).rounded(.up), height: height)
    }

    /// Draws the chip filling `rect` (its own capsule and badge).
    static func draw(_ canvas: Canvas, _ rect: RectF, kind: BreakKind, remaining: TimeInterval) {
        let radius = rect.height / 2
        let opaque = Appearance.prefersOpaque || Appearance.highContrast
        canvas.fill(rect, radius: radius, Theme.Palette.solidPopup.opacity(opaque ? 1 : 0.94))
        canvas.clipped(to: rect, radius: radius) {
            canvas.gradient(RectF(x: rect.x, y: rect.y, width: rect.width, height: rect.height / 2), radius: 0,
                            from: Colour.white.opacity(0.07), to: Colour.white.opacity(0), angle: 90)
        }
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: radius - 0.5, width: 1, Colour.white.opacity(Appearance.highContrast ? 0.4 : 0.12))
        let badge = Theme.Size.countdownChipBadge
        PopupBadge.draw(canvas, centre: PointF(x: rect.x + badgeInset + badge / 2, y: rect.midY), diameter: badge,
                        symbol: kind.symbolName, tone: .brand)
        let label = text(kind: kind, remaining: remaining)
        let size = Canvas.measure(label, style: style)
        canvas.text(label, at: PointF(x: rect.x + badgeInset + badge + 8, y: rect.midY - size.height / 2), style: style,
                    Theme.Palette.white(.title))
    }
}

/// Shows the countdown chip while `state.nudge?.phase == .countdownChip` (SPEC §3.2): the Windows
/// counterpart of the macOS `CountdownChipController`.
///
/// - The chip sits 20 DIPs right of and below the pointer, flipping to the other side near an
///   edge so it stays whole on the pointer's display, and follows the pointer (`GetCursorPos` at
///   30 Hz, only while the chip shows; it moves the window without redrawing it).
/// - It is not part of `PopupStack`'s layout or limit, sits above the other pop-ups, never
///   activates and lets clicks through (`WS_EX_LAYERED | WS_EX_TRANSPARENT` on its own window).
/// - It redraws only when its text changes (once a second).
@MainActor
final class CountdownChipController: SurfaceController {
    private let state: AppState
    private let stack: PopupStack
    private var window: DrawnWindow?
    private var shownID: UUID?
    private var kind: BreakKind = .eyes
    private var remaining: TimeInterval = 0
    private var label = ""
    private var size = SizeF(width: 0, height: 0)
    private var followTimer: Timer?
    private var placed: (x: Int32, y: Int32, monitor: UInt)?

    static let pointerOffset: Float = 20
    static let followInterval: TimeInterval = 1.0 / 30

    init(state: AppState, stack: PopupStack) {
        self.state = state
        self.stack = stack
    }

    func sync() {
        guard let nudge = state.nudge, nudge.phase == .countdownChip else {
            if window != nil { hide() }
            return
        }
        kind = nudge.kind
        remaining = nudge.autoStartRemaining ?? 0
        if shownID != nudge.id || window == nil {
            show(id: nudge.id)
            return
        }
        let text = PopupChipView.text(kind: kind, remaining: remaining)
        guard text != label else { return }
        label = text
        let newSize = PopupChipView.size(kind: kind, remaining: remaining)
        if newSize != size {
            size = newSize
            placed = nil
            follow()
        }
        window?.setNeedsDisplay()
    }

    func tearDown() {
        hide()
    }

    private func show(id: UUID) {
        hide()
        shownID = id
        label = PopupChipView.text(kind: kind, remaining: remaining)
        size = PopupChipView.size(kind: kind, remaining: remaining)
        let window = DrawnWindow(style: .popup)
        window.background = nil
        window.content = { [weak self] canvas, _ in
            guard let self else { return }
            PopupChipView.draw(canvas, canvas.bounds, kind: self.kind, remaining: self.remaining)
        }
        window.create(size: size, owner: SystemEvents.shared.hwnd)
        if let hwnd = window.window.hwnd { Self.makeClickThrough(hwnd) }
        self.window = window
        placed = nil
        follow()
        window.window.show(activate: false)
        let timer = Timer(timeInterval: Self.followInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.follow() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func hide() {
        followTimer?.invalidate()
        followTimer = nil
        window?.destroy()
        window = nil
        shownID = nil
        placed = nil
    }

    /// 20 DIPs right of and below the pointer, on the pointer's display, flipped near its edges.
    private func follow() {
        guard let window else { return }
        var cursor = POINT()
        guard GetCursorPos(&cursor), let handle = MonitorFromPoint(cursor, DWORD(MONITOR_DEFAULTTONEAREST)),
              let monitor = Monitors.describe(handle) else { return }
        let s = monitor.scale
        let offset = Int32((Self.pointerOffset * s).rounded())
        let w = Int32((size.width * s).rounded()), h = Int32((size.height * s).rounded())
        let bounds = monitor.frame
        var x = cursor.x + offset
        var y = cursor.y + offset
        if x + w > bounds.right { x = cursor.x - offset - w }
        if y + h > bounds.bottom { y = cursor.y - offset - h }
        x = min(max(x, bounds.left), bounds.right - w)
        y = min(max(y, bounds.top), bounds.bottom - h)
        if let placed, placed.x == x, placed.y == y, placed.monitor == monitor.handle { return }
        placed = (x, y, monitor.handle)
        window.window.place(RectF(x: Float(x) / s, y: Float(y) / s, width: size.width, height: size.height), on: monitor)
    }

    /// The chip lets every click through to what is under it, shows no system backdrop, border
    /// or rounded corners (it draws its own capsule), and stays above the other pop-ups.
    private static func makeClickThrough(_ hwnd: HWND) {
        let exStyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, exStyle | LONG_PTR(WS_EX_LAYERED | WS_EX_TRANSPARENT))
        SetLayeredWindowAttributes(hwnd, 0, 255, DWORD(LWA_ALPHA))
        var none: Int32 = 1                   // DWMSBT_NONE
        _ = DwmSetWindowAttribute(hwnd, 38, &none, DWORD(MemoryLayout<Int32>.size))
        var square: Int32 = 1                 // DWMWCP_DONOTROUND
        _ = DwmSetWindowAttribute(hwnd, 33, &square, DWORD(MemoryLayout<Int32>.size))
        var noBorder: UInt32 = 0xFFFF_FFFE    // DWMWA_COLOR_NONE
        _ = DwmSetWindowAttribute(hwnd, 34, &noBorder, DWORD(MemoryLayout<UInt32>.size))
        var margins = MARGINS(cxLeftWidth: 0, cxRightWidth: 0, cyTopHeight: 0, cyBottomHeight: 0)
        _ = DwmExtendFrameIntoClientArea(hwnd, &margins)
    }
}
