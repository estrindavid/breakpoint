import BreakpointCore
import BreakpointRuntime
import Foundation

/// Everything about an overlay frame that is not in `ActiveBreakState` (the Mac's
/// `OverlayPresentation`): the clock at frame precision, fades, focus, pulses and transitions.
/// The controller fills it every frame; snapshots set it by hand. The view never reads the clock.
struct OverlayPresentation {
    /// Seconds since the break started, at frame precision (breathing, pacing, the Skip guard and
    /// the closing moment draw from it).
    var liveElapsed: TimeInterval
    /// False on the other displays: the backdrop and a small timer only.
    var showsContent = true
    var focused: OverlayControl?
    /// The agent chip's working dot (0.4…1, 0.5 Hz).
    var dotOpacity: Float = 1
    /// The hint line's opacity multiplier (1 → 0.5 → 1 on a single Esc).
    var hintPulse: Float = 1
    /// Content opacity during the entrance and exit (the window's own opacity fades the backdrop).
    var contentOpacity: Float = 1
    /// `walk` ambient, 0…1 (eased over 0.3 s by the controller).
    var ambient: Float = 0
    /// A `move` step change: the previous step's words and how far the slide has gone (0…1).
    var stepChange: (previous: OverlayStepText, progress: Float)?
    /// The agent chip changing colour: the previous chip and how far the cross-fade has gone.
    var chipChange: (previous: AgentChipState, progress: Float)?
    var reduceMotion = false
    var highContrast = false

    init(liveElapsed: TimeInterval) { self.liveElapsed = liveElapsed }
}

/// The words a `move` step shows (they slide out as the next step's slide in).
struct OverlayStepText: Equatable {
    var title: String
    var instruction: String
    var cue: String?

    init(_ active: ActiveBreakState) {
        title = active.title
        instruction = active.instruction
        cue = active.step?.step.cue ?? active.detail
    }
}

/// The break overlay for one display (SPEC §3.3, §3.4): backdrop, then the centred column (agent
/// chip, title, instruction, kind line, hairline, guide, controls, hint), or on the other displays
/// the backdrop and a small timer. Pure: the same function draws the live windows and snapshots.
///
/// Layout by baselines, as the Mac's `OverlayColumnLayout`: the text group (title cap height to the
/// instruction's last baseline) is centred at 44% of the height; the instruction's first baseline
/// is 58 below the title's; the kind line 16 below the instruction; the hairline 44 below the
/// instruction's (or kind line's) baseline; a plain timer's centre 66 below the hairline, a ring's
/// top 32 below it; the controls' centre 96 above the bottom; the hint 12 below the controls. If
/// the guide would crowd the controls, the group moves up (never above the agent chip).
@MainActor
enum OverlayView {
    struct Handlers {
        var skip: () -> Void = {}
        var done: () -> Void = {}
        var extend: () -> Void = {}
        var primary: () -> Void = {}
        var skipTour: () -> Void = {}
    }

    static func draw(_ canvas: Canvas, _ controls: Controls, _ active: ActiveBreakState, _ p: OverlayPresentation,
                     handlers: Handlers) {
        let ambient = isAmbient(active) ? p.ambient : 0
        guard p.showsContent else {
            OverlayBackdrop.drawSecondary(canvas, ambient: ambient, highContrast: p.highContrast)
            otherDisplay(canvas, active, p)
            return
        }
        OverlayBackdrop.draw(canvas, ambient: ambient, highContrast: p.highContrast)
        var p = p
        p.ambient = ambient
        Column(canvas: canvas, controls: controls, active: active, p: p, handlers: handlers).draw()
    }

    /// Ambient applies to `walk` only, and never while an agent needs you.
    static func isAmbient(_ active: ActiveBreakState) -> Bool {
        active.ambient && active.kind == .walk && !active.needsYou
    }

