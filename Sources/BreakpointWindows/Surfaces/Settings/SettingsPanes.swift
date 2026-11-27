import BreakpointCore
import BreakpointRuntime
import Foundation

// The eight panes (SPEC §3.9), row for row as the macOS panes in Sources/BreakpointKit/Settings,
// in Windows words where the Mac names macOS things. This file: the dispatcher and the Breaks,
// Routine, Pauses and Wind-down panes; SettingsPanesYou.swift has the others and the sheets.

@MainActor
enum SettingsPanes {
    static func draw(_ pane: SettingsPane, _ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        switch pane {
        case .breaks: breaks(&page, model, handlers)
        case .routine: routine(&page, model, handlers)
        case .pauses: pauses(&page, model, handlers)
        case .windDown: windDown(&page, model, handlers)
        case .integrations: integrations(&page, model, handlers)
        case .general: general(&page, model, handlers)
        case .privacy: privacy(&page, model, handlers)
        case .about: about(&page, model, handlers)
        }
    }

    // MARK: Shared pieces

    /// A pop-up of whole minutes inside a sentence; the current value is added if it is not one of
    /// the choices (a hand-edited file).
    static func minutes(_ id: String, values: [Int], current: Int, set: @escaping (Int) -> Void) -> SentencePart {
        let choices = values.contains(current) ? values : (values + [current]).sorted()
        return .menu(id: id, title: "\(current)", items: choices.map { value in ("\(value)", value == current, { set(value) }) })
    }

    static func update(_ handlers: SettingsHandlers, _ change: @escaping (inout Settings) -> Void) {
        handlers.actions.updateSettings(change)
    }

    /// A toggle row bound to one setting.
    static func toggle(_ page: inout SettingsPage, _ handlers: SettingsHandlers, _ model: SettingsModel,
                       _ keyPath: WritableKeyPath<Settings, Bool>, id: String, title: String, description: String, symbol: String,
                       enabled: Bool = true, options: (() -> Void)? = nil, optionsEnabled: Bool = true) {
        page.toggleRow(id, title: title, description: description, symbol: symbol, isOn: model.state.settings[keyPath: keyPath],
                       enabled: enabled, options: options, optionsEnabled: optionsEnabled) { on in
            handlers.actions.updateSettings { $0[keyPath: keyPath] = on }
        }
    }

    // MARK: Breaks

    /// Preset cards with mini timelines, the three cadence sentences, auto-start, strict mode,
    /// every display, Preview nudge · Preview break.
    static func breaks(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let settings = model.state.settings
        page.sectionHeader("Pace", detail: settings.preset == .custom ? "Custom" : nil)
        presetCards(&page, model, handlers)
        page.gap(10)
        timelineLegend(&page)
        page.gap(SettingsMetrics.sectionGap)

        page.section("Timing") { rows in
            rows.sentence([.text("Offer an eye rest after"),
                           minutes("eyes", values: Array(stride(from: 10, through: 60, by: 5)), current: settings.eyesEveryMinutes) { value in
                               update(handlers) { $0.setCadence(eyesEveryMinutes: value) }
                           },
                           .text("min of screen time")])
            rows.divider()
            rows.sentence([.text("Offer a stretch after"),
                           minutes("move", values: Array(stride(from: 20, through: 120, by: 5)), current: settings.moveEveryMinutes) { value in
                               update(handlers) { $0.setCadence(moveEveryMinutes: value) }
                           },
                           .text("min without moving")])
            rows.divider()
            rows.sentence([.text("Offer a walk when \(agentPossessive(model.state)) run is likely over"),
                           minutes("walk", values: Array(5...20), current: settings.walkThresholdMinutes) { value in
                               update(handlers) { $0.walkThresholdMinutes = value }
                           },
                           .text("min")])
        }

        page.section("When breaks start") { rows in
            toggle(&rows, handlers, model, \.autoStartEyes, id: "autoStartEyes", title: "Start eye rests by themselves",
                   description: "A 10-second countdown runs first; typing, clicking or scrolling cancels it.", symbol: "eye")
            rows.divider()
            toggle(&rows, handlers, model, \.strictAgentOnly, id: "strictAgentOnly", title: "Only during agent runs",
                   description: "Breakpoint offers breaks only when an agent or long command starts, never when you pause typing.",
                   symbol: "sparkle")
            rows.divider()
            toggle(&rows, handlers, model, \.fullBreakOnAllDisplays, id: "fullBreakOnAllDisplays",
                   title: "Show the full break on every display",
                   description: "Otherwise other displays show the blurred backdrop and a small timer.", symbol: "display.2")
        }

        page.section("Preview") { rows in
            rows.gap(4)
            rows.row("See a nudge or a break",
                     description: "Shows the real one for 5 seconds; Esc ends a break early. Nothing is recorded.",
                     symbol: "play.rectangle", minHeight: 0)
            let kind = model.ui.previewKind
            let line = RectF(x: rows.x + SettingsMetrics.rowIcon + 10, y: rows.y, width: rows.width, height: SettingsMetrics.smallButtonHeight)
            if let canvas = rows.canvas, let controls = rows.live(line) {
                let menu = RectF(x: line.x, y: line.y, width: SettingsDraw.menuWidth(kind.menuTitle), height: line.height)
                controls.menu(canvas, id: "previewKind", menu, title: kind.menuTitle, items: BreakKind.allCases.map { choice in
                    (choice.menuTitle, choice == kind, {
                        model.ui.previewKind = choice
                        handlers.changed()
                    })
                })
                rows.record("previewKind", menu)
                var x = menu.maxX + 8
                for (id, title, action) in [("previewNudge", "Preview nudge", handlers.actions.previewNudge),
                                            ("previewBreak", "Preview break", handlers.actions.previewBreak)] {
                    let width = Canvas.measure(title, style: Theme.Typography.smallButton).width + 28
                    let rect = RectF(x: x, y: line.y, width: width, height: line.height)
                    controls.button(canvas, id: id, rect, title) { action(kind) }
                    rows.record(id, rect)
                    x += width + 8
                }
            }
            rows.gap(line.height + 14)
        }
    }

