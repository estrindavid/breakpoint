import BreakpointCore
import BreakpointRuntime
import Foundation

// SPEC §3.10: the first-launch window's content, drawn the Windows way. One pure layout pass per
// frame over `Canvas` and `Controls`; every colour comes from the `Look` the controls carry (the
// system's light or dark app mode), so the snapshots draw both looks on any machine.

/// The onboarding steps, in order.
enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, howItWorks, connect, pace, done
}

/// Where onboarding is and what its moving parts are doing; shared by the controller (keys,
/// window) and the view (clicks).
@MainActor
final class OnboardingModel {
    private(set) var step: OnboardingStep
    /// The last change went forward (the new page slides in from the trailing side).
    private(set) var forward = true
    /// When the page last changed (its 0.3 s slide and fade).
    private(set) var changedAt: Date?
    /// When the welcome page first showed (the mark's arrival).
    var shownAt = Date()
    /// When the How it works page showed (its 6 s loop starts there).
    private(set) var demoStart = Date()
    /// The tray icon can be seen (not in the overflow behind the ^ arrow).
    var iconVisible = true
    /// "bottom right of your screen" and the like.
    var iconPlace = "bottom right of your screen"
    /// Direction from the window to the tray icon, degrees clockwise from "up"; `nil`: unknown.
    var arrowAngle: Float?
    var loginAvailability: LoginItemAvailability = .available
    /// When each just-verified install's ✓ started its hop.
    var hopStarts: [IntegrationID: Date] = [:]
    /// "Animation effects" are off: fades only, no loop (three stills), no hop.
    var reduceMotion = false
    /// Snapshots: everything at rest, the demo frozen at `demoPhase`, the hop at `hopProgress`.
    var frozen = false
    var demoPhase: OnboardingDemo.Phase = .nudge
    var hopProgress: Double?
    /// Called when the last step finishes or the user skips.
    var onFinish: () -> Void = {}
    /// The page changed (the controller re-checks what animates and where the icon is).
    var onStepChange: () -> Void = {}

    init(step: OnboardingStep = .welcome) { self.step = step }

    func advance() {
        if let next = OnboardingStep(rawValue: step.rawValue + 1) {
            go(to: next, forward: true)
        } else {
            onFinish()
        }
    }

    func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        go(to: previous, forward: false)
    }

    func skip() { onFinish() }

    private func go(to next: OnboardingStep, forward: Bool) {
        self.forward = forward
        step = next
        changedAt = Date()
        if next == .howItWorks { demoStart = Date() }
        onStepChange()
    }

    /// The page's slide and fade, 0…1 (1: at rest).
    func transition(at now: Date) -> Float {
        guard !frozen, let changedAt else { return 1 }
        let length = reduceMotion ? 0.2 : 0.3
        return Float(min(1, max(0, now.timeIntervalSince(changedAt) / length)))
    }

    /// Seconds into the How it works loop.
    func demoTime(at now: Date) -> TimeInterval {
        if frozen { return demoPhase.start + 0.6 }
        return now.timeIntervalSince(demoStart).truncatingRemainder(dividingBy: OnboardingDemo.loop)
    }

    /// The hop of a just-connected ✓, 0…1 (1: at rest).
    func hop(_ id: IntegrationID, at now: Date) -> Double {
        if frozen { return hopProgress ?? 1 }
        guard let start = hopStarts[id] else { return 1 }
        return min(1, now.timeIntervalSince(start) / OnboardingView.hopDuration)
    }

    /// Something on the page moves now (the window redraws every frame only then).
    func animates(_ state: AppState, at now: Date) -> Bool {
        if frozen { return false }
        if transition(at: now) < 1 { return true }
        switch step {
        case .welcome: return !reduceMotion && now.timeIntervalSince(shownAt) < 0.8
        case .howItWorks: return !reduceMotion
        case .connect:
            let busy = !reduceMotion && state.integrations.contains(where: \.isBusy)
            let hopping = hopStarts.contains { now.timeIntervalSince($0.value) < OnboardingView.hopDuration }
            return busy || hopping
        case .pace: return false
        case .done: return !reduceMotion
        }
    }
}

@MainActor
enum OnboardingView {
    struct Handlers {
        var advance: () -> Void = {}
        var back: () -> Void = {}
        var skip: () -> Void = {}
        var install: (IntegrationID) -> Void = { _ in }
        var uninstall: (IntegrationID) -> Void = { _ in }
        var choosePreset: (CadencePreset) -> Void = { _ in }
        var setLaunchAtLogin: (Bool) -> Void = { _ in }
    }