    /// Other displays: the backdrop and a 13 pt timer at 60%, 40 DIPs below the top.
    private static func otherDisplay(_ canvas: Canvas, _ active: ActiveBreakState, _ p: OverlayPresentation) {
        let text = active.kind == .walk ? DurationFormat.clock(active.elapsed, rounding: .down) : DurationFormat.clock(active.remaining)
        let style = TextStyle(size: 13, weight: 600, monospacedDigits: true, align: .center)
        canvas.withOpacity(p.contentOpacity) {
            canvas.text(text, at: PointF(x: 0, y: OverlayMetrics.otherDisplayTimerTop), width: canvas.bounds.width, style: style,
                        Colour.white.opacity(Theme.TextStep.secondary.opacity))
        }
    }

    /// The hint line's pieces (SPEC §3.3 row 8), in Windows key names.
    static func hint(_ active: ActiveBreakState) -> [OverlayParts.Piece] {
        if active.isPreview { return [.key("Esc"), .text("to close the preview")] }
        if active.needsYou { return [.key("Enter"), .text("Back to work")] }
        if OverlayControls.hasPrimary(active) {
            return [.key("Esc"), .key("Esc"), .text("to skip  ·  "), .key("Enter"), .text(OverlayControls.primaryTitle(active))]
        }
        if active.doneAvailable { return [.key("Enter"), .text("Done")] }
        return [.key("Esc"), .key("Esc"), .text("to skip")]
    }

    /// The `Controls` id of an overlay control (focus and hover).
    static func controlID(_ control: OverlayControl) -> String {
        switch control {
        case .skip: return "skip"
        case .extend: return "extend"
        case .primary: return "primary"
        }
    }

    /// Text measurements the layout needs: a line's height and its first baseline (DirectWrite
    /// puts the baseline at the font's ascent, about 81% of a Segoe UI Variable line).
    static func lineHeight(_ style: TextStyle) -> Float { Canvas.measure("Ag", style: TextStyle(size: style.size, weight: style.weight)).height }
    static func ascent(_ style: TextStyle) -> Float { lineHeight(style) * 0.81 }
}

/// One frame of the column: measures, places by baselines and draws.
@MainActor
private struct Column {
    let canvas: Canvas
    let controls: Controls
    let active: ActiveBreakState
    let p: OverlayPresentation
    let handlers: OverlayView.Handlers

    private var width: Float { canvas.bounds.width }
    private var height: Float { canvas.bounds.height }
    private var cx: Float { width / 2 }
    private var columnWidth: Float { min(Theme.Size.overlayColumnMaxWidth, width - 96) }
    private var titleWidth: Float { min(width - 96, 1120) }
    private var textDim: Float { 1 - 0.5 * p.ambient }
    private var completion: OverlayCompletionFrame? {
        active.completion.map { OverlayCompletionFrame.at(max(0, p.liveElapsed - $0.at), reduceMotion: p.reduceMotion) }
    }
    private var content: Float { Float(completion?.content ?? 1) }
    private var chrome: Float { p.contentOpacity }

    static let instructionStyle = TextStyle(size: 19, align: .center, wrap: true)
    static let smallTimer = TextStyle(size: 15, monospacedDigits: true, align: .center)

    /// The title's style, shrunk (to 60% at most) so it stays on one line.
    private func titleStyle(_ text: String) -> TextStyle {
        let base = Theme.Typography.overlayTitle(displayWidth: width)
        let measured = Canvas.measure(text, style: TextStyle(size: base.size, weight: base.weight)).width
        guard measured > titleWidth else { return base }
        let size = max(base.size * 0.6, (base.size * titleWidth / measured * 2).rounded(.down) / 2)
        return TextStyle(size: size, weight: base.weight, align: .center)
    }