    /// "your agent's" or, with one tool in use, e.g. "Claude Code's".
    static func agentPossessive(_ state: AppState) -> String {
        let sources = Set(state.integrations.filter { $0.status.isInstalled && $0.id != .shell }.map(\.id.source))
        if sources.count == 1, let source = sources.first { return "\(source.displayName)'s" }
        return "your agent's"
    }

    static let presetContentHeight: Float = 40

    /// The three preset cards (Gentle, Balanced, Frequent), each with its mini timeline.
    static func presetCards(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let settings = model.state.settings
        let presets = CadencePreset.cards
        let gap: Float = 12
        let width = ((page.width - gap * Float(presets.count - 1)) / Float(presets.count)).rounded(.down)
        let details = presets.map { preset -> (String, Cadence) in
            let cadence = preset.cadence ?? settings.cadence
            return ("Eye rest every \(cadence.eyesEveryMinutes) min\nStretch every \(cadence.moveEveryMinutes) min", cadence)
        }
        let height = zip(presets, details).map { preset, detail in
            SettingsPage.presetCardHeight(width: width, title: preset.title, detail: detail.0, contentHeight: presetContentHeight)
        }.max() ?? 120
        let look = page.look
        for (index, preset) in presets.enumerated() {
            let rect = RectF(x: page.x + Float(index) * (width + gap), y: page.y, width: width, height: height)
            let (detail, cadence) = details[index]
            page.presetCard("preset.\(preset.rawValue)", rect, title: preset.title, detail: detail, selected: settings.preset == preset,
                            contentHeight: presetContentHeight, action: { update(handlers) { $0.applyPreset(preset) } }) { canvas, area in
                timeline(canvas, RectF(x: area.x, y: area.y + 6, width: area.width, height: area.height - 6), cadence: cadence,
                         look: look)
            }
        }
        page.gap(height)
    }