    static let barHeight: Float = 64
    static let hopDuration: Double = 0.45
    static let titleStyle = TextStyle(size: 24, weight: 700, align: .center, wrap: true)
    static let sentenceStyle = TextStyle(size: 13, align: .center, wrap: true)

    /// Under the content: nothing over Mica (the backdrop is the window's colour), the look's own
    /// surface when drawn opaque (transparency effects off, Windows 10, snapshots).
    static func background(_ canvas: Canvas, look: Look) {
        if canvas.isOffscreen || Appearance.prefersOpaque { canvas.fill(canvas.bounds, look.surface) }
    }

    static func draw(_ canvas: Canvas, _ controls: Controls, state: AppState, model: OnboardingModel, handlers: Handlers,
                     now: Date = Date()) {
        let look = controls.look
        let size = canvas.size
        let content = RectF(x: 0, y: 0, width: size.width, height: size.height - barHeight)
        let t = model.transition(at: now)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        // Welcome fades only: its mark is drawn through clips, which land wrong inside a transform.
        let slide: Float = model.reduceMotion || model.step == .welcome ? 0 : (model.forward ? 24 : -24) * (1 - eased)
        canvas.clipped(to: content, radius: 0) {
            canvas.withOpacity(eased) {
                canvas.transformed(dx: slide) {
                    switch model.step {
                    case .welcome: welcome(canvas, look: look, content: content, model: model, now: now)
                    case .howItWorks: OnboardingDemo.page(canvas, look: look, content: content, state: state, model: model, now: now)
                    case .connect: OnboardingConnect.page(canvas, controls, look: look, content: content, state: state, model: model,
                                                          handlers: handlers, now: now)
                    case .pace: pace(canvas, controls, look: look, content: content, state: state, handlers: handlers)
                    case .done: OnboardingDone.page(canvas, controls, look: look, content: content, state: state, model: model,
                                                    handlers: handlers, now: now)
                    }
                }
            }
        }
        bottomBar(canvas, controls, look: look, state: state, model: model, handlers: handlers)
    }

    // MARK: The bottom bar

    /// Skip setup, the page dots, Back (Esc) and Continue (primary, Enter).
    private static func bottomBar(_ canvas: Canvas, _ controls: Controls, look: Look, state: AppState, model: OnboardingModel,
                                  handlers: Handlers) {
        let size = canvas.size
        let top = size.height - barHeight
        canvas.fill(RectF(x: 0, y: top, width: size.width, height: 1), look.stroke.opacity(0.6))
        let mid = top + barHeight / 2
        let height = Theme.Size.smallButtonHeight
        // The Connect step has its own skip ("Skip for now", its Continue button).
        if model.step != .done, model.step != .connect {
            let title = "Skip setup"
            let textSize = Canvas.measure(title, style: Theme.Typography.row)
            let rect = RectF(x: 24, y: mid - textSize.height / 2, width: textSize.width, height: textSize.height)
            let hot = controls.isHovered("skipSetup")
            canvas.text(title, at: PointF(x: rect.x, y: rect.y), style: Theme.Typography.row, hot ? look.text : look.secondary)
            controls.region("skipSetup", rect.insetBy(-6, -6), focusable: true) { handlers.skip() }
            if controls.isFocusVisible("skipSetup") {
                canvas.stroke(rect.insetBy(-5, -4), radius: 5, width: 2, look.accent)
            }
        }
        pageDots(canvas, look: look, centre: PointF(x: size.width / 2, y: mid), current: model.step.rawValue,
                 count: OnboardingStep.allCases.count)
        let installed = state.integrations.contains { $0.status.isInstalled }
        let continueTitle: String
        switch model.step {
        case .welcome: continueTitle = "Get started"
        case .connect where !installed: continueTitle = "Skip for now"
        case .done: continueTitle = "Done"
        default: continueTitle = "Continue"
        }
        let continueRole: Controls.Role = model.step == .connect && !installed ? .secondary : .primary
        var right = size.width - 24
        let continueWidth = buttonWidth(continueTitle)
        controls.button(canvas, id: "continue", RectF(x: right - continueWidth, y: mid - height / 2, width: continueWidth, height: height),
                        continueTitle, role: continueRole) { handlers.advance() }
        right -= continueWidth + 12
        if model.step != .welcome {
            let backWidth = buttonWidth("Back")
            controls.button(canvas, id: "back", RectF(x: right - backWidth, y: mid - height / 2, width: backWidth, height: height),
                            "Back", role: .secondary) { handlers.back() }
        }
    }