    func draw() {
        let L = Theme.Size.self
        // Chip and the coach line under it.
        let chipTop = L.overlayChipTop
        var chipBottom = chipTop + L.agentChipHeight
        let chipCoach: String? = active.isRehearsal
            ? (active.agentChip.tone == .mint ? TourCopy.breakChipDone : TourCopy.breakChipWorking)
            : (active.isPreview ? nil : active.hint)
        var chipCoachOrigin: PointF?
        if let chipCoach {
            let size = OverlayParts.coachSize(chipCoach, pointing: .up)
            chipCoachOrigin = PointF(x: cx - size.width / 2, y: chipBottom + OverlayMetrics.coachGap)
            chipBottom += OverlayMetrics.coachGap + size.height
        }

        // Bottom chrome.
        let controlsCentre = height - L.controlsCentreFromBottom
        let controlsTop = controlsCentre - L.buttonHeight / 2

        // The text group, relative to the title's baseline (0).
        let tStyle = titleStyle(active.title)
        let titleCap = tStyle.size * 0.7
        let iStyle = Self.instructionStyle
        let iLine = OverlayView.lineHeight(iStyle)
        let iSize = Canvas.measure(active.instruction, style: iStyle, width: columnWidth)
        let iLines = max(1, Int((iSize.height / iLine).rounded()))
        let instructionFirst = L.titleToInstructionBaseline
        let instructionLast = instructionFirst + Float(iLines - 1) * iLine
        let groupCentre = (-titleCap + instructionLast) / 2
        var cursor = instructionLast
        let kindLine = active.step?.step.cue ?? active.detail
        var kindTop: Float?
        if kindLine != nil {
            kindTop = instructionLast + OverlayMetrics.kindLineGap
            cursor = instructionLast + OverlayMetrics.kindLineGap + 17
        }
        let hairlineY = cursor + L.instructionToHairline
        let timerLine = OverlayView.lineHeight(Theme.Typography.timer)
        let guideTop: Float
        switch active.kind {
        case .eyes: guideTop = hairlineY + L.hairlineToTimerCentre - (OverlayView.ascent(Theme.Typography.timer) - 38 * 0.7 / 2)
        default: guideTop = hairlineY + OverlayMetrics.hairlineToRingTop
        }
        let guideBottom = guideTop + guideHeight(timerLine: timerLine)

        var titleBaseline = height * L.overlayOpticalCentre - groupCentre
        let overflow = (titleBaseline + guideBottom) - (controlsTop - Theme.Spacing.xl)
        if overflow > 0 {
            let room = max(0, (titleBaseline - titleCap) - (chipBottom + Theme.Spacing.xl))
            titleBaseline -= min(overflow, room)
        }

        // Row 1: the agent chip, and the coach line under it.
        canvas.withOpacity(chrome) { drawChip(top: chipTop) }
        if let chipCoach, let origin = chipCoachOrigin {
            canvas.withOpacity(chrome * (active.isRehearsal ? 1 : 1 - p.ambient)) {
                OverlayParts.coachLine(canvas, chipCoach, pointing: .up, origin: origin, highContrast: p.highContrast)
            }
        }

        // Title (or the closing line), instruction, kind line.
        let body = chrome * textDim
        let titleTop = titleBaseline - OverlayView.ascent(tStyle)
        let instructionTop = titleBaseline + instructionFirst - OverlayView.ascent(iStyle)
        words(OverlayStepText(active), titleTop: titleTop, instructionTop: instructionTop,
              kindTop: kindTop.map { titleBaseline + $0 }, tStyle: tStyle, opacity: body, change: p.stepChange)
        if let line = active.completion?.line, let completion {
            let style = titleStyle(line)
            canvas.withOpacity(chrome * Float(completion.line)) {
                canvas.text(line, at: PointF(x: 0, y: titleBaseline - OverlayView.ascent(style)), width: width, style: style, .white)
            }
        }

        // Hairline and guide.
        canvas.withOpacity(body) {
            let y = titleBaseline + hairlineY
            canvas.fill(RectF(x: cx - L.hairlineWidth / 2, y: y - 0.5, width: L.hairlineWidth, height: 1),
                        Colour.white.opacity(Theme.TextStep.hairline.opacity))
        }
        canvas.withOpacity(chrome) { guide(top: titleBaseline + guideTop, timerLine: timerLine) }

        // Controls and hint (hidden in ambient, faded by the closing moment).
        let controlsVisible = 1 - p.ambient
        let controlsWidth = drawControls(centre: controlsCentre, opacity: chrome * controlsVisible * content,
                                         interactive: p.ambient < 0.5 && chrome > 0.5 && active.completion == nil)
        canvas.withOpacity(chrome * p.hintPulse * controlsVisible * content) {
            OverlayParts.keyHint(canvas, pieces: OverlayView.hint(active), centreX: cx,
                                 top: controlsCentre + L.buttonHeight / 2 + OverlayMetrics.hintGap,
                                 colour: Colour.white.opacity(Theme.TextStep.hint.opacity), highContrast: p.highContrast)
        }

        // The tour's sample break: a coach line beside the controls and the rehearsal footer.
        let hasFooter = active.kind == .move
        if active.isRehearsal {
            canvas.withOpacity(chrome) {
                let size = OverlayParts.coachSize(TourCopy.breakControls, pointing: .leading)
                OverlayParts.coachLine(canvas, TourCopy.breakControls, pointing: .leading,
                                       origin: PointF(x: cx + controlsWidth / 2 + 10, y: controlsCentre - size.height / 2),
                                       highContrast: p.highContrast)
                rehearsalFooter(bottom: height - 20 - (hasFooter ? 24 : 0))
            }
        }
        if hasFooter {
            canvas.withOpacity(chrome * textDim) {
                let style = TextStyle(size: 11, align: .center)
                let baseline = height - 24
                canvas.text(BreakCopyLibrary.wellnessDisclaimer, at: PointF(x: cx - columnWidth / 2, y: baseline - OverlayView.ascent(style)),
                            width: columnWidth, style: style, Colour.white.opacity(Theme.TextStep.hint.opacity))
            }
        }
    }