    /// The mini timeline of two hours of steady work: a track, short ticks for eye rests, mint
    /// dots for stretches (shape, not only colour), hour labels underneath.
    static func timeline(_ canvas: Canvas, _ rect: RectF, cadence: Cadence, look: Look) {
        let inner = rect.insetBy(2, 0)
        let mid = inner.y + 8
        canvas.fill(RectF(x: inner.x, y: mid - 2, width: inner.width, height: 4), radius: 2, look.text.opacity(0.10))
        for mark in SettingsSchedule(cadence: cadence).marks {
            let x = inner.x + inner.width * Float(mark.minute) / 120
            if mark.isMove {
                canvas.circle(PointF(x: x, y: mid), radius: 4.5, look.accent)
                canvas.ring(PointF(x: x, y: mid), radius: 4.25, width: 0.5, look.text.opacity(0.15))
            } else {
                canvas.fill(RectF(x: x - 1, y: mid - 5, width: 2, height: 10), radius: 1, look.text.opacity(0.45))
            }
        }
        let style = TextStyle(size: 9, weight: 500, monospacedDigits: true)
        let labelY = mid + 10
        canvas.text("0", at: PointF(x: inner.x, y: labelY), style: style, look.secondary)
        canvas.text("1 h", at: PointF(x: inner.x, y: labelY), width: inner.width, style: TextStyle(size: 9, weight: 500, align: .center),
                    look.secondary)
        canvas.text("2 h", at: PointF(x: inner.x, y: labelY), width: inner.width, style: TextStyle(size: 9, weight: 500, align: .trailing),
                    look.secondary)
    }

    /// "▏ Eye rest  ● Stretch  Two hours of steady work" under the cards.
    static func timelineLegend(_ page: inout SettingsPage) {
        let style = Theme.Typography.rowDescription
        if let canvas = page.canvas {
            let look = page.look
            var x = page.x + 4
            let mid = page.y + 7
            canvas.fill(RectF(x: x, y: mid - 5, width: 2, height: 10), radius: 1, look.text.opacity(0.45))
            x += 7
            x += canvas.text("Eye rest", at: PointF(x: x, y: page.y), style: style, look.secondary).width + 14
            canvas.circle(PointF(x: x + 4, y: mid), radius: 4, look.accent)
            x += 13
            x += canvas.text("Stretch", at: PointF(x: x, y: page.y), style: style, look.secondary).width + 14
            canvas.text("Two hours of steady work", at: PointF(x: x, y: page.y), style: style, look.hint)
        }
        page.gap(Canvas.measure("Eye rest", style: style).height)
    }

    // MARK: Routine

    /// Resistance band; the routines a stretch takes turns through, each with a checkbox to leave
    /// it out; Preview a stretch. The AirPods movement check is not on Windows (no head-motion
    /// source: `WindowsPlatform` makes `UnavailableHeadphoneMotion`), so its section is hidden.
    static func routine(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let settings = model.state.settings
        page.section("Equipment") { rows in
            toggle(&rows, handlers, model, \.hasBand, id: "hasBand", title: "I have a resistance band",
                   description: "Band routines join the rotation.", symbol: "figure.strengthtraining.functional")
        }
        let routines = BuiltInRoutines.available(for: settings)
        let included = routines.filter { !settings.excludedRoutines.contains($0.id) }.count
        page.section("Stretches") { rows in
            for (index, routine) in routines.enumerated() {
                if index > 0 { rows.divider() }
                let isIn = !settings.excludedRoutines.contains(routine.id)
                let id = "routine.\(routine.id)"
                rows.row(routine.name, description: routine.summary, symbol: "figure.arms.open",
                         trailing: [.checkbox(id, isOn: isIn, enabled: !(isIn && included <= 1)) { on in
                             update(handlers) { $0.setRoutine(routine.id, excluded: !on) }
                         }], dimmed: !isIn)
            }
            rows.divider()
            rows.row("Each stretch is the next routine in turn, two minutes each.",
                     trailing: [.button("previewStretch", "Preview a stretch") { handlers.actions.previewBreak(.move) }], quiet: true)
        }
    }

    // MARK: Pauses

