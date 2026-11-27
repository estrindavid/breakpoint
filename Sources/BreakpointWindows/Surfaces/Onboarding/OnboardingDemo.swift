import BreakpointCore
import BreakpointRuntime
import Foundation

// SPEC §3.10 step 2: a looping 6 s demo on a miniature desktop: a terminal with an agent at work,
// the nudge appears → Start → the break takes the screen → the agent chip turns amber "Claude needs
// you" → back to the terminal. Under reduced motion: three stills with captions. The stage draws
// small stand-ins for the nudge card and the break screen (a whole 1280 × 640 display shrunk to
// the stage), from the same preview data the real surfaces show.

@MainActor
enum OnboardingDemo {
    /// The moments of the demo, in order.
    enum Phase: Int, CaseIterable, Sendable {
        case working, nudge, onBreak, needsYou, back

        /// When the phase starts within the 6 s loop.
        var start: TimeInterval {
            switch self {
            case .working: return 0
            case .nudge: return 0.5
            case .onBreak: return 2.1
            case .needsYou: return 3.7
            case .back: return 4.9
            }
        }

        static func at(_ t: TimeInterval) -> Phase { allCases.last { $0.start <= t } ?? .working }

        var caption: String {
            switch self {
            case .working, .nudge: return "When your agent starts working, a small offer appears."
            case .onBreak: return "Start it, and the break takes the screen for a moment."
            case .needsYou: return "If your agent needs you, a soft chime calls you back."
            case .back: return "Back to work, right where you left off."
            }
        }

        var stillCaption: String {
            switch self {
            case .nudge: return "1. An offer appears while your agent works."
            case .onBreak: return "2. Start it, and the break takes the screen."
            default: return "3. A chime calls you back when it needs you."
            }
        }
    }

    static let loop: TimeInterval = 6
    static let stage = SizeF(width: 472, height: 236)
    static let fade: TimeInterval = 0.35

    static func page(_ canvas: Canvas, look: Look, content: RectF, state: AppState, model: OnboardingModel, now: Date) {
        let y = OnboardingView.header(canvas, look: look, content: content, title: "How it works",
                                      sentence: "Breaks come at natural pauses, like the minutes while your agent works.")
        let x = content.midX - stage.width / 2
        if model.reduceMotion {
            stills(canvas, look: look, origin: PointF(x: x, y: y), now: state.now)
            return
        }
        let t = model.demoTime(at: now)
        drawStage(canvas, at: PointF(x: x, y: y), t: t, now: state.now, look: look)
        canvas.text(Phase.at(t).caption, at: PointF(x: x, y: y + stage.height + 14), width: stage.width,
                    style: TextStyle(size: 13, align: .center, wrap: true), look.secondary)
    }

    /// Reduced motion: three stills with captions.
    private static func stills(_ canvas: Canvas, look: Look, origin: PointF, now: Date) {
        let scale: Float = 0.32
        let cell = stage.width * scale
        let gap: Float = 12
        let total = 3 * cell + 2 * gap
        var x = origin.x + (stage.width - total) / 2
        for phase in [Phase.nudge, .onBreak, .needsYou] {
            canvas.transformed(dx: x, dy: origin.y, scale: scale) {
                drawStage(canvas, at: PointF(x: 0, y: 0), t: phase.start + 0.6, now: now, look: look)
            }
            canvas.text(phase.stillCaption, at: PointF(x: x, y: origin.y + stage.height * scale + 8), width: cell,
                        style: TextStyle(size: 11, align: .center, wrap: true), look.secondary)
            x += cell + gap
        }
    }

    private static func ramp(_ t: TimeInterval, _ start: TimeInterval) -> Float {
        Float(min(1, max(0, (t - start) / fade)))
    }

