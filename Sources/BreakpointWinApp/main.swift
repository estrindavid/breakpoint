import BreakpointWindows
import CBreakpointGraphics
import Foundation
import WinSDK

// Spike: a nudge-shaped card on the acrylic backdrop, drawn with Direct2D through the shim.
_ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
_ = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))
_ = bp_graphics_start()

MainActor.assumeIsolated {
    let window = Window(style: .popup)
    window.create(frame: RectF(x: 600, y: 40, width: 410, height: 122))
    window.draw = { canvas in
        let bounds = canvas.bounds
        if Appearance.prefersOpaque { canvas.fill(bounds, Theme.Palette.solidPopup) }
        canvas.fill(bounds, Theme.Palette.white(.fill).opacity(0.4))
        let badge = RectF(x: 14, y: 14, width: 44, height: 44)
        canvas.gradient(badge, radius: 22, from: Theme.Palette.mint, to: Theme.Palette.indigo, angle: 45)
        BrandMark.drawMark(in: badge.insetBy(9, 9), on: canvas, tag: Theme.Palette.onAccent, eyes: Theme.Palette.mint)
        canvas.text("2-min stretch?", at: PointF(x: 70, y: 14), style: Theme.Typography.nudgeTitle, Theme.Palette.white(.title))
        canvas.text("Claude is working on the login redirect.", at: PointF(x: 70, y: 42), width: 320,
                    style: Theme.Typography.nudgeSubtitle, Theme.Palette.white(.secondary))
        let start = RectF(x: 70, y: 76, width: 96, height: 34)
        canvas.fill(start, radius: 17, Theme.Palette.mint)
        canvas.text("Start", in: start, style: Theme.Typography.button, Theme.Palette.onMint)
        let later = RectF(x: 175, y: 76, width: 96, height: 34)
        canvas.fill(later, radius: 17, Theme.Palette.white(.fill))
        canvas.text("Not now", in: later, style: Theme.Typography.button, Theme.Palette.white(.label))
        canvas.arc(PointF(x: 380, y: 30), radius: 10, from: 0, to: 0.7, width: 3, Theme.Palette.mint)
    }
    window.show()
    window.onMouseDown = { _ in MessageLoop.quit() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MessageLoop.quit() }
}
exit(MessageLoop.run())
