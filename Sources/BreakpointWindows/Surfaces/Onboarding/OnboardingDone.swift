import BreakpointCore
import BreakpointRuntime
import Foundation

// SPEC §3.10 step 5: "Breakpoint lives in your notification area" with a small arrow pointing at
// the tray icon's actual position, what a click on it does, and "Open Breakpoint at login".

@MainActor
enum OnboardingDone {
    static let title = "Breakpoint lives in your notification area"

    static func page(_ canvas: Canvas, _ controls: Controls, look: Look, content: RectF, state: AppState, model: OnboardingModel,
                     handlers: OnboardingView.Handlers, now: Date) {
        var y = content.y + 28
        // The arrow, bobbing gently toward the icon.
        let bob: Float = model.reduceMotion || model.frozen ? 0
            : Float((1 - cos(now.timeIntervalSinceReferenceDate * 2 * .pi / 1.8)) / 2) * 3
        arrow(canvas, centre: PointF(x: content.midX, y: y + 15), angle: model.arrowAngle ?? 135, length: 22, bob: bob, look.accent)
        y += 30 + 10
        y += trayPreview(canvas, centre: content.midX, top: y, look: look) + 18

        let width = content.width - 64
        y += canvas.text(title, at: PointF(x: 32, y: y), width: width, style: OnboardingView.titleStyle, look.text).height + 8
        let sentenceWidth = min(420, width)
        y += canvas.text(placeSentence(state, model), at: PointF(x: content.midX - sentenceWidth / 2, y: y), width: sentenceWidth,
                         style: OnboardingView.sentenceStyle, look.secondary).height + 20

        let tips: [(String, String)] = [
            ("\u{E8B0}", "Click it to see your next break, pause, or take one now."),
            ("\u{E8B0}", "Right-click it for the same in a menu."),
            ("\u{E713}", "Change anything later in Settings."),
        ]
        let cardWidth: Float = 400
        let textWidth = cardWidth - 32 - 30
        let heights = tips.map { Canvas.measure($0.1, style: Theme.Typography.bodyWrapped, width: textWidth).height }
        let cardHeight = 32 + heights.reduce(0, +) + 20
        let card = RectF(x: content.midX - cardWidth / 2, y: y, width: cardWidth, height: cardHeight)
        OnboardingView.card(canvas, card, look: look)
        var ty = card.y + 16
        for (index, tip) in tips.enumerated() {
            OnboardingView.icon(canvas, tip.0, centre: PointF(x: card.x + 16 + 10, y: ty + heights[index] / 2), size: 12, look.secondary)
            canvas.text(tip.1, at: PointF(x: card.x + 16 + 30, y: ty), width: textWidth, style: Theme.Typography.bodyWrapped, look.text)
            ty += heights[index] + 10
        }
        y = card.maxY + 16
        loginChoice(canvas, controls, centreX: content.midX, top: y, look: look, state: state, model: model, handlers: handlers)
    }

    /// Where to look, and what happens when the window closes (the tour's offer the first time).
    static func placeSentence(_ state: AppState, _ model: OnboardingModel) -> String {
        guard model.iconVisible else {
            return "Windows keeps it behind the ^ arrow in the taskbar. Drag it next to the clock to keep it in view."
        }
        let then = state.settings.tourStatus == .notOffered
            ? "When you close this window, it offers a one-minute tour."
            : "It opens there once when you close this window."
        return "Look for this mark at the \(model.iconPlace). \(then)"
    }

    /// An arrow `length` long through `centre`, pointing `angle` degrees clockwise from up.
    private static func arrow(_ canvas: Canvas, centre: PointF, angle: Float, length: Float, bob: Float, _ colour: Colour) {
        let radians = angle * .pi / 180
        let dx = sin(radians), dy = -cos(radians)
        let c = PointF(x: centre.x + dx * bob, y: centre.y + dy * bob)
        let tip = PointF(x: c.x + dx * length / 2, y: c.y + dy * length / 2)
        let tail = PointF(x: c.x - dx * length / 2, y: c.y - dy * length / 2)
        canvas.line(tail, tip, width: 2.5, colour)
        let head: Float = 7
        for side: Float in [-1, 1] {
            let a = radians + .pi + side * 0.65
            canvas.line(tip, PointF(x: tip.x + sin(a) * head, y: tip.y - cos(a) * head), width: 2.5, colour)
        }
    }