    // MARK: Parts

    private func drawChip(top: Float) {
        if let change = p.chipChange, change.progress < 1 {
            canvas.withOpacity(1 - change.progress) {
                OverlayParts.agentChip(canvas, centreX: cx, top: top, chip: change.previous, dotOpacity: 1, tone: change.previous.tone)
            }
            canvas.withOpacity(change.progress) {
                OverlayParts.agentChip(canvas, centreX: cx, top: top, chip: active.agentChip,
                                       dotOpacity: active.agentChip.isWorking ? p.dotOpacity : 1, tone: active.agentChip.tone)
            }
            return
        }
        OverlayParts.agentChip(canvas, centreX: cx, top: top, chip: active.agentChip,
                               dotOpacity: active.agentChip.isWorking ? p.dotOpacity : 1, tone: active.agentChip.tone)
    }

    /// Title, instruction and kind line; on a `move` step change the old words slide 12 left and
    /// fade as the new ones come in from 12 right (Reduce Motion: a cross-fade).
    private func words(_ text: OverlayStepText, titleTop: Float, instructionTop: Float, kindTop: Float?, tStyle: TextStyle,
                       opacity: Float, change: (previous: OverlayStepText, progress: Float)?) {
        let completionTitle = Float(completion?.title ?? 1)
        func one(_ words: OverlayStepText, dx: Float, alpha: Float) {
            canvas.transformed(dx: dx) {
                canvas.withOpacity(alpha * completionTitle) {
                    canvas.text(words.title, at: PointF(x: 0, y: titleTop), width: width, style: titleStyle(words.title), .white)
                }
                canvas.withOpacity(alpha * content) {
                    canvas.text(words.instruction, at: PointF(x: cx - columnWidth / 2, y: instructionTop), width: columnWidth,
                                style: Self.instructionStyle, Colour.white.opacity(Theme.TextStep.body.opacity))
                    if let cue = words.cue, let kindTop { OverlayParts.cueChip(canvas, cue, centreX: cx, top: kindTop) }
                }
            }
        }
        if let change, change.progress < 1, change.previous != text {
            let t = change.progress
            let slide = p.reduceMotion ? 0 : OverlayMetrics.moveStepSlide
            one(change.previous, dx: -slide * t, alpha: opacity * (1 - t))
            one(text, dx: slide * (1 - t), alpha: opacity * t)
        } else {
            one(text, dx: 0, alpha: opacity)
        }
    }