    /// Pause during calls (Options…: also when the camera is on), the away threshold sentence, and
    /// the read-only notes about typing, dictation and the cool-down, and about presenting.
    static func pauses(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let settings = model.state.settings
        let callDescription: String
        if !settings.pauseForMicrophone {
            callDescription = "Breaks may be offered during calls."
        } else {
            callDescription = settings.pauseForCamera
                ? "No break is offered while any microphone or camera is in use."
                : "No break is offered while any microphone is in use."
        }
        page.section("Calls") { rows in
            toggle(&rows, handlers, model, \.pauseForMicrophone, id: "pauseForMicrophone", title: "Pause during calls",
                   description: callDescription, symbol: "mic", options: {
                       handlers.openSheet(.callOptions)
                   }, optionsEnabled: settings.pauseForMicrophone)
            if let signals = model.state.status.pause.callSignals, let phrase = signals.phrase {
                rows.divider()
                rows.row("Paused now: \(phrase)", description: "Breaks come back a minute after the call ends.", symbol: "pause.circle",
                         trailing: [.button("resumeNow", "Resume now") { handlers.actions.resume() }])
            }
        }
        page.footnote("Breakpoint sees only that a microphone or camera is in use, never which app or what is said.", symbol: "lock")

        page.section("Away") { rows in
            rows.sentence([.text("Treat me as away after"),
                           minutes("away", values: Array(Settings.awayThresholdRange), current: settings.awayThresholdMinutes) { value in
                               update(handlers) { $0.awayThresholdMinutes = value }
                           },
                           .text("min without input")])
            rows.divider()
            rows.row("Time away counts",
                     description: "Coming back resets your timers, and a long enough absence counts as a break. You can undo it from the notification area.",
                     symbol: "figure.walk.departure")
        }
        page.footnote("Locking your \(BreakpointPlatform.computerName) or letting the display sleep counts as away straight away.")

        page.section("Always") { rows in
            rows.row("Breakpoint also waits while you type, drag or dictate, and for 1 minute after a pause ends.", symbol: "hourglass")
            rows.divider()
            rows.row("Quiet while you present or watch",
                     description: "While a display is mirrored or kept awake, only an agent run or a long command offers a break, and eye rests never start by themselves.",
                     symbol: "play.rectangle")
        }
    }

    // MARK: Wind-down

    /// Remind me to stop; "Stop at [23:00] on [Every day ⌄]" with day chips; Ask for longer holds
    /// and a still of the card it shows.
    static func windDown(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let settings = model.state.settings
        let enabled = settings.windDownEnabled
        page.section { rows in
            toggle(&rows, handlers, model, \.windDownEnabled, id: "windDownEnabled", title: "Remind me to stop",
                   description: "After your stop time, the next finished agent run shows a wrap-up card.", symbol: "moon")
        }

        page.section("When", enabled: enabled) { rows in
            let stop = settings.stopTime
            let time = TimeFormat.timeOfDay(stop.date(on: model.state.now))
            let stepperWidth = max(110, Canvas.measure(time, style: TextStyle(size: 13, weight: 600)).width + 64)
            let days = daysSummary(settings.stopDays)
            rows.sentence([
                .text("Stop at"),
                .control(id: "stopTime", width: stepperWidth) { canvas, controls, rect in
                    controls.stepper(canvas, id: "stopTime", at: PointF(x: rect.x, y: rect.y), value: time, width: rect.width,
                                     minus: { update(handlers) { $0.stopTime = shifted(stop, by: -15) } },
                                     plus: { update(handlers) { $0.stopTime = shifted(stop, by: 15) } })
                },
                .text("on"),
                .menu(id: "stopDays", title: days, items: [
                    ("Every day", settings.stopDays == .all, { update(handlers) { $0.stopDays = .all } }),
                    ("Weekdays", settings.stopDays == .weekdays, { update(handlers) { $0.stopDays = .weekdays } }),
                    ("Sunday to Thursday nights", settings.stopDays == sundayToThursday,
                     { update(handlers) { $0.stopDays = sundayToThursday } }),
                ]),
            ], disabled: !enabled)
            rows.divider()
            dayChips(&rows, settings.stopDays, handlers)
        }

        page.section("The card", enabled: enabled) { rows in
            toggle(&rows, handlers, model, \.escalatingHold, id: "escalatingHold", title: "Ask for longer holds",
                   description: "Each extra 15 minutes needs a longer press: 3, 6, then 10 seconds.", symbol: "hand.tap")
            rows.divider()
            rows.gap(12)
            windDownCardStill(&rows, model)
            rows.gap(12)
        }
        page.footnote("Wrap up writes a short “Where you left off” note you can copy, and pauses breaks until morning.")
    }

    static let sundayToThursday: Weekdays = [.sunday, .monday, .tuesday, .wednesday, .thursday]