    /// A small taskbar corner: the overflow chevron, the mark highlighted, the clock.
    private static func trayPreview(_ canvas: Canvas, centre: Float, top: Float, look: Look) -> Float {
        let size = SizeF(width: 150, height: 32)
        let rect = RectF(x: centre - size.width / 2, y: top, width: size.width, height: size.height)
        let bar = look.dark ? Colour(hex: 0x202020) : Colour(hex: 0xEEEEEE)
        let ink = look.dark ? Colour.white : Colour(0.1, 0.1, 0.12)
        canvas.fill(rect, radius: 6, bar)
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: 6, width: 1, look.text.opacity(0.1))
        let chevron = PointF(x: rect.x + 18, y: rect.midY)
        canvas.path("MLL", [chevron.x - 4, chevron.y + 2, chevron.x, chevron.y - 2, chevron.x + 4, chevron.y + 2], ink.opacity(0.75), stroke: 1.3)
        let markBox = RectF(x: rect.x + 34, y: rect.y + 4, width: 34, height: 24)
        canvas.fill(markBox, radius: 4, ink.opacity(0.10))
        TrayMarkPreview.draw(canvas, in: RectF(x: markBox.midX - 9, y: markBox.midY - 9, width: 18, height: 18), colour: ink, cutout: bar)
        Glyphs.draw("speaker.wave.2", on: canvas, centre: PointF(x: rect.x + 82, y: rect.midY), size: 12, ink.opacity(0.75))
        let clock = TextStyle(size: 11, align: .trailing)
        canvas.text("14:05", in: RectF(x: rect.x + 92, y: rect.y, width: rect.width - 92 - 10, height: rect.height), style: clock, ink.opacity(0.85))
        return size.height
    }

    /// "Open Breakpoint at login" as a capsule check; off and disabled, with the reason under it,
    /// where a login item cannot point at this copy.
    private static func loginChoice(_ canvas: Canvas, _ controls: Controls, centreX: Float, top: Float, look: Look, state: AppState,
                                    model: OnboardingModel, handlers: OnboardingView.Handlers) {
        let reason = unavailableReason(model.loginAvailability)
        let isOn = reason == nil && state.settings.launchAtLogin
        let label = "Open Breakpoint at login"
        let labelSize = Canvas.measure(label, style: Theme.Typography.row)
        let width = 12 + 16 + 7 + labelSize.width + 12
        let rect = RectF(x: (centreX - width / 2).rounded(), y: top, width: width, height: 28)
        let hot = reason == nil && controls.isHovered("login")
        canvas.withOpacity(reason == nil ? 1 : 0.55) {
            canvas.fill(rect, radius: 14, look.text.opacity(hot ? 0.09 : 0.05))
            let check = PointF(x: rect.x + 12 + 8, y: rect.midY)
            if isOn {
                canvas.circle(check, radius: 8, look.accent)
                canvas.path("MLL", [check.x - 3.5, check.y, check.x - 1, check.y + 2.6, check.x + 3.8, check.y - 2.6], look.onAccent, stroke: 1.6)
            } else {
                canvas.ring(check, radius: 7.5, width: 1.2, look.secondary)
            }
            canvas.text(label, at: PointF(x: rect.x + 12 + 16 + 7, y: rect.midY - labelSize.height / 2), style: Theme.Typography.row, look.text)
        }
        if let reason {
            canvas.text(reason, at: PointF(x: centreX - 200, y: rect.maxY + 6), width: 400,
                        style: TextStyle(size: 11, align: .center, wrap: true), look.secondary)
        } else {
            controls.region("login", rect, focusable: true) { handlers.setLaunchAtLogin(!isOn) }
            if controls.isFocusVisible("login") {
                canvas.stroke(rect.insetBy(-3, -3), radius: 17, width: 2, look.accent)
            }
        }
    }

    /// Why the login item cannot be used in this run (development runs keep the plain choice: they
    /// never register anything anyway).
    static func unavailableReason(_ availability: LoginItemAvailability) -> String? {
        switch availability {
        case .available, .developmentRun: return nil
        case .outsideApplications: return "This works once Breakpoint is installed in your Programs folder."
        case .notFromApp: return "This works once Breakpoint runs from its installed copy."
        }
    }
}

/// The idle tray mark (outline and eyes), for the Done step's taskbar corner.
@MainActor
enum TrayMarkPreview {
    static func draw(_ canvas: Canvas, in rect: RectF, colour: Colour, cutout: Colour) {
        let markHeight = rect.width * BrandMark.bounds.height / BrandMark.bounds.width
        let mark = RectF(x: rect.x, y: rect.midY - markHeight / 2, width: rect.width, height: markHeight)
        BrandMark.draw(.tagOutline, in: mark, on: canvas, colour)
        BrandMark.draw(.eyes, in: mark, on: canvas, colour)
    }
}