    private func guideHeight(timerLine: Float) -> Float {
        let small = OverlayView.lineHeight(Self.smallTimer)
        switch active.kind {
        case .eyes: return timerLine
        case .move: return Theme.Size.moveRing + Theme.Spacing.m + Theme.Size.stepDot + Theme.Spacing.m + small
        case .walk: return Theme.Size.walkRing
        case .breathe: return Theme.Size.breatheRing + Theme.Spacing.m + small
        }
    }

    private var secondary: Colour { Colour.white.opacity(Theme.TextStep.secondary.opacity) }

    private func guide(top: Float, timerLine: Float) {
        let L = Theme.Size.self
        let timer = Theme.Typography.timer
        let completion = self.completion
        // The ring and timer keep their strength in ambient (only the words dim).
        let guideOpacity = content
        switch active.kind {
        case .eyes:
            canvas.withOpacity(guideOpacity) {
                canvas.text(DurationFormat.clock(active.remaining), at: PointF(x: 0, y: top), width: width, style: timer, secondary)
            }
            if let completion {
                let centre = PointF(x: cx, y: top + OverlayView.ascent(timer) - 38 * 0.7 / 2)
                OverlayParts.completionMark(canvas, centre: centre, diameter: OverlayMetrics.completionMarkEyes,
                                            lineWidth: L.walkRingStroke, startProgress: 0, frame: completion, highContrast: p.highContrast)
            }
        case .move:
            let centre = PointF(x: cx, y: top + L.moveRing / 2)
            canvas.withOpacity(guideOpacity) { moveGuide(centre: centre) }
            if let completion {
                OverlayParts.completionMark(canvas, centre: centre, diameter: L.moveRing, lineWidth: L.moveRingStroke,
                                            startProgress: moveStart, frame: completion, highContrast: p.highContrast)
            }
        case .walk:
            let centre = PointF(x: cx, y: top + L.walkRing / 2)
            canvas.withOpacity(guideOpacity) {
                OverlayParts.luminousRing(canvas, centre: centre, diameter: L.walkRing, lineWidth: L.walkRingStroke,
                                          progress: active.progress, highContrast: p.highContrast)
                centredText(DurationFormat.clock(active.elapsed, rounding: .down), centre: centre, style: timer, secondary)
            }
            if let completion {
                OverlayParts.completionMark(canvas, centre: centre, diameter: L.walkRing, lineWidth: L.walkRingStroke,
                                            startProgress: active.progress, frame: completion, highContrast: p.highContrast)
            }
        case .breathe:
            let centre = PointF(x: cx, y: top + L.breatheRing / 2)
            canvas.withOpacity(guideOpacity) {
                breatheRing(centre: centre)
                canvas.text(DurationFormat.clock(active.remaining), at: PointF(x: 0, y: top + L.breatheRing + Theme.Spacing.m),
                            width: width, style: Self.smallTimer, secondary)
            }
            if let completion {
                OverlayParts.completionMark(canvas, centre: centre, diameter: L.breatheRing, lineWidth: L.breatheRingStroke,
                                            startProgress: 1, frame: completion, highContrast: p.highContrast)
            }
        }
    }

    private func centredText(_ text: String, centre: PointF, style: TextStyle, _ colour: Colour) {
        let size = Canvas.measure(text, style: style)
        canvas.text(text, at: PointF(x: centre.x - size.width / 2, y: centre.y - size.height / 2), style: TextStyle(
            size: style.size, weight: style.weight, monospacedDigits: style.monospacedDigits), colour)
    }

