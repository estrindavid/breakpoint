import BreakpointCore
import BreakpointRuntime
import Foundation

/// The overlay's backdrop on Windows (SPEC §3.3), bottom to top: the deep scrim `#070A12`, a
/// vignette (the scrim colour deepening toward the edges), the Breakpoint aurora (its five lights
/// laid on in deep tones, then as light), and a hush behind the column so the light never costs
/// the text contrast.
///
/// Differences from the Mac, on purpose:
/// - No live blur of the desktop (an overlay window has no backdrop material), so the scrim is
///   heavier (`OverlayMetrics.scrimOpacity`) to keep the desktop only faintly present.
/// - The aurora is still: drifting it would redraw a full-screen window 15 times a second for the
///   whole break. Its lights sit where they are at the start of their loop.
/// - No grain (Direct2D dithers its gradients itself).
/// - High contrast: a heavier scrim and no aurora, as Increase Contrast on the Mac.
@MainActor
enum OverlayBackdrop {
    /// `ambient` 0…1 (walk ambient: scrim 85% → here 92%, aurora at half strength).
    static func draw(_ canvas: Canvas, ambient: Float, highContrast: Bool) {
        let bounds = canvas.bounds
        if canvas.isOffscreen { standInDesktop(canvas) }
        let base = highContrast ? OverlayMetrics.scrimOpacityHighContrast : OverlayMetrics.scrimOpacity
        let scrim = base + (OverlayMetrics.scrimOpacityAmbient - base) * ambient
        canvas.fill(bounds, Theme.Palette.scrim.opacity(max(base, scrim)))
        vignette(canvas)
        if !highContrast { aurora(canvas, strength: 1 - 0.5 * ambient) }
        let w = bounds.width, h = bounds.height
        canvas.glow(PointF(x: w * Float(AuroraField.gatherPoint.x), y: h * 0.5), rx: w * OverlayMetrics.hushRadius,
                    ry: w * OverlayMetrics.hushRadius * 0.8, Theme.Palette.scrim.opacity(OverlayMetrics.hushOpacity))
    }

    /// The other displays' backdrop: the same, a little plainer (no hush: there is no column).
    static func drawSecondary(_ canvas: Canvas, ambient: Float, highContrast: Bool) {
        if canvas.isOffscreen { standInDesktop(canvas) }
        let base = highContrast ? OverlayMetrics.scrimOpacityHighContrast : OverlayMetrics.scrimOpacity
        let scrim = base + (OverlayMetrics.scrimOpacityAmbient - base) * ambient
        canvas.fill(canvas.bounds, Theme.Palette.scrim.opacity(max(base, scrim)))
        vignette(canvas)
        if !highContrast { aurora(canvas, strength: 0.7 * (1 - 0.5 * ambient)) }
    }

    /// Four edge bands of scrim colour fading inwards: the corners, where two meet, darkest.
    private static func vignette(_ canvas: Canvas) {
        let b = canvas.bounds
        let edge = Theme.Palette.scrim.opacity(OverlayMetrics.vignetteOpacity)
        let clear = Theme.Palette.scrim.opacity(0)
        let band = min(b.width, b.height) * 0.32
        canvas.gradient(RectF(x: 0, y: 0, width: b.width, height: band), radius: 0, from: edge, to: clear, angle: 90)
        canvas.gradient(RectF(x: 0, y: b.height - band, width: b.width, height: band), radius: 0, from: edge, to: clear, angle: 270)
        canvas.gradient(RectF(x: 0, y: 0, width: band, height: b.height), radius: 0, from: edge, to: clear, angle: 0)
        canvas.gradient(RectF(x: b.width - band, y: 0, width: band, height: b.height), radius: 0, from: edge, to: clear, angle: 180)
    }

    private static func aurora(_ canvas: Canvas, strength: Float) {
        let b = canvas.bounds
        let longSide = max(b.width, b.height)
        let lights = AuroraField.lights(phase: 0, bloom: 1)
        for pass in 0..<2 {
            let passStrength = (pass == 0 ? OverlayMetrics.auroraDeepStrength : OverlayMetrics.auroraStrength) * strength
            for light in lights {
                let colour = pass == 0 ? deepColour(light.hue) : lightColour(light.hue)
                let radius = longSide * Float(light.radius)
                canvas.glow(PointF(x: b.width * Float(light.x), y: b.height * Float(light.y)), rx: radius, ry: radius,
                            colour.opacity(passStrength * Float(light.intensity)))
            }
        }
    }

    private static func lightColour(_ hue: AuroraField.Hue) -> Colour {
        switch hue {
        case .mint: return Theme.Palette.mint
        case .teal: return OverlayMetrics.auroraTeal
        case .indigo: return Theme.Palette.indigo
        case .deep: return OverlayMetrics.auroraDeep
        }
    }

    private static func deepColour(_ hue: AuroraField.Hue) -> Colour {
        switch hue {
        case .mint: return OverlayMetrics.auroraDeepTones[0]
        case .teal: return OverlayMetrics.auroraDeepTones[1]
        case .indigo: return OverlayMetrics.auroraDeepTones[2]
        case .deep: return OverlayMetrics.auroraDeepTones[3]
        }
    }

    /// Snapshots only: a bright, busy stand-in for the desktop the live overlay covers (a light
    /// wallpaper and two app windows), so contrast is judged against roughly the worst case.
    static func standInDesktop(_ canvas: Canvas) {
        let b = canvas.bounds
        canvas.gradient(b, radius: 0, from: Colour(hex: 0x9CC8F0), to: Colour(hex: 0xF4D7A8), angle: 60)
        canvas.glow(PointF(x: b.width * 0.75, y: b.height * 0.3), rx: b.width * 0.35, ry: b.height * 0.4, Colour(hex: 0xFF8A65, alpha: 0.6))
        let editor = RectF(x: b.width * 0.08, y: b.height * 0.1, width: b.width * 0.5, height: b.height * 0.62)
        canvas.fill(editor, radius: 8, Colour(hex: 0x1E1E1E))
        for line in 0..<18 {
            let width = editor.width * (0.25 + 0.5 * Float((line * 37) % 11) / 11)
            canvas.fill(RectF(x: editor.x + 24, y: editor.y + 44 + Float(line) * 20, width: width, height: 8), radius: 2,
                        line % 3 == 0 ? Colour(hex: 0x569CD6) : Colour(hex: 0xD4D4D4, alpha: 0.7))
        }
        let browser = RectF(x: b.width * 0.5, y: b.height * 0.35, width: b.width * 0.42, height: b.height * 0.55)
        canvas.fill(browser, radius: 8, Colour(hex: 0xFFFFFF))
        canvas.fill(RectF(x: browser.x, y: browser.y, width: browser.width, height: 36), radius: 8, Colour(hex: 0xE8EAED))
        canvas.fill(RectF(x: browser.x + 20, y: browser.y + 60, width: browser.width * 0.6, height: 18), radius: 3, Colour(hex: 0x202124))
        canvas.fill(RectF(x: browser.x + 20, y: browser.y + 100, width: browser.width - 40, height: 120), radius: 6, Colour(hex: 0x4285F4))
    }
}