    /// The stop time moved by whole quarters of an hour, wrapping round midnight.
    static func shifted(_ time: TimeOfDay, by minutes: Int) -> TimeOfDay {
        var total = time.minutesSinceMidnight
        if minutes > 0 {
            total = (total / 15 + 1) * 15
        } else {
            total = total % 15 == 0 ? total - 15 : (total / 15) * 15
        }
        total = (total + 24 * 60) % (24 * 60)
        return TimeOfDay(hour: total / 60, minute: total % 60)
    }

    /// Calendar weekday numbers in the user's week order (Monday first in most locales).
    static var weekOrder: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    /// "Every day", "Weekdays", "Weekends", "Sunday to Thursday" or the days listed ("Mon, Tue, Thu").
    static func daysSummary(_ days: Weekdays) -> String {
        if days == .all { return "Every day" }
        if days == .weekdays { return "Weekdays" }
        if days == [.saturday, .sunday] { return "Weekends" }
        if days == sundayToThursday { return "Sunday to Thursday" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekOrder.filter { days.contains(calendarWeekday: $0) }.map { symbols[$0 - 1] }.joined(separator: ", ")
    }

    /// A day toggle each: filled with its letter when on, outlined when off (shape, not only colour).
    static func dayChips(_ page: inout SettingsPage, _ days: Weekdays, _ handlers: SettingsHandlers) {
        page.gap(8)
        if let canvas = page.canvas {
            let look = page.look
            let letters = Calendar.current.veryShortWeekdaySymbols
            for (index, weekday) in weekOrder.enumerated() {
                let rect = RectF(x: page.x + Float(index) * 34, y: page.y, width: 28, height: 28)
                let id = "day.\(weekday)"
                let on = days.contains(calendarWeekday: weekday)
                guard let controls = page.live(rect) else { continue }
                let centre = PointF(x: rect.midX, y: rect.midY)
                if on {
                    canvas.circle(centre, radius: 14, controls.isHovered(id) ? look.accent.mixed(with: .white, 0.12) : look.accent)
                } else {
                    if controls.isHovered(id) { canvas.circle(centre, radius: 14, look.fill) }
                    canvas.ring(centre, radius: 13.5, width: 1, look.text.opacity(0.25))
                }
                canvas.text(letters[weekday - 1], in: rect, style: TextStyle(size: 12, weight: 600, align: .center),
                            on ? look.onAccent : look.secondary)
                controls.region(id, rect, focusable: true) {
                    handlers.actions.updateSettings { settings in
                        let day = Weekdays(calendarWeekday: weekday)
                        if settings.stopDays.contains(day) {
                            // Keep at least one day.
                            if settings.stopDays.subtracting(day).isEmpty { return }
                            settings.stopDays.remove(day)
                        } else {
                            settings.stopDays.insert(day)
                        }
                    }
                }
                SettingsDraw.focusRing(canvas, controls, id: id, rect, radius: 14)
                page.record(id, rect)
            }
        }
        page.gap(28 + 8)
    }

    /// A still of the real wind-down card as it would appear tonight, at 80% on a dark backdrop.
    static func windDownCardStill(_ page: inout SettingsPage, _ model: SettingsModel) {
        let height: Float = 112 + 32
        if let canvas = page.canvas {
            let backdrop = RectF(x: page.x, y: page.y, width: page.width, height: height)
            canvas.gradient(backdrop, radius: 8, from: Colour(hex: 0x2A3040), to: Colour(hex: 0x141821), angle: 135)
            let stop = model.state.settings.stopTime
            let at = Calendar.current.date(byAdding: .minute, value: 20, to: stop.date(on: model.state.now)) ?? model.state.now
            let scale: Float = 0.8
            let cardWidth = Theme.Size.windDownWidth
            let cardHeight = SettingsWindDownStill.height(stop: stop, at: at)
            let origin = PointF(x: backdrop.midX - cardWidth * scale / 2, y: backdrop.midY - cardHeight * scale / 2)
            canvas.clipped(to: backdrop, radius: 8) {
                canvas.transformed(dx: origin.x, dy: origin.y, scale: scale) {
                    SettingsWindDownStill.draw(canvas, stop: stop, at: at)
                }
            }
        }
        page.gap(height)
    }
}

/// The wind-down card's asking phase, drawn as the pop-up draws it (SPEC §3.6), at its own size
/// with its origin at 0, 0: title, body, "15 more minutes · Hold 3 s" and Wrap up.
@MainActor
enum SettingsWindDownStill {
    static let padding = Theme.Size.windDownPadding