    // MARK: move

    /// Seconds into the current step at frame precision (just short of its end, where a pace would
    /// wrap into a new repetition).
    private func stepElapsed(_ step: RoutineStepState) -> TimeInterval {
        let stepStart = active.elapsed - step.elapsed
        return min(max(p.liveElapsed - stepStart, 0), max(0, step.step.duration - 0.001))
    }

    /// Where the ring stood when the break completed (the closing ring starts there).
    private var moveStart: Double {
        guard let step = active.step else { return 1 }
        if let pace = TempoPacing.frame(tempo: step.step.tempo, at: min(step.elapsed, step.step.duration - 0.001)) {
            return pace.motion == .around ? 0 : pace.fullness
        }
        return step.progress
    }

    private func moveGuide(centre: PointF) {
        let L = Theme.Size.self
        if let step = active.step, !step.step.tempo.isEmpty,
           let frame = TempoPacing.frame(tempo: step.step.tempo, at: stepElapsed(step), stepped: p.reduceMotion) {
            let around = frame.motion == .around
            let level = around ? 0 : frame.fullness
            let head = around ? frame.fullness : min(frame.fullness, 1)
            let range = OverlayMetrics.breatheReducedFill
            canvas.circle(centre, radius: L.moveRing / 2 - L.moveRingStroke,
                          Theme.Palette.mint.opacity(Float(range.lowerBound + (range.upperBound - range.lowerBound) * level)))
            OverlayParts.luminousRing(canvas, centre: centre, diameter: L.moveRing, lineWidth: L.moveRingStroke, progress: head,
                                      tail: around ? head - OverlayMetrics.paceTravelArc : 0, highContrast: p.highContrast)
            let word = frame.label.prefix(1).uppercased() + frame.label.dropFirst()
            canvas.withOpacity(Float(wordOpacity(frame, step: step))) {
                centredText(word, centre: centre, style: Theme.Typography.breatheWord, .white)
            }
        } else {
            OverlayParts.luminousRing(canvas, centre: centre, diameter: L.moveRing, lineWidth: L.moveRingStroke,
                                      progress: active.step?.progress ?? 0, highContrast: p.highContrast)
            centredText(DurationFormat.clock(active.step?.remaining ?? 0), centre: centre, style: Theme.Typography.timer, secondary)
        }
        var y = centre.y + L.moveRing / 2 + Theme.Spacing.m
        if let step = active.step {
            let dots = Float(step.count) * L.stepDot + Float(max(0, step.count - 1)) * L.stepDotGap
            var x = cx - dots / 2 + L.stepDot / 2
            for i in 0..<step.count {
                let colour = i < step.index ? Theme.Palette.mint
                    : (i == step.index ? Colour.white : Colour.white.opacity(Theme.TextStep.hairline.opacity))
                canvas.circle(PointF(x: x, y: y + L.stepDot / 2), radius: L.stepDot / 2, colour)
                x += L.stepDot + L.stepDotGap
            }
            y += L.stepDot + Theme.Spacing.m
        }
        canvas.text("\(DurationFormat.clock(active.remaining)) left", at: PointF(x: 0, y: y), width: width, style: Self.smallTimer, secondary)
    }

    /// The phase word dips to 35% around each turn (never at the step's own start or end).
    private func wordOpacity(_ frame: PaceFrame, step: RoutineStepState) -> Double {
        let half = (p.reduceMotion ? OverlayMetrics.reduceMotionFade : OverlayMetrics.paceWordFade) / 2
        let neighbours = TempoPacing.neighbours(tempo: step.step.tempo, phaseIndex: frame.phaseIndex)
        let isFirst = frame.repetition == 0 && frame.phaseIndex == 0
        let isLast = stepElapsed(step) + frame.phaseRemaining >= step.step.duration - 0.001
        let low = OverlayMetrics.paceWordTurnOpacity
        if frame.phaseElapsed < half, !isFirst, neighbours.previous != frame.label {
            return low + (1 - low) * frame.phaseElapsed / half
        }
        if frame.phaseRemaining < half, !isLast, neighbours.next != frame.label {
            return low + (1 - low) * frame.phaseRemaining / half
        }
        return 1
    }