    /// The current page is a short accent capsule, the others small dots (shape, not only colour).
    static func pageDots(_ canvas: Canvas, look: Look, centre: PointF, current: Int, count: Int) {
        let total = Float(count - 1) * (6 + 6) + 16
        var x = centre.x - total / 2
        for index in 0..<count {
            let w: Float = index == current ? 16 : 6
            canvas.fill(RectF(x: x, y: centre.y - 3, width: w, height: 6), radius: 3,
                        index == current ? look.accent : look.text.opacity(0.2))
            x += w + 6
        }
    }

    static func buttonWidth(_ title: String) -> Float {
        (Canvas.measure(title, style: Theme.Typography.smallButton).width + 2 * Theme.Size.buttonPadding).rounded(.up)
    }

    // MARK: Shared page layout

    /// A step's title and its one sentence, centred; returns where the step's content starts.
    static func header(_ canvas: Canvas, look: Look, content: RectF, title: String, sentence: String) -> Float {
        let width = content.width - 64
        var y = content.y + 28
        y += canvas.text(title, at: PointF(x: 32, y: y), width: width, style: titleStyle, look.text).height
        y += 8
        let sentenceWidth = min(440, width)
        y += canvas.text(sentence, at: PointF(x: (content.width - sentenceWidth) / 2, y: y), width: sentenceWidth,
                         style: sentenceStyle, look.secondary).height
        return y + 18
    }

