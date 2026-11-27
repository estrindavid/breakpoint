import BreakpointCore
import BreakpointRuntime
import CBreakpointWin32
import Foundation
import WinSDK

/// The mark in the notification area (SPEC §3.7): the same states as the macOS menu-bar mark,
/// composed by shape (outlined tag, eyes, notch block, rest bar, badge), drawn in one colour that
/// follows the taskbar (white on a dark taskbar, near-black on a light one), as Windows' own tray
/// icons are. Knocked-out parts are real holes in the icon.
@MainActor
public enum TrayMark {
    /// Draws `variant` with `badge` into `rect` (the icon's square).
    public static func draw(_ canvas: Canvas, in rect: RectF, variant: MarkVariant, badge: MarkBadge,
                            badgeOpacity: Float = 1, pose: MarkPose = .rest, colour: Colour) {
        // The mark fills the icon's width; the badge sits at its trailing-bottom corner.
        let markHeight = rect.width * BrandMark.bounds.height / BrandMark.bounds.width
        let mark = RectF(x: rect.x, y: rect.midY - markHeight / 2, width: rect.width, height: markHeight)
        let s = mark.width / BrandMark.bounds.width
        switch variant {
        case .brand, .onBreak:
            BrandMark.draw(.tag, in: mark, on: canvas, colour)
            canvas.erasing { BrandMark.draw(.eyes, in: mark, on: canvas, .black, pose: pose) }
        case .idle:
            BrandMark.draw(.tagOutline, in: mark, on: canvas, colour)
            BrandMark.draw(.eyes, in: mark, on: canvas, colour, pose: pose)
        case .due:
            BrandMark.draw(.tagOutline, in: mark, on: canvas, colour)
            BrandMark.draw(.notchBlock, in: mark, on: canvas, colour)
            canvas.erasing { BrandMark.draw(.eyes, in: mark, on: canvas, .black, pose: pose) }
        case .paused:
            BrandMark.draw(.tagOutline, in: mark, on: canvas, colour)
            BrandMark.draw(.restBar, in: mark, on: canvas, colour)
        }
        guard badge != .none else { return }
        let (centre, diameter) = badgeGeometry(mark, scale: s, pose: badge == .working ? pose : .rest)
        guard diameter > 0.01 else { return }
        // A halo around the badge, so it reads apart from the outline it overlaps.
        let halo = diameter + 3 * s * Float(min(1, max(0, pose.dotScale)))
        canvas.erasing { canvas.circle(centre, radius: halo / 2, .black) }
        switch badge {
        case .working: canvas.circle(centre, radius: diameter / 2, colour.opacity(badgeOpacity))
        case .needsYou: canvas.ring(centre, radius: diameter / 2 - 0.75 * s, width: 1.5 * s, colour)
        case .none: break
        }
    }

    /// As the macOS `BrandMarkGlyph.badgeGeometry`: 6.5 units at the corner, travelling toward the
    /// notch (grid 10, 11.4) as it settles.
    static func badgeGeometry(_ mark: RectF, scale s: Float, pose: MarkPose) -> (PointF, Float) {
        let rest = 6.5 * s
        let corner = PointF(x: mark.maxX - rest / 2, y: mark.maxY - rest / 2)
        let ox = mark.midX - BrandMark.bounds.width * s / 2 - BrandMark.bounds.minX * s
        let oy = mark.midY - BrandMark.bounds.height * s / 2 - BrandMark.bounds.minY * s
        let notch = PointF(x: ox + 10 * s, y: oy + 11.4 * s)
        let t = Float(min(1, max(0, pose.dotTravel)))
        let centre = PointF(x: corner.x + (notch.x - corner.x) * t, y: corner.y + (notch.y - corner.y) * t)
        return (centre, rest * Float(min(1, max(0, pose.dotScale))))
    }

    /// The taskbar is light (Settings → Personalization → Colours → Windows mode).
    public static var taskbarIsLight: Bool { Appearance.systemUsesLightTheme }

    public static var colour: Colour { taskbarIsLight ? Colour(0.1, 0.1, 0.12) : Colour.white }
}

/// The notification-area icon itself: added to the system events window, re-added when Explorer
/// restarts, its image and tooltip updated as the state changes.
@MainActor
final class TrayIcon {
    static let id: UInt32 = 1
    private(set) var isInstalled = false
    private var icon: HICON?
    private var tip = "Breakpoint"
    /// The icon was clicked (`true`: the context menu key or right click) at a screen point.
    var onSelect: ((POINT) -> Void)?
    var onMenu: ((POINT) -> Void)?
    var onKeySelect: (() -> Void)?
    private var registered = false