    // MARK: breathe

    /// 220 ring, mint 20% fill and a 3 DIP stroke, scaling 0.72 → 1 and back (Reduce Motion: no
    /// scaling; the fill rises 10% → 30% and falls back), "In" / "Out" cross-fading inside.
    private func breatheRing(centre: PointF) {
        let L = Theme.Size.self
        let t = p.liveElapsed
        let fullness = OverlayBreath.fullness(at: t)
        let scale = p.reduceMotion ? 1 : L.breatheMinScale + (1 - L.breatheMinScale) * Float(fullness)
        let range = OverlayMetrics.breatheReducedFill
        let fill = p.reduceMotion ? range.lowerBound + (range.upperBound - range.lowerBound) * fullness : 0.20
        let radius = L.breatheRing / 2 * scale
        canvas.circle(centre, radius: radius, Theme.Palette.mint.opacity(Float(fill)))
        canvas.ring(centre, radius: radius - L.breatheRingStroke / 2, width: L.breatheRingStroke, Theme.Palette.mint)
        let inOpacity = Float(OverlayBreath.inWordOpacity(at: t))
        canvas.withOpacity(inOpacity) { centredText("In", centre: centre, style: Theme.Typography.breatheWord, .white) }
        canvas.withOpacity(1 - inOpacity) { centredText("Out", centre: centre, style: Theme.Typography.breatheWord, .white) }
    }

    // MARK: Controls

    private var skipEnabled: Bool { p.liveElapsed >= active.skipEnabledAt || active.isPreview }

    /// The controls row, centred on `centre`; returns its width.
    private func drawControls(centre: Float, opacity: Float, interactive: Bool) -> Float {
        let L = Theme.Size.self
        let style = Theme.Typography.button
        let list = OverlayControls.controls(for: active)
        let guardRing = !active.doneAvailable && !skipEnabled
        func title(_ control: OverlayControl) -> String {
            switch control {
            case .skip: return active.doneAvailable ? "Done" : "Skip"
            case .extend: return "1 more minute"
            case .primary: return OverlayControls.primaryTitle(active)
            }
        }
        let widths: [Float] = list.map { control in
            let text = Canvas.measure(title(control), style: TextStyle(size: style.size, weight: style.weight)).width
            let ring: Float = control == .skip && guardRing ? OverlayMetrics.skipGuardRing + 6 : 0
            return max(L.buttonHeight, text + ring + 2 * L.buttonPadding)
        }
        let total = widths.reduce(0, +) + L.overlayControlGap * Float(max(0, list.count - 1))
        guard opacity > 0.001 else { return total }
        var x = cx - total / 2
        canvas.withOpacity(opacity) {
            for (control, w) in zip(list, widths) {
                let rect = RectF(x: x, y: centre - L.buttonHeight / 2, width: w, height: L.buttonHeight)
                x += w + L.overlayControlGap
                switch control {
                case .skip where guardRing:
                    guardedSkip(rect)
                case .skip:
                    let done = active.doneAvailable
                    let role: Controls.Role = done && !OverlayControls.hasPrimary(active) ? .primary : .secondary
                    button(control, rect, title(control), role: role, interactive: interactive,
                           action: done ? handlers.done : handlers.skip)
                case .extend:
                    button(control, rect, title(control), role: .secondary, interactive: interactive, action: handlers.extend)
                case .primary:
                    button(control, rect, title(control), role: .primary, interactive: interactive, action: handlers.primary)
                }
            }
        }
        return total
    }