    static func height(stop: TimeOfDay, at: Date) -> Float {
        let inner = Theme.Size.windDownWidth - 2 * padding
        let title = Canvas.measure(Copy.windDownTitle(now: at), style: Theme.Typography.windDownTitle).height
        let body = Canvas.measure(Copy.windDownBody(stopTime: stop, on: at), style: Theme.Typography.bodyWrapped, width: inner).height
        return padding + title + 4 + body + Theme.Spacing.m + Theme.Size.smallButtonHeight + padding
    }

    static func draw(_ canvas: Canvas, stop: TimeOfDay, at: Date) {
        let width = Theme.Size.windDownWidth
        let card = RectF(x: 0, y: 0, width: width, height: height(stop: stop, at: at))
        canvas.shadow(card, radius: Theme.Radius.card, blur: 12, offset: PointF(x: 0, y: 4), Colour.black.opacity(0.3))
        canvas.fill(card, radius: Theme.Radius.card, Theme.Palette.glassApproximation)
        canvas.stroke(card.insetBy(0.5, 0.5), radius: Theme.Radius.card, width: 1, Colour.white.opacity(0.14))
        let inner = width - 2 * padding
        var y = padding
        y += canvas.text(Copy.windDownTitle(now: at), at: PointF(x: padding, y: y), style: Theme.Typography.windDownTitle, .white).height + 4
        y += canvas.text(Copy.windDownBody(stopTime: stop, on: at), at: PointF(x: padding, y: y), width: inner,
                         style: Theme.Typography.bodyWrapped, Theme.Palette.white(.body)).height
        y += Theme.Spacing.m
        let buttonHeight = Theme.Size.smallButtonHeight
        let style = Theme.Typography.smallButton
        let wrapWidth = Canvas.measure("Wrap up", style: style).width + 2 * Theme.Size.buttonPadding
        let wrap = RectF(x: width - padding - wrapWidth, y: y, width: wrapWidth, height: buttonHeight)
        canvas.fill(wrap, radius: buttonHeight / 2, Theme.Palette.mint)
        canvas.text("Wrap up", in: wrap, style: style, Theme.Palette.onMint)
        let holdTitle = "15 more minutes"
        let hold = Copy.windDownHold(3)
        let holdStyle = TextStyle(size: 11, weight: 500)
        let titleWidth = Canvas.measure(holdTitle, style: TextStyle(size: style.size, weight: style.weight)).width
        let holdWidth = Canvas.measure(hold, style: holdStyle).width
        let extendWidth = titleWidth + 8 + holdWidth + 2 * Theme.Size.buttonPadding
        let extend = RectF(x: wrap.x - Theme.Size.buttonGap - extendWidth, y: y, width: extendWidth, height: buttonHeight)
        canvas.fill(extend, radius: buttonHeight / 2, Colour.white.opacity(0.12))
        let leading = TextStyle(size: style.size, weight: style.weight)
        let size = Canvas.measure(holdTitle, style: leading)
        canvas.text(holdTitle, at: PointF(x: extend.x + Theme.Size.buttonPadding, y: extend.midY - size.height / 2), style: leading,
                    Theme.Palette.white(.title))
        let holdSize = Canvas.measure(hold, style: holdStyle)
        canvas.text(hold, at: PointF(x: extend.x + Theme.Size.buttonPadding + titleWidth + 8, y: extend.midY - holdSize.height / 2),
                    style: holdStyle, Theme.Palette.white(.secondary))
    }
}

/// Where breaks would fall in two hours of steady work at a cadence, by the engine's rules: a due
/// stretch wins over a due eye rest, a stretch resets both timers, an eye rest screen time only
/// (as `BreakSchedule` on the Mac).
struct SettingsSchedule {
    struct Mark {
        let minute: Int
        let isMove: Bool
    }

    let marks: [Mark]

    init(cadence: Cadence, span: Int = 120) {
        var marks: [Mark] = []
        var screen = 0
        var still = 0
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
        self.marks = marks
    }
}