    /// The stage at `t` seconds into the loop.
    static func drawStage(_ canvas: Canvas, at origin: PointF, t: TimeInterval, now: Date, look: Look) {
        let rect = RectF(origin: origin, size: stage)
        let nudgeAlpha = ramp(t, Phase.nudge.start) * (1 - ramp(t, Phase.onBreak.start))
        let overlayAlpha = ramp(t, Phase.onBreak.start) * (1 - ramp(t, Phase.back.start))
        let needsYou = ramp(t, Phase.needsYou.start)
        let back = t >= Phase.back.start
        // No clip: a clip inside a transform (the stills, the page's slide) lands in the wrong place
        // (Canvas.clipped applies the transform twice), so every part stays inside the stage.
        do {
            canvas.gradient(rect, radius: 10, from: Colour(hex: 0x24344F), to: Colour(hex: 0x4F7F84), angle: 30)
            terminal(canvas, RectF(x: rect.midX - 165, y: rect.y + 30, width: 330, height: 168), back: back)
            taskbar(canvas, rect, onBreak: overlayAlpha > 0.5, needsYou: back || needsYou > 0.5)
            if nudgeAlpha > 0.001 {
                canvas.withOpacity(nudgeAlpha) {
                    let scale: Float = 0.6
                    let width = Theme.Size.nudgeSize.width * scale
                    let rise = (1 - nudgeAlpha) * -8
                    canvas.transformed(dx: rect.midX - width / 2, dy: rect.y + 12 + rise, scale: scale) {
                        nudgeCard(canvas, now: now)
                    }
                }
            }
            if overlayAlpha > 0.001 {
                canvas.withOpacity(overlayAlpha) {
                    canvas.fill(rect, radius: 10, Theme.Palette.solidOverlay.opacity(0.97))
                    let scale = stage.width / 1280
                    canvas.transformed(dx: rect.x, dy: rect.y, scale: scale) {
                        breakScreen(canvas, now: now, needsYou: needsYou)
                    }
                }
            }
        }
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: 10, width: 1, look.text.opacity(0.12))
    }

    /// A terminal window with an agent session in it.
    private static func terminal(_ canvas: Canvas, _ rect: RectF, back: Bool) {
        canvas.shadow(rect, radius: 8, blur: 10, offset: PointF(x: 0, y: 6), Colour.black.opacity(0.35))
        canvas.fill(rect, radius: 8, Colour(hex: 0x0E1116, alpha: 0.94))
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: 8, width: 1, Colour.white.opacity(0.12))
        // Title bar: the tab on the left, the window buttons on the right (Windows Terminal).
        let tab = RectF(x: rect.x + 8, y: rect.y + 4, width: 120, height: 16)
        canvas.fill(tab, radius: 4, Colour.white.opacity(0.08))
        canvas.text("breakpoint — PowerShell", in: tab.insetBy(6, 0), style: TextStyle(size: 9, weight: 500), Colour.white.opacity(0.55))
        let buttons = rect.maxX - 12
        canvas.line(PointF(x: buttons - 44, y: rect.y + 12), PointF(x: buttons - 38, y: rect.y + 12), width: 1, Colour.white.opacity(0.4))
        canvas.stroke(RectF(x: buttons - 25, y: rect.y + 9, width: 6, height: 6), radius: 0.5, width: 1, Colour.white.opacity(0.4))
        canvas.line(PointF(x: buttons - 6, y: rect.y + 9), PointF(x: buttons, y: rect.y + 15), width: 1, Colour.white.opacity(0.4))
        canvas.line(PointF(x: buttons, y: rect.y + 9), PointF(x: buttons - 6, y: rect.y + 15), width: 1, Colour.white.opacity(0.4))
        let mono = TextStyle(size: 10, family: "Cascadia Mono")
        var y = rect.y + 30
        let x = rect.x + 12
        func line(_ text: String, _ colour: Colour) {
            canvas.text(text, at: PointF(x: x, y: y), width: rect.width - 24, style: mono, colour)
            y += 17
        }
        line("PS C:\\code\\breakpoint>", Colour.white.opacity(0.45))
        line("› fix the login redirect after OAuth callback", Colour.white.opacity(0.9))
        if back {
            line("Allow edit to auth/callback.swift? (y/n)", Theme.Palette.amber)
        } else {
            line("✻ Working… reading auth/callback.swift", Theme.Palette.indigo.opacity(0.9))
        }
    }

    /// The taskbar along the stage's bottom: a few app tiles in the middle, the tray mark and the
    /// clock at the right.
    private static func taskbar(_ canvas: Canvas, _ stage: RectF, onBreak: Bool, needsYou: Bool) {
        let bar = RectF(x: stage.x + 1, y: stage.maxY - 18, width: stage.width - 2, height: 18)
        // Rounded ends, so it follows the stage's rounded corners without a clip.
        canvas.fill(bar, radius: 9, Colour.black.opacity(0.35))
        for index in 0..<4 {
            let tile = RectF(x: bar.midX - 34 + Float(index) * 18, y: bar.y + 4, width: 10, height: 10)
            canvas.fill(tile, radius: 2, Colour.white.opacity(index == 1 ? 0.55 : 0.3))
        }
        let markRect = RectF(x: bar.maxX - 62, y: bar.y + 4, width: 14, height: 10)
        TourMarkDrawing.draw(canvas, in: markRect, variant: onBreak ? .onBreak : .idle, badge: needsYou ? .needsYou : .working,
                             colour: Colour.white.opacity(0.9), cutout: Colour(hex: 0x1F2A33))
        canvas.text("14:05", in: RectF(x: bar.maxX - 40, y: bar.y, width: 32, height: bar.height),
                    style: TextStyle(size: 8, align: .trailing), Colour.white.opacity(0.8))
    }

    /// The nudge card at its own size (scaled by the caller): badge, offer, subtitle, Start and
    /// Not now.
    private static func nudgeCard(_ canvas: Canvas, now: Date) {
        let nudge = PreviewData(now: now).nudge(kind: .move)
        let size = Theme.Size.nudgeSize
        let rect = RectF(x: 0, y: 0, width: size.width, height: size.height)
        canvas.shadow(rect, radius: 12, blur: 16, offset: PointF(x: 0, y: 6), Colour.black.opacity(0.35))
        canvas.fill(rect, radius: 12, Theme.Palette.solidPopup)
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: 12, width: 1, Colour.white.opacity(0.12))
        let pad = Theme.Size.cardPadding
        KindBadge.draw(canvas, centre: PointF(x: pad + Theme.Size.badge / 2, y: pad + Theme.Size.badge / 2), symbol: nudge.offer.kind.symbolName)
        let textX = pad + Theme.Size.badge + Theme.Size.badgeToText
        canvas.text(nudge.title, at: PointF(x: textX, y: pad), style: Theme.Typography.nudgeTitle, Colour.white)
        canvas.text(nudge.subtitle, at: PointF(x: textX, y: pad + 26), style: Theme.Typography.nudgeSubtitle,
                    Colour.white.opacity(Theme.TextStep.secondary.opacity))
        let buttonY = size.height - pad - Theme.Size.buttonHeight
        let start = RectF(x: textX, y: buttonY, width: 110, height: Theme.Size.buttonHeight)
        canvas.fill(start, radius: start.height / 2, Theme.Palette.mint)
        canvas.text("Start", in: start, style: Theme.Typography.button, Theme.Palette.onMint)
        let later = RectF(x: start.maxX + Theme.Size.buttonGap, y: buttonY, width: 110, height: Theme.Size.buttonHeight)
        canvas.fill(later, radius: later.height / 2, Colour.white.opacity(0.10))
        canvas.text("Not now", in: later, style: Theme.Typography.button, Colour.white.opacity(Theme.TextStep.label.opacity))
    }

    /// The break screen laid out on a 1280 × 640 display (scaled by the caller): the agent chip
    /// at the top (amber once the agent needs you), title, instruction, ring and Skip.
    private static func breakScreen(_ canvas: Canvas, now: Date, needsYou: Float) {
        let display = SizeF(width: 1280, height: 640)
        let bounds = RectF(x: 0, y: 0, width: display.width, height: display.height)
        let active = PreviewData(now: now).activeBreak(kind: .move, progress: 0.3)
        canvas.glow(PointF(x: bounds.midX, y: bounds.height * 0.42), rx: 520, ry: 300, Theme.Palette.mint.opacity(0.08))
        for (text, tone, alpha) in [(active.agentChip.text, active.agentChip.tone, 1 - needsYou),
                                    (Copy.needsYou(agent: "Claude"), Tone.needsYou, needsYou)] where alpha > 0.001 {
            canvas.withOpacity(alpha) {
                let width = Chip.width(text: text, hasDot: tone != nil)
                Chip.draw(canvas, at: PointF(x: bounds.midX - width / 2, y: Theme.Size.overlayChipTop), text: text, tone: tone)
            }
        }
        let titleStyle = Theme.Typography.overlayTitle(displayWidth: display.width)
        let titleSize = Canvas.measure(active.title, style: titleStyle, width: 900)
        let titleTop = display.height * 0.30
        canvas.text(active.title, at: PointF(x: bounds.midX - 450, y: titleTop), width: 900, style: titleStyle, Colour.white)
        canvas.text(active.instruction, at: PointF(x: bounds.midX - 320, y: titleTop + titleSize.height + 14), width: 640,
                    style: Theme.Typography.overlayInstruction, Colour.white.opacity(Theme.TextStep.body.opacity))
        let ringCentre = PointF(x: bounds.midX, y: display.height * 0.66)
        ProgressRing.draw(canvas, centre: ringCentre, radius: 44, width: Theme.Size.moveRingStroke, progress: 0.3)
        let skip = RectF(x: bounds.midX - 50, y: display.height - Theme.Size.controlsCentreFromBottom / 1.6 - 17, width: 100,
                         height: Theme.Size.buttonHeight)
        canvas.fill(skip, radius: skip.height / 2, Colour.white.opacity(0.12))
        canvas.text("Skip", in: skip, style: Theme.Typography.button, Colour.white.opacity(Theme.TextStep.label.opacity))
    }
}