    private func button(_ control: OverlayControl, _ rect: RectF, _ title: String, role: Controls.Role, interactive: Bool,
                        action: @escaping () -> Void) {
        let id = OverlayView.controlID(control)
        if interactive {
            controls.button(canvas, id: id, rect, title, role: role, action: action)
        } else {
            // Shown but not clickable (ambient waking, the entrance): the same look, no region.
            let look = controls.look
            canvas.fill(rect, radius: rect.height / 2, role == .primary ? look.accent : look.fill)
            canvas.text(title, in: rect.insetBy(8, 0), style: Theme.Typography.button,
                        role == .primary ? look.onAccent : look.text.opacity(Theme.TextStep.label.opacity))
        }
        if p.highContrast, role != .primary {
            canvas.stroke(rect.insetBy(0.5, 0.5), radius: rect.height / 2, width: 1, Colour.white.opacity(0.30))
        }
    }

    /// Skip during its 3 s guard: disabled, a 14 DIP ring inside its leading edge filling.
    private func guardedSkip(_ rect: RectF) {
        let L = Theme.Size.self
        let progress = active.skipEnabledAt > 0 ? min(1, p.liveElapsed / active.skipEnabledAt) : 1
        canvas.withOpacity(0.55) {
            canvas.fill(rect, radius: rect.height / 2, controls.look.fill)
            let ringCentre = PointF(x: rect.x + L.buttonPadding + OverlayMetrics.skipGuardRing / 2, y: rect.midY)
            ProgressRing.draw(canvas, centre: ringCentre, radius: OverlayMetrics.skipGuardRing / 2 - 1, width: 2, progress: progress,
                              tint: Colour.white.opacity(0.75), track: Colour.white.opacity(0.2))
            let style = Theme.Typography.button
            let textX = ringCentre.x + OverlayMetrics.skipGuardRing / 2 + 6
            let size = Canvas.measure("Skip", style: TextStyle(size: style.size, weight: style.weight))
            canvas.text("Skip", at: PointF(x: textX, y: rect.midY - size.height / 2), style: TextStyle(size: style.size, weight: style.weight),
                        Colour.white.opacity(Theme.TextStep.label.opacity))
        }
    }

    // MARK: Rehearsal

    /// "[Rehearsal] Rehearsal with sample data. Nothing is recorded.  Skip tour", bottom-centred.
    private func rehearsalFooter(bottom: Float) {
        let style = TextStyle(size: 13)
        let label = TourCopy.rehearsalLabel
        let chipWidth = OverlayParts.smallMintChip(nil, "Rehearsal", at: PointF(x: 0, y: 0))
        let labelSize = Canvas.measure(label, style: style)
        let skipSize = Canvas.measure("Skip tour", style: style)
        let gap = Theme.Spacing.s
        let total = chipWidth + gap + labelSize.width + gap + skipSize.width
        let rowHeight = max(OverlayMetrics.smallChipHeight, labelSize.height)
        let top = bottom - rowHeight
        var x = cx - total / 2
        OverlayParts.smallMintChip(canvas, "Rehearsal", at: PointF(x: x, y: top + (rowHeight - OverlayMetrics.smallChipHeight) / 2))
        x += chipWidth + gap
        canvas.text(label, at: PointF(x: x, y: top + (rowHeight - labelSize.height) / 2), style: style, secondary)
        x += labelSize.width + gap
        let skipRect = RectF(x: x, y: top + (rowHeight - skipSize.height) / 2, width: skipSize.width, height: skipSize.height)
        let hot = controls.isHovered("skipTour")
        canvas.text("Skip tour", at: PointF(x: skipRect.x, y: skipRect.y), style: style,
                    Colour.white.opacity(hot ? Theme.TextStep.body.opacity : Theme.TextStep.secondary.opacity))
        controls.region("skipTour", skipRect.insetBy(-4, -4), action: handlers.skipTour)
    }
}