    func install() {
        SystemEvents.shared.start()
        guard let hwnd = SystemEvents.shared.hwnd else { return }
        if !registered {
            registered = true
            SystemEvents.shared.on(SystemEvents.trayCallback) { [weak self] wParam, lParam in
                self?.callback(wParam, lParam)
                return 0
            }
            SystemEvents.shared.on(SystemEvents.shared.taskbarCreatedMessage) { [weak self] _, _ in
                // Explorer restarted: every icon is gone.
                guard let self else { return nil }
                self.isInstalled = false
                self.install()
                return nil
            }
        }
        isInstalled = bp_tray_add(UnsafeMutableRawPointer(hwnd), Self.id, SystemEvents.trayCallback,
                                  icon.map { UnsafeMutableRawPointer($0) }, tip.wide) == 1
    }

    func remove() {
        guard isInstalled, let hwnd = SystemEvents.shared.hwnd else { return }
        bp_tray_remove(UnsafeMutableRawPointer(hwnd), Self.id)
        isInstalled = false
    }

    func update(icon newIcon: HICON?, tip newTip: String) {
        let old = icon
        icon = newIcon
        tip = newTip
        if isInstalled, let hwnd = SystemEvents.shared.hwnd {
            _ = bp_tray_modify(UnsafeMutableRawPointer(hwnd), Self.id, newIcon.map { UnsafeMutableRawPointer($0) }, newTip.wide)
        }
        if let old, old != newIcon { DestroyIcon(old) }
    }

    func update(tip newTip: String) {
        guard newTip != tip else { return }
        tip = newTip
        if isInstalled, let hwnd = SystemEvents.shared.hwnd {
            _ = bp_tray_modify(UnsafeMutableRawPointer(hwnd), Self.id, nil, newTip.wide)
        }
    }

    func focus() {
        guard isInstalled, let hwnd = SystemEvents.shared.hwnd else { return }
        bp_tray_focus(UnsafeMutableRawPointer(hwnd), Self.id)
    }

    /// The icon's rectangle in physical pixels (nil when it is in the overflow and hidden).
    var rect: RECT? {
        guard isInstalled, let hwnd = SystemEvents.shared.hwnd else { return nil }
        var left: Int32 = 0, top: Int32 = 0, right: Int32 = 0, bottom: Int32 = 0
        guard bp_tray_rect(UnsafeMutableRawPointer(hwnd), Self.id, &left, &top, &right, &bottom) == 1 else { return nil }
        return RECT(left: LONG(left), top: LONG(top), right: LONG(right), bottom: LONG(bottom))
    }

    // NOTIFYICON_VERSION_4 events.
    private static let ninSelect: UInt32 = UInt32(WM_USER) + 0
    private static let ninKeySelect: UInt32 = UInt32(WM_USER) + 1

    private func callback(_ wParam: WPARAM, _ lParam: LPARAM) {
        let event = UInt32(lParam & 0xFFFF)
        let point = POINT(x: LONG(Int16(truncatingIfNeeded: wParam & 0xFFFF)),
                          y: LONG(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF)))
        switch event {
        case Self.ninSelect: onSelect?(point)
        case Self.ninKeySelect: onKeySelect?()
        case UInt32(WM_CONTEXTMENU): onMenu?(point)
        default: break
        }
    }

    /// Renders the mark at the tray's icon size for the current DPI.
    static func makeIcon(variant: MarkVariant, badge: MarkBadge, badgeOpacity: Float, pose: MarkPose) -> HICON? {
        let dpi = SystemEvents.shared.hwnd.map { GetDpiForWindow($0) } ?? GetDpiForSystem()
        let size = Int(GetSystemMetricsForDpi(SM_CXSMICON, dpi))
        let job = IconJob(size: Float(size), variant: variant, badge: badge, badgeOpacity: badgeOpacity, pose: pose,
                          colour: TrayMark.colour)
        let drawer: BPIconDrawer = { surface, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let job = Unmanaged<IconJob>.fromOpaque(context).takeUnretainedValue()
                let canvas = Canvas(surface: surface, size: SizeF(width: job.size, height: job.size), scale: 1)
                // A pixel of inset on each side keeps the outline off the icon's edge.
                let inset: Float = job.size >= 24 ? 1.5 : 0.75
                TrayMark.draw(canvas, in: RectF(x: inset, y: inset, width: job.size - 2 * inset, height: job.size - 2 * inset),
                              variant: job.variant, badge: job.badge, badgeOpacity: job.badgeOpacity, pose: job.pose,
                              colour: job.colour)
            }
        }
        let icon = withExtendedLifetime(job) {
            bp_make_icon(Int32(size), drawer, Unmanaged.passUnretained(job).toOpaque())
        }
        return icon.map { HICON($0.assumingMemoryBound(to: HICON__.self)) }
    }

    private final class IconJob {
        let size: Float
        let variant: MarkVariant
        let badge: MarkBadge
        let badgeOpacity: Float
        let pose: MarkPose
        let colour: Colour
        init(size: Float, variant: MarkVariant, badge: MarkBadge, badgeOpacity: Float, pose: MarkPose, colour: Colour) {
            self.size = size; self.variant = variant; self.badge = badge; self.badgeOpacity = badgeOpacity
            self.pose = pose; self.colour = colour
        }
    }
}