    /// A rounded inset card on the window (the Connect rows, the Done tips).
    static func card(_ canvas: Canvas, _ rect: RectF, look: Look) {
        canvas.fill(rect, radius: Theme.Radius.settingsSection, look.dark ? Colour.white.opacity(0.05) : Colour.black.opacity(0.035))
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: Theme.Radius.settingsSection, width: 1,
                      look.dark ? Colour.white.opacity(0.08) : Colour.black.opacity(0.07))
    }

    /// A glyph of the system icon font (Segoe Fluent Icons), by code point.
    static func icon(_ canvas: Canvas, _ glyph: String, centre: PointF, size: Float, _ colour: Colour) {
        let box = RectF(x: centre.x - size, y: centre.y - size * 0.75, width: size * 2, height: size * 1.5)
        canvas.text(glyph, in: box, style: TextStyle(size: size, align: .center, family: Glyphs.iconFamily), colour)
    }

    /// The mark in the brand gradient (mint to indigo), its eyes cut out: punched through to the
    /// Mica backdrop on a window, painted in the surface colour when drawn opaque.
    static func brandMark(_ canvas: Canvas, in rect: RectF, look: Look) {
        let slices = 32
        let w = rect.width / Float(slices)
        for index in 0..<slices {
            let t = Float(index) / Float(slices - 1)
            let colour = Theme.Palette.mint.mixed(with: Theme.Palette.indigo, t)
            canvas.clipped(to: RectF(x: rect.x + Float(index) * w, y: rect.y - 2, width: w + 1, height: rect.height + 4), radius: 0) {
                BrandMark.draw(.tag, in: rect, on: canvas, colour)
            }
        }
        if canvas.isOffscreen || Appearance.prefersOpaque {
            BrandMark.draw(.eyes, in: rect, on: canvas, look.surface)
        } else {
            canvas.erasing { BrandMark.draw(.eyes, in: rect, on: canvas, .black) }
        }
    }

    // MARK: 1. Welcome

    /// The mark arrives (a short fade and slide); a headline, one sentence, "No permissions needed."
    private static func welcome(_ canvas: Canvas, look: Look, content: RectF, model: OnboardingModel, now: Date) {
        let hero = Theme.Typography.onboardingHero
        let lead = TextStyle(size: 15, align: .center, wrap: true)
        let headline = "Breaks that wait for your agent"
        let sentence = "Breakpoint offers a short stretch or eye rest while your coding agent works, and calls you back when it needs you."
        let heroWidth = content.width - 80
        let leadWidth = min(420, heroWidth)
        let heroSize = Canvas.measure(headline, style: hero, width: heroWidth)
        let leadSize = Canvas.measure(sentence, style: lead, width: leadWidth)
        let markHeight: Float = 64
        let total = markHeight + 28 + heroSize.height + 12 + leadSize.height + 24 + 30
        var y = content.y + ((content.height - total) / 2).rounded()

        var arrival: Float = 1
        if !model.frozen && !model.reduceMotion {
            let p = Float(min(1, max(0, (now.timeIntervalSince(model.shownAt) - 0.1) / 0.5)))
            arrival = 1 - pow(1 - p, 3)
        }
        let markWidth = markHeight * BrandMark.bounds.width / BrandMark.bounds.height
        canvas.withOpacity(arrival) {
            brandMark(canvas, in: RectF(x: content.midX - markWidth / 2 - 6 * (1 - arrival), y: y, width: markWidth, height: markHeight),
                      look: look)
        }
        y += markHeight + 28
        canvas.text(headline, at: PointF(x: 40, y: y), width: heroWidth, style: hero, look.text)
        y += heroSize.height + 12
        canvas.text(sentence, at: PointF(x: (content.width - leadWidth) / 2, y: y), width: leadWidth, style: lead, look.secondary)
        y += leadSize.height + 24

        let label = "No permissions needed."
        let labelSize = Canvas.measure(label, style: Theme.Typography.bodySemibold)
        let pillWidth = 14 + 16 + 6 + labelSize.width + 14
        let pill = RectF(x: content.midX - pillWidth / 2, y: y, width: pillWidth, height: 30)
        canvas.fill(pill, radius: 15, look.accent.opacity(look.dark ? 0.14 : 0.10))
        icon(canvas, "\u{EA18}", centre: PointF(x: pill.x + 14 + 8, y: pill.midY), size: 14, look.accent)
        canvas.text(label, at: PointF(x: pill.x + 14 + 16 + 6, y: pill.midY - labelSize.height / 2), style: Theme.Typography.bodySemibold,
                    look.text)
    }

    // MARK: 4. Pick your pace

    /// The preset cards from Settings, Balanced preselected; ← → change the selection.
    private static func pace(_ canvas: Canvas, _ controls: Controls, look: Look, content: RectF, state: AppState, handlers: Handlers) {
        var y = header(canvas, look: look, content: content, title: "Pick your pace",
                       sentence: "Choose how often breaks are offered. Each card shows two hours of steady work; you can change it any time in Settings.")
        let rowWidth: Float = 496
        let x = content.midX - rowWidth / 2
        let gap: Float = 12
        let cardWidth = (rowWidth - 2 * gap) / 3
        let cardHeight: Float = 12 + 44 + 10 + 17 + 2 + 30 + 12
        for (index, preset) in CadencePreset.cards.enumerated() {
            let cadence = preset.cadence ?? state.settings.cadence
            let rect = RectF(x: x + Float(index) * (cardWidth + gap), y: y, width: cardWidth, height: cardHeight)
            presetCard(canvas, controls, rect, look: look, preset: preset, cadence: cadence,
                       selected: state.settings.preset == preset) { handlers.choosePreset(preset) }
        }
        y += cardHeight + 10

        // "▏ Eye rest  ● Stretch  Two hours of steady work" ... "← → to choose".
        let legendStyle = TextStyle(size: 11)
        var lx = x + 4
        let midY = y + 7
        canvas.fill(RectF(x: lx, y: midY - 5, width: 2, height: 10), radius: 1, look.text.opacity(0.45))
        lx += 7
        lx += canvas.text("Eye rest", at: PointF(x: lx, y: y), style: legendStyle, look.secondary).width + 14
        canvas.circle(PointF(x: lx + 4, y: midY), radius: 4, look.accent)
        lx += 13
        lx += canvas.text("Stretch", at: PointF(x: lx, y: y), style: legendStyle, look.secondary).width + 14
        canvas.text("Two hours of steady work", at: PointF(x: lx, y: y), style: legendStyle, look.hint)
        keyHint(canvas, look: look, trailing: PointF(x: x + rowWidth - 4, y: midY), keys: ["←", "→"], text: "to choose")
    }

    /// Keycaps then words, ending at `trailing`.
    static func keyHint(_ canvas: Canvas, look: Look, trailing: PointF, keys: [String], text: String) {
        let style = TextStyle(size: 11)
        let textWidth = Canvas.measure(text, style: style).width
        let capWidths = keys.map { max(18, Canvas.measure($0, style: Theme.Typography.keycap).width + 10) }
        var x = trailing.x - textWidth - 5 - capWidths.reduce(0, +) - Float(max(0, keys.count - 1)) * 4
        for (key, width) in zip(keys, capWidths) {
            let cap = RectF(x: x, y: trailing.y - 9, width: width, height: 18)
            canvas.fill(cap, radius: Theme.Radius.keycap, look.fill)
            canvas.stroke(cap.insetBy(0.5, 0.5), radius: Theme.Radius.keycap, width: 1, look.stroke)
            canvas.text(key, in: cap, style: Theme.Typography.keycap, look.secondary)
            x += width + 4
        }
        canvas.text(text, at: PointF(x: x + 1, y: trailing.y - Canvas.measure(text, style: style).height / 2), style: style, look.secondary)
    }

    /// A preset card: the two-hour timeline, the title and cadence, and the selection (a check and
    /// the accent border).
    private static func presetCard(_ canvas: Canvas, _ controls: Controls, _ rect: RectF, look: Look, preset: CadencePreset,
                                   cadence: Cadence, selected: Bool, action: @escaping () -> Void) {
        let id = "preset.\(preset.rawValue)"
        let hot = controls.isHovered(id)
        canvas.fill(rect, radius: Theme.Radius.settingsSection,
                    look.dark ? Colour.white.opacity(hot ? 0.08 : 0.05) : Colour.white.opacity(hot ? 0.85 : 1))
        if selected {
            canvas.stroke(rect.insetBy(1, 1), radius: Theme.Radius.settingsSection - 1, width: 2, look.accent)
        } else {
            canvas.stroke(rect.insetBy(0.5, 0.5), radius: Theme.Radius.settingsSection, width: 1, look.text.opacity(0.12))
        }
        let inner = rect.insetBy(12, 12)
        timeline(canvas, RectF(x: inner.x, y: inner.y + 8, width: inner.width, height: 30), look: look, cadence: cadence)
        let textTop = inner.y + 44 + 10
        canvas.text(preset.title, at: PointF(x: inner.x, y: textTop), style: Theme.Typography.bodySemibold, look.text)
        let detail = "Eye rest every \(cadence.eyesEveryMinutes) min\nStretch every \(cadence.moveEveryMinutes) min"
        canvas.text(detail, at: PointF(x: inner.x, y: textTop + 19), width: inner.width - 22, style: Theme.Typography.rowDescription,
                    look.secondary)
        let check = PointF(x: inner.maxX - 8, y: textTop + 9)
        if selected {
            canvas.circle(check, radius: 8, look.accent)
            canvas.path("MLL", [check.x - 3.5, check.y, check.x - 1, check.y + 2.6, check.x + 3.8, check.y - 2.6], look.onAccent, stroke: 1.6)
        } else {
            canvas.ring(check, radius: 7.5, width: 1.2, look.secondary.opacity(0.6))
        }
        controls.region(id, rect, focusable: true, action: action)
        if controls.isFocusVisible(id) {
            canvas.stroke(rect.insetBy(-3, -3), radius: Theme.Radius.settingsSection + 3, width: 2, look.accent)
        }
    }

    /// Where breaks would fall in two hours of steady work: ticks for eye rests, dots for stretches,
    /// hour labels under the track.
    private static func timeline(_ canvas: Canvas, _ rect: RectF, look: Look, cadence: Cadence) {
        let track = RectF(x: rect.x + 2, y: rect.y + 6, width: rect.width - 4, height: 4)
        canvas.fill(track, radius: 2, look.text.opacity(0.10))
        for mark in OnboardingSchedule(cadence: cadence).marks {
            let x = track.x + track.width * Float(mark.minute) / 120
            if mark.isMove {
                canvas.circle(PointF(x: x, y: track.midY), radius: 4.5, look.accent)
                canvas.ring(PointF(x: x, y: track.midY), radius: 4.25, width: 0.5, look.text.opacity(0.15))
            } else {
                canvas.fill(RectF(x: x - 1, y: track.midY - 5, width: 2, height: 10), radius: 1, look.text.opacity(0.45))
            }
        }
        let labelStyle = TextStyle(size: 9, weight: 500)
        let labelY = rect.y + 18
        canvas.text("0", at: PointF(x: track.x, y: labelY), style: labelStyle, look.secondary)
        let hour = Canvas.measure("1 h", style: labelStyle).width
        canvas.text("1 h", at: PointF(x: track.midX - hour / 2, y: labelY), style: labelStyle, look.secondary)
        let two = Canvas.measure("2 h", style: labelStyle).width
        canvas.text("2 h", at: PointF(x: track.maxX - two, y: labelY), style: labelStyle, look.secondary)
    }
}

/// Where breaks would fall in `span` minutes of steady work at a cadence, by the engine's rules (a
/// due stretch wins over a due eye rest; a stretch resets both timers, an eye rest screen time
/// only), as the macOS `BreakSchedule` draws the preset cards.
struct OnboardingSchedule {
    struct Mark {
        let minute: Int
        let isMove: Bool
    }

    var marks: [Mark] = []

    init(cadence: Cadence, span: Int = 120) {
        var screen = 0, still = 0
        for minute in 1...span {
            screen += 1
            still += 1
            if still >= cadence.moveEveryMinutes {
                marks.append(Mark(minute: minute, isMove: true))
                screen = 0
                still = 0
            } else if screen >= cadence.eyesEveryMinutes {
                marks.append(Mark(minute: minute, isMove: false))
                screen = 0
            }
        }
    }
}
