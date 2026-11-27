import BreakpointCore
import BreakpointRuntime
import Foundation

// The Integrations, General, Privacy and About panes and the two options sheets (SPEC §3.9), as
// the macOS panes in Sources/BreakpointKit/Settings, in Windows words.

extension SettingsPanes {
    // MARK: Integrations

    static let anyToolCommand = "breakpoint emit agentStarted --source my-tool --session ID"

    /// One row per tool (icon, name, status pill, Install / Remove), the Codex folder override
    /// while Codex is not found, and the "Use with any tool" one-liner with Copy.
    static func integrations(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let rows = model.state.integrations.filter { IntegrationID.settingsRows.contains($0.id) }
        page.paragraph("Breakpoint hears from your tools through small hooks in their settings files. Nothing is written until you press Install, and Remove takes out only what Breakpoint added.")
        page.gap(SettingsMetrics.sectionGap)
        page.section("Tools") { list in
            for (index, row) in rows.enumerated() {
                if index > 0 { list.divider() }
                integrationRow(&list, row, model, handlers)
                if row.id == .codex, row.status == .notFound {
                    list.divider()
                    codexFolderRow(&list, model, handlers)
                }
            }
        }
        page.section("Use with any tool") { list in
            anyToolRow(&list, model, handlers)
        }
        page.footnote("Send agentFinished when it’s done. The command lives at ~\\.breakpoint\\bin\\breakpoint.exe once any tool is installed.")
    }

    /// The status pill's words (SPEC §5.6).
    static func statusText(_ status: IntegrationStatus, now: Date) -> String {
        switch status {
        case .notFound: return "Not found"
        case .notInstalled: return "Not installed"
        case .connected(.none): return "Connected"
        case .connected(let date?):
            let ago = now.timeIntervalSince(date)
            return ago < 60 ? "Connected · last event just now" : "Connected · last event \(DurationFormat.minutes(ago)) ago"
        case .problem: return "Can’t read its settings"
        }
    }

    /// The pill's words for a row: the problem states say which problem it is.
    static func statusText(_ row: IntegrationRowState, now: Date) -> String {
        switch row.installState {
        case .outdated: return "Needs an update"
        case .modified: return "Edited outside Breakpoint"
        case .installed where !row.status.isInstalled: return "Needs attention"
        default: return statusText(row.status, now: now)
        }
    }

    /// The button that installs again over Breakpoint's own entries.
    static func reinstallLabel(_ state: IntegrationInstallState) -> String {
        switch state {
        case .outdated: return "Update"
        case .modified: return "Restore"
        default: return "Install again"
        }
    }

    /// What Install does, in one line, with this PC's paths.
    static func installLine(_ id: IntegrationID) -> String {
        switch id {
        case .claudeCode: return "Adds hooks to ~\\.claude\\settings.json."
        case .cursor: return "Adds hooks to ~\\.cursor\\hooks.json."
        case .codex: return "Adds hooks to ~\\.codex\\hooks.json. Codex asks you to trust them once, in /hooks."
        case .codexNotify: return "Adds one notify line to ~\\.codex\\config.toml."
        case .copilot: return "Adds one file, ~\\.copilot\\hooks\\breakpoint.json."
        case .gemini: return "Adds hooks to ~\\.gemini\\settings.json."
        case .shell: return "Offers breaks while long commands run. Adds a small block to your PowerShell profile."
        }
    }

    static func integrationDescription(_ row: IntegrationRowState) -> String {
        switch row.status {
        case .notFound:
            return row.id == .shell ? installLine(row.id)
                : "Not found on this \(BreakpointPlatform.computerName). Install \(row.displayName) first, then come back."
        case .problem(let reason):
            return reason
        case .connected(.none) where row.id == .codex:
            return "One more step: in Codex, open /hooks and trust Breakpoint’s entries."
        default:
            return installLine(row.id)
        }
    }

    static func integrationTrailing(_ row: IntegrationRowState, _ model: SettingsModel, _ handlers: SettingsHandlers) -> [SettingsTrailing] {
        let key = row.id.rawValue
        if row.isBusy { return [.spinner(phase: spinnerPhase(model))] }
        switch row.status {
        case .notInstalled:
            return [.button("install.\(key)", "Install", role: .primary) { handlers.actions.install(row.id) }]
        case .problem where row.canRemove:
            return [.button("remove.\(key)", "Remove") { handlers.actions.uninstall(row.id) },
                    .button("install.\(key)", reinstallLabel(row.installState), role: .primary) { handlers.actions.install(row.id) }]
        case .problem:
            return [.button("install.\(key)", "Try again") { handlers.actions.install(row.id) }]
        case .connected:
            return [.button("remove.\(key)", "Remove") { handlers.actions.uninstall(row.id) }]
        case .notFound:
            return []
        }
    }

    static func spinnerPhase(_ model: SettingsModel) -> Double {
        model.ui.spins ? Date().timeIntervalSinceReferenceDate * 1.2 : 0.1
    }

    /// Icon, name and pill, what Install does or what is wrong, the install's notes, its error,
    /// Codex's Options…; the buttons on the right.
    static func integrationRow(_ page: inout SettingsPage, _ row: IntegrationRowState, _ model: SettingsModel,
                               _ handlers: SettingsHandlers) {
        let look = page.look
        let trailing = integrationTrailing(row, model, handlers)
        let trailingWidth = trailing.reduce(Float(0)) { $0 + $1.width } + Float(max(0, trailing.count - 1)) * 8
        let textX = page.x + SettingsMetrics.rowIcon + 10
        let textWidth = page.width - SettingsMetrics.rowIcon - 10 - (trailing.isEmpty ? 0 : trailingWidth + 12)
        let small = Theme.Typography.rowDescription
        let description = integrationDescription(row)
        let notes = row.id == .codex && row.status.isInstalled ? row.notes.filter { !$0.contains("/hooks") } : row.notes
        let hasOptions = row.id == .codex
        var height: Float = 20 + 4 + Canvas.measure(description, style: small, width: textWidth).height
        for note in notes { height += 4 + Canvas.measure(note, style: small, width: textWidth - 16).height }
        if let error = row.errorMessage { height += 4 + Canvas.measure(error, style: small, width: textWidth - 16).height }
        if hasOptions { height += 8 + SettingsMetrics.smallButtonHeight }
        let rowHeight = max(44, height + 20)
        if let canvas = page.canvas {
            let rowRect = RectF(x: page.x, y: page.y, width: page.width, height: rowHeight)
            let controls = page.live(rowRect)
            canvas.withOpacity(row.status == .notFound ? 0.75 : 1) {
                var y = page.y + 10
                SourceTile.draw(canvas, RectF(x: page.x, y: y + 1, width: SettingsMetrics.rowIcon, height: SettingsMetrics.rowIcon),
                                symbol: MenuBarGlyphs.integrationSymbol(row.id), look: look)
                let nameSize = Canvas.measure(row.displayName, style: Theme.Typography.row)
                canvas.text(row.displayName, at: PointF(x: textX, y: y + 10 - nameSize.height / 2), style: Theme.Typography.row, look.text)
                let kind: SettingsDraw.PillKind
                switch row.status {
                case .connected: kind = .connected
                case .problem: kind = .problem
                default: kind = .plain
                }
                SettingsDraw.pill(canvas, at: PointF(x: textX + nameSize.width + 8, y: y), text: statusText(row, now: model.state.now),
                                  kind: kind, flashing: model.ui.flashing.contains(row.id), look: look)
                y += 24
                y += canvas.text(description, at: PointF(x: textX, y: y), width: textWidth, style: small, look.secondary).height
                for note in notes {
                    y += 4
                    SettingsGlyph.draw("info.circle", on: canvas, centre: PointF(x: textX + 5, y: y + 7), size: 10, look.secondary)
                    y += canvas.text(note, at: PointF(x: textX + 16, y: y), width: textWidth - 16, style: small, look.secondary).height
                }
                if let error = row.errorMessage {
                    y += 4
                    SettingsDraw.warning(canvas, centre: PointF(x: textX + 5, y: y + 7), size: 10)
                    y += canvas.text(error, at: PointF(x: textX + 16, y: y), width: textWidth - 16, style: small,
                                     look.dark ? SettingsDraw.orange : SettingsDraw.orangeLight).height
                }
                if hasOptions, let controls {
                    y += 8
                    let width = Canvas.measure("Options…", style: Theme.Typography.smallButton).width + 28
                    let rect = RectF(x: textX, y: y, width: width, height: SettingsMetrics.smallButtonHeight)
                    controls.button(canvas, id: "codex.options", rect, "Options…") {
                        handlers.openSheet(.codexOptions)
                    }
                    page.record("codex.options", rect)
                }
            }
            if let controls {
                var right = page.x + page.width
                for item in trailing.reversed() {
                    let rect = RectF(x: right - item.width, y: page.y + 10 + 10 - item.height / 2, width: item.width, height: item.height)
                    item.draw(canvas, controls, rect)
                    if let id = item.id { page.record(id, rect) }
                    right -= item.width + 8
                }
            }
        }
        page.gap(rowHeight)
    }

    /// The Codex folder override, shown only while Codex is not found in its default folder.
    static func codexFolderRow(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let ui = model.ui
        let text = ui.codexDraft ?? model.state.settings.codexHome ?? ""
        let focused = ui.codexDraft != nil
        page.row("Codex folder", description: "If Codex keeps its settings somewhere other than ~\\.codex, choose that folder.",
                 symbol: "folder", trailing: [
                     .custom(width: 180, height: SettingsMetrics.smallButtonHeight, id: SettingsUI.codexFieldID) { canvas, controls, rect in
                         SettingsTextField.draw(canvas, controls, id: SettingsUI.codexFieldID, rect, text: text, placeholder: "~\\.codex",
                                                editing: focused, action: handlers.focusCodexField)
                     },
                     .button("codexFolder.choose", "Choose…") { handlers.chooseCodexFolder() },
                 ])
    }

    /// The one-liner in a quiet monospaced box, and Copy (Copied for a moment).
    static func anyToolRow(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let height: Float = 28
        page.gap(8)
        if let canvas = page.canvas {
            let look = page.look
            let copied = model.ui.copiedUntil.map { $0 > Date() } ?? false
            let title = copied ? "Copied" : "Copy"
            let buttonWidth = max(76, Canvas.measure(title, style: Theme.Typography.smallButton).width + 28)
            let box = RectF(x: page.x, y: page.y, width: page.width - buttonWidth - 10, height: height)
            canvas.fill(box, radius: 6, look.text.opacity(look.dark ? 0.08 : 0.05))
            canvas.clipped(to: box.insetBy(10, 0), radius: 0) {
                canvas.text(anyToolCommand, in: box.insetBy(10, 0), style: TextStyle(size: 12, family: "Cascadia Mono"), look.text)
            }
            let button = RectF(x: box.maxX + 10, y: page.y + 1, width: buttonWidth, height: SettingsMetrics.smallButtonHeight)
            if let controls = page.live(button) {
                controls.button(canvas, id: "copyCommand", button, title) { handlers.copyCommand() }
                page.record("copyCommand", button)
            }
        }
        page.gap(height + 8)
    }

    // MARK: General

    /// Getting started, open at login, the tray tooltip text, pop-up position thumbnails, nudge
    /// hotkeys, the flyout shortcut recorder, chimes with ▶ and a volume slider.
    static func general(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let settings = model.state.settings
        page.section("Getting started") { rows in
            rows.row("The one-minute tour", description: "Rehearses one break with sample data, on the real screens. Nothing is recorded.",
                     symbol: "figure.wave", trailing: [.button("tour", "Take the tour") { handlers.actions.replayTour() }])
            rows.divider()
            toggle(&rows, handlers, model, \.showHints, id: "showHints", title: "Show hints",
                   description: "The first time a pop-up or the break screen appears, one short line says how to use it. Each shows once.",
                   symbol: "lightbulb")
        }

        page.section("Startup") { rows in
            toggle(&rows, handlers, model, \.launchAtLogin, id: "launchAtLogin", title: "Open at login",
                   description: loginDescription(model.ui.login), symbol: "power")
        }

        page.section("Notification area") { rows in
            let titles: [(MenuBarTextMode, String)] = [(.nothing, "nothing"), (.timeToNextBreak, "time to next break"),
                                                       (.agentState, "agent state")]
            let current = titles.first { $0.0 == settings.menuBarText }?.1 ?? "nothing"
            let parts: [SentencePart] = [
                .text("Show"),
                .menu(id: "menuBarText", title: current, items: titles.map { mode, title in
                    (title, mode == settings.menuBarText, { update(handlers) { $0.menuBarText = mode } })
                }),
                .text("in the icon’s tooltip"),
            ]
            let sentenceWidth = parts.reduce(Float(0)) { $0 + $1.width + 6 }
            let top = rows.y
            rows.sentence(parts)
            let previewX = rows.x + sentenceWidth + 12
            if let canvas = rows.canvas, rows.x + rows.width - previewX > 120 {
                tooltipPreview(canvas, RectF(x: previewX, y: top + 7, width: rows.x + rows.width - previewX, height: 26), model)
            }
        }
        page.footnote("While breaks are paused it reads “Paused”, whatever you choose.")

        page.sectionHeader("Pop-ups")
        positionCards(&page, model, handlers)
        page.gap(SettingsMetrics.sectionGap)
        page.footnote("Pop-ups appear on the display your pointer is on.")

        page.section("Keyboard") { rows in
            toggle(&rows, handlers, model, \.nudgeHotkeys, id: "nudgeHotkeys", title: "Hotkeys for the nudge",
                   description: "\(HotKeys.display(.nudgeStart)) starts the offered break. \(HotKeys.display(.nudgeDismiss)) dismisses it, or a resume card.",
                   symbol: "keyboard")
            rows.divider()
            rows.row("Shortcut to open Breakpoint",
                     description: "Opens and closes Breakpoint’s window in the notification area from anywhere.", symbol: "command",
                     trailing: recorderTrailing(model, handlers))
        }

        page.section("Sounds") { rows in
            let sounds: [(String, String, String, SoundID, WritableKeyPath<Settings, Bool>, String)] = [
                ("chimeNeedsYou", "Chime when an agent needs you during a break",
                 "A soft two-note chime, once. Never while a microphone or camera is on.", .needsYouChime, \.chimeNeedsYou, "bell"),
                ("chimeBreakEnd", "Chime when a break ends", "Plays as a completed break closes.", .breakEndChime, \.chimeBreakEnd,
                 "bell.and.waves.left.and.right"),
                ("stepTick", "Tick at each new stretch step", "A short, quiet tone, so you can follow a stretch without watching.",
                 .stepTick, \.stepTick, "metronome"),
            ]
            for (id, title, description, sound, keyPath, symbol) in sounds {
                rows.row(title, description: description, symbol: symbol, trailing: [
                    .play("\(id).play") { handlers.actions.previewSound(sound) },
                    .toggle(id, isOn: settings[keyPath: keyPath]) { on in update(handlers) { $0[keyPath: keyPath] = on } },
                ])
                rows.divider()
            }
            volumeRow(&rows, model, handlers)
        }
    }

    static func loginDescription(_ availability: LoginItemAvailability) -> String {
        let base = "Breakpoint starts quietly in the notification area."
        switch availability {
        case .available: return base
        case .developmentRun: return base + " Development runs leave your startup apps alone."
        case .outsideApplications: return base + " This works once Breakpoint is installed in your Programs folder."
        case .notFromApp: return base + " This works once Breakpoint runs from its installed copy."
        }
    }

    /// What the tray icon's tooltip would say with the chosen text, from the current state.
    static func tooltipSample(_ state: AppState) -> String {
        var text: String?
        switch state.settings.menuBarText {
        case .nothing: text = nil
        case .timeToNextBreak: text = Copy.menuBarCountdown(state.status.nextBreakIn)
        case .agentState:
            let working = state.sessions.first { $0.state == .working }
            text = Copy.menuBarAgent(working?.displayName ?? "Claude", elapsed: working?.runElapsed(at: state.now) ?? 180)
        }
        if state.status.isPaused { text = "Paused" }
        let tooltip = state.menuBar.tooltip
        guard let text, !text.isEmpty, !tooltip.contains(text) else { return tooltip }
        return "\(tooltip) · \(text)"
    }

    /// A small tooltip, as Windows draws one over the notification area, beside the mark.
    static func tooltipPreview(_ canvas: Canvas, _ rect: RectF, _ model: SettingsModel) {
        let look = model.look
        let sample = tooltipSample(model.state)
        let style = TextStyle(size: 12)
        let width = min(rect.width - 26, Canvas.measure(sample, style: style).width + 16)
        let markRect = RectF(x: rect.maxX - 18, y: rect.midY - 6, width: 18, height: 12)
        let bubble = RectF(x: markRect.x - 8 - width, y: rect.y, width: width, height: rect.height)
        canvas.fill(bubble, radius: 4, look.dark ? Colour(hex: 0x2B2B2B) : Colour.white)
        canvas.stroke(bubble.insetBy(0.5, 0.5), radius: 4, width: 1, look.dark ? Colour.white.opacity(0.1) : Colour.black.opacity(0.12))
        canvas.clipped(to: bubble.insetBy(8, 0), radius: 0) {
            canvas.text(sample, in: bubble.insetBy(8, 0), style: style, look.text)
        }
        BrandMark.drawMark(in: markRect, on: canvas, tag: look.text.opacity(0.8), eyes: look.dark ? Colour(hex: 0x272727) : Colour(hex: 0xF7F7F7))
    }

    static func positionTitle(_ position: PopupPosition) -> String {
        switch position {
        case .topLeft: return "Top left"
        case .topCentre: return "Top centre"
        case .topRight: return "Top right"
        }
    }

    static func positionDetail(_ position: PopupPosition) -> String {
        switch position {
        case .topLeft: return "Near the left edge"
        case .topCentre: return "The default"
        case .topRight: return "Near the right edge"
        }
    }

    /// Three cards, each a miniature desktop showing where pop-ups land.
    static func positionCards(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let positions = PopupPosition.allCases
        let gap: Float = 12
        let width = ((page.width - gap * Float(positions.count - 1)) / Float(positions.count)).rounded(.down)
        let contentHeight = ((width - 24) * 10 / 16).rounded()
        let height = positions.map {
            SettingsPage.presetCardHeight(width: width, title: positionTitle($0), detail: positionDetail($0), contentHeight: contentHeight)
        }.max() ?? 140
        let look = page.look
        let selected = model.state.settings.popupPosition
        for (index, position) in positions.enumerated() {
            let rect = RectF(x: page.x + Float(index) * (width + gap), y: page.y, width: width, height: height)
            page.presetCard("position.\(position.rawValue)", rect, title: positionTitle(position), detail: positionDetail(position),
                            selected: selected == position, contentHeight: contentHeight,
                            action: { update(handlers) { $0.popupPosition = position } }) { canvas, area in
                positionThumbnail(canvas, area, position: position, selected: selected == position, look: look)
            }
        }
        page.gap(height)
    }

    /// A miniature Windows desktop: wallpaper, a window for scale, the taskbar (centred icons, the
    /// notification area with Breakpoint's mark), and a small nudge card at the chosen position.
    static func positionThumbnail(_ canvas: Canvas, _ rect: RectF, position: PopupPosition, selected: Bool, look: Look) {
        let w = rect.width, h = rect.height
        let dark = look.dark
        canvas.clipped(to: rect, radius: 6) {
            canvas.gradient(rect, radius: 6, from: dark ? Colour(hex: 0x23443F) : Colour(hex: 0xCDEDE4),
                            to: dark ? Colour(hex: 0x272C52) : Colour(hex: 0xD8DCF6), angle: 135)
            // A window, for scale.
            let window = RectF(x: rect.x + w * 0.24, y: rect.y + h * 0.3, width: w * 0.52, height: h * 0.46)
            canvas.fill(window, radius: h * 0.04, Colour.white.opacity(dark ? 0.10 : 0.55))
            canvas.fill(RectF(x: window.x, y: window.y, width: window.width, height: h * 0.06), radius: h * 0.03,
                        Colour.white.opacity(dark ? 0.08 : 0.5))
            // The taskbar.
            let bar = max(5, h * 0.1)
            let taskbar = RectF(x: rect.x, y: rect.maxY - bar, width: w, height: bar)
            canvas.fill(taskbar, dark ? Colour.black.opacity(0.4) : Colour.white.opacity(0.65))
            let ink = dark ? Colour.white.opacity(0.55) : Colour.black.opacity(0.45)
            let icon = bar * 0.45
            for i in 0..<4 {
                let x = rect.midX + (Float(i) - 1.5) * icon * 1.8 - icon / 2
                canvas.fill(RectF(x: x, y: taskbar.midY - icon / 2, width: icon, height: icon), radius: icon * 0.25, ink)
            }
            let markWidth = bar * 0.8
            BrandMark.drawMark(in: RectF(x: taskbar.maxX - w * 0.2, y: taskbar.midY - markWidth * 0.32, width: markWidth,
                                         height: markWidth * 0.64), on: canvas, tag: ink, eyes: dark ? Colour(hex: 0x1F2830) : Colour(hex: 0xEDF3F2))
            canvas.fill(RectF(x: taskbar.maxX - w * 0.12, y: taskbar.midY - bar * 0.14, width: w * 0.08, height: bar * 0.28),
                        radius: bar * 0.14, ink)
            // The nudge.
            let card = SizeF(width: w * 0.36, height: h * 0.2)
            let inset = w * 0.05
            let x: Float
            switch position {
            case .topLeft: x = rect.x + inset
            case .topCentre: x = rect.x + (w - card.width) / 2
            case .topRight: x = rect.maxX - inset - card.width
            }
            canvas.withOpacity(selected ? 1 : 0.8) {
                miniNudge(canvas, RectF(x: x, y: rect.y + h * 0.05, width: card.width, height: card.height))
            }
        }
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: 6, width: 1, look.text.opacity(0.08))
    }

    /// The nudge in miniature: dark glass, gradient badge, a title and a subtitle line, two buttons.
    static func miniNudge(_ canvas: Canvas, _ rect: RectF) {
        let h = rect.height, w = rect.width
        canvas.shadow(rect, radius: h * 0.3, blur: 3, offset: PointF(x: 0, y: 1), Colour.black.opacity(0.25))
        canvas.fill(rect, radius: h * 0.3, Theme.Palette.glassApproximation)
        canvas.stroke(rect.insetBy(0.25, 0.25), radius: h * 0.3, width: 0.5, Colour.white.opacity(0.14))
        let pad = h * 0.13
        let badge = h * 0.42
        canvas.gradient(RectF(x: rect.x + pad, y: rect.y + pad, width: badge, height: badge), radius: badge / 2,
                        from: Theme.Palette.mint, to: Theme.Palette.indigo, angle: 45)
        let tx = rect.x + pad + badge + w * 0.05
        let ty = rect.y + pad + h * 0.04
        canvas.fill(RectF(x: tx, y: ty, width: w * 0.38, height: h * 0.1), radius: h * 0.05, Colour.white.opacity(0.9))
        canvas.fill(RectF(x: tx, y: ty + h * 0.2, width: w * 0.5, height: h * 0.08), radius: h * 0.04, Colour.white.opacity(0.45))
        canvas.fill(RectF(x: tx, y: ty + h * 0.4, width: w * 0.17, height: h * 0.16), radius: h * 0.08, Colour.white.opacity(0.18))
        canvas.stroke(RectF(x: tx + w * 0.2, y: ty + h * 0.4, width: w * 0.2, height: h * 0.16), radius: h * 0.08, width: 0.5,
                      Colour.white.opacity(0.25))
    }

    /// The shortcut recorder (Record shortcut / the combination / "Type a shortcut…") and ×.
    static func recorderTrailing(_ model: SettingsModel, _ handlers: SettingsHandlers) -> [SettingsTrailing] {
        let ui = model.ui
        let combo = model.state.settings.popoverHotkey
        let id = SettingsUI.recorderID
        let title: String
        if ui.recording {
            title = ui.recorderHint ?? "Type a shortcut…"
        } else if let combo {
            title = HotKeys.display(combo)
        } else {
            title = "Record shortcut"
        }
        let width = max(130, Canvas.measure(title, style: Theme.Typography.smallButton).width + 28)
        var items: [SettingsTrailing] = [
            .custom(width: width, height: SettingsMetrics.smallButtonHeight, id: id) { canvas, controls, rect in
                controls.button(canvas, id: id, rect, title, role: ui.recording ? .quiet : .secondary) { handlers.startRecording() }
                if ui.recording {
                    canvas.stroke(rect.insetBy(0.5, 0.5), radius: rect.height / 2, width: 1.5, controls.look.accent)
                }
            },
        ]
        if combo != nil, !ui.recording {
            items.append(.custom(width: 20, height: 20, id: "popoverShortcut.clear") { canvas, controls, rect in
                let look = controls.look
                let clearID = "popoverShortcut.clear"
                let centre = PointF(x: rect.midX, y: rect.midY)
                canvas.circle(centre, radius: 8, controls.isHovered(clearID) ? look.text.opacity(0.5) : look.text.opacity(0.32))
                let d: Float = 3
                let ink = look.dark ? Colour.black.opacity(0.8) : Colour.white
                canvas.line(PointF(x: centre.x - d, y: centre.y - d), PointF(x: centre.x + d, y: centre.y + d), width: 1.4, ink)
                canvas.line(PointF(x: centre.x + d, y: centre.y - d), PointF(x: centre.x - d, y: centre.y + d), width: 1.4, ink)
                controls.region(clearID, rect.insetBy(-3, -3), focusable: true) { update(handlers) { $0.popoverHotkey = nil } }
                SettingsDraw.focusRing(canvas, controls, id: clearID, rect, radius: 10)
            })
        }
        return items
    }

    /// Volume, with the slider between a quiet and a loud speaker and the percentage.
    static func volumeRow(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let volume = model.ui.volumeDraft ?? model.state.settings.volume
        let percent = Int((volume * 100).rounded())
        let sliderWidth: Float = 180
        page.row("Volume", trailing: [
            .custom(width: 16, height: 16) { canvas, controls, rect in
                SettingsGlyph.draw("speaker.fill", on: canvas, centre: PointF(x: rect.midX, y: rect.midY), size: 11, controls.look.secondary)
            },
            .custom(width: sliderWidth, height: 20, id: "volume") { canvas, controls, rect in
                controls.slider(canvas, id: "volume", rect, value: volume, range: 0...1, step: 0.01) { value in
                    model.ui.volumeDraft = value
                    // Dragging commits on release (the controller); the arrow keys commit at once.
                    if controls.pressed != "volume" {
                        update(handlers) { $0.volume = value }
                        model.ui.volumeDraft = nil
                        handlers.actions.previewSound(.needsYouChime)
                    }
                    handlers.changed()
                }
            },
            .custom(width: 16, height: 16) { canvas, controls, rect in
                SettingsGlyph.draw("speaker.wave.3.fill", on: canvas, centre: PointF(x: rect.midX, y: rect.midY), size: 13,
                                   controls.look.secondary)
            },
            .custom(width: 36, height: 16) { canvas, controls, rect in
                canvas.text("\(percent)%", at: PointF(x: rect.x, y: rect.y), width: rect.width,
                            style: TextStyle(size: 12, weight: 500, monospacedDigits: true, align: .trailing), controls.look.secondary)
            },
        ])
    }

    // MARK: Privacy

    static let reads: [(String, String)] = [
        ("keyboard", "How long since your last key press, click or scroll. Never which keys."),
        ("cursorarrow.motionlines", "Whether a mouse button is held, and where the pointer is, to place pop-ups."),
        ("mic", "Whether any microphone or camera is in use. Never which app, never the audio."),
        ("lock", "Screen lock, display sleep and the screen saver."),
        ("tv", "Whether something is keeping the display awake, such as a video, and whether a display is mirrored. No app names."),
        ("point.3.connected.trianglepath.dotted", "Events from tools you connect: what happened and why, the project folder and the snippets above."),
    ]

    static let neverReads: [(String, String)] = [
        ("rectangle.dashed", "Your screen: no screenshots, no recording."),
        ("text.cursor", "What you type, your code, or window titles."),
        ("square.grid.2x2", "Which apps or websites you use."),
        ("network.slash", "The network, except for updates (About): a daily version check that sends nothing about you, and the new version when you install it."),
    ]

    /// "No permissions needed." first, then Keep prompt snippets, what Breakpoint reads and never
    /// reads, where the data lives, Export history · Delete all data.
    static func privacy(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let look = page.look
        let headline = "No permissions needed."
        let detail = "Breakpoint installs no keyboard or mouse hook, and never asks for administrator, camera, microphone, location or notification access."
        let textWidth = page.width - 28 - 28 - 14
        let headlineStyle = TextStyle(size: 15, weight: 600)
        let detailHeight = Canvas.measure(detail, style: Theme.Typography.rowDescription, width: textWidth).height
        let textHeight = Canvas.measure(headline, style: headlineStyle).height + 3 + detailHeight
        let boxHeight = max(28, textHeight) + 28
        if let canvas = page.canvas {
            let box = RectF(x: page.x, y: page.y, width: page.width, height: boxHeight)
            canvas.fill(box, radius: Theme.Radius.settingsSection, look.accent.opacity(look.dark ? 0.12 : 0.08))
            SettingsGlyph.draw("checkmark.shield.fill", on: canvas, centre: PointF(x: box.x + 14 + 14, y: box.midY), size: 26, look.accent)
            var y = box.midY - textHeight / 2
            y += canvas.text(headline, at: PointF(x: box.x + 56, y: y), style: headlineStyle, look.text).height + 3
            canvas.text(detail, at: PointF(x: box.x + 56, y: y), width: textWidth, style: Theme.Typography.rowDescription, look.secondary)
        }
        page.gap(boxHeight + SettingsMetrics.sectionGap)

        page.section("Stored on this \(BreakpointPlatform.computerName)") { rows in
            toggle(&rows, handlers, model, \.storePromptSnippets, id: "storePromptSnippets", title: "Keep prompt snippets",
                   description: "The first line of your prompt and of the agent's last reply, and the command it asks to run, label sessions and resume cards. Secrets are masked.",
                   symbol: "text.quote")
        }
        for (title, lines, positive) in [("What Breakpoint reads", reads, true), ("What it never reads", neverReads, false)] {
            page.section(title) { rows in
                for (index, line) in lines.enumerated() {
                    if index > 0 { rows.divider() }
                    rows.row(line.1, symbol: line.0, trailing: [
                        .custom(width: 14, height: 14) { canvas, controls, rect in
                            SettingsGlyph.draw(positive ? "checkmark" : "xmark", on: canvas, centre: PointF(x: rect.midX, y: rect.midY),
                                               size: 11, controls.look.secondary)
                        },
                    ])
                }
            }
        }
        page.section("Your data") { rows in
            rows.row("Everything stays in your AppData folder",
                     description: "\(BreakpointPlatform.dataFolderDisplayName), plus the command-line copy in ~\\.breakpoint.",
                     symbol: "folder", trailing: [.button("revealData", "Show in File Explorer") { handlers.revealData() }])
            rows.divider()
            rows.row("Export history", description: "Saves your break history as a JSON file.", symbol: "square.and.arrow.up",
                     trailing: [.button("exportHistory", "Export…") { handlers.actions.exportHistory() }])
            rows.divider()
            rows.row("Delete all data",
                     description: "Removes your break history and agent run estimates. Settings, connected tools and their config backups stay. Asks first.",
                     symbol: "trash", trailing: [.button("deleteAllData", "Delete…", role: .destructive) { handlers.actions.deleteAllData() }])
        }
    }

    // MARK: About

    static let evidence: [String] = [
        "The stretch with a band is two minutes of elastic band exercise: three short sets with rests between them.",
        "Eye rests follow the common advice to look at something far away for about 20 seconds every so often.",
        "Breakpoint keeps no score and makes no promise about how you will feel. It offers the pause; the rest is up to you.",
    ]

    static let acknowledgements = "Built with Swift, Win32 and Direct2D, with no third-party code. Icons are Segoe Fluent Icons. The chime is synthesised on your \(BreakpointPlatform.computerName). Thanks to everyone who tried early builds and said what got in their way."

    /// Version, Updates (§2.11), "General wellness, not medical advice.", evidence notes,
    /// acknowledgements.
    static func about(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let look = page.look
        page.gap(4)
        let heroHeight: Float = 72
        if let canvas = page.canvas {
            appIcon(canvas, RectF(x: page.x, y: page.y, width: heroHeight, height: heroHeight))
            let lines: [(String, TextStyle, Colour, Float)] = [
                ("Breakpoint", TextStyle(size: 22, weight: 700), look.text, 3),
                ("Break reminders that wait for your agent.", Theme.Typography.row, look.secondary, 5),
                ("Version \(BreakpointVersion.current)", TextStyle(size: 11, weight: 500, monospacedDigits: true), look.secondary, 3),
                (Copy.aboutTagline, TextStyle(size: 11), look.secondary, 0),
            ]
            let total = lines.reduce(Float(0)) { $0 + Canvas.measure($1.0, style: $1.1).height + $1.3 }
            var y = page.y + (heroHeight - total) / 2
            for (text, style, colour, after) in lines {
                y += canvas.text(text, at: PointF(x: page.x + heroHeight + 16, y: y), style: style, colour).height + after
            }
        }
        page.gap(heroHeight + SettingsMetrics.sectionGap)

        updates(&page, model, handlers)

        page.section { rows in
            rows.row(BreakCopyLibrary.wellnessDisclaimer,
                     description: "Breakpoint suggests short movement and eye rests, and leaves the rest to you.", symbol: "heart.text.square")
        }
        page.section("Evidence notes") { rows in
            for (index, line) in evidence.enumerated() {
                if index > 0 { rows.divider() }
                rows.gap(10)
                rows.paragraph(line, colour: rows.look.text, indent: 0)
                rows.gap(10)
            }
        }
        page.section("Acknowledgements") { rows in
            rows.gap(10)
            rows.paragraph(acknowledgements, colour: rows.look.text, indent: 0)
            rows.gap(10)
        }
    }

    /// The app's icon at 72 DIPs: the mark in mint on a dark rounded square with a faint brand glow.
    static func appIcon(_ canvas: Canvas, _ rect: RectF) {
        let side = rect.width
        let tile = rect.insetBy(side * 0.04, side * 0.04)
        canvas.shadow(tile, radius: side * 0.22, blur: 6, offset: PointF(x: 0, y: 2), Colour.black.opacity(0.2))
        canvas.fill(tile, radius: side * 0.22, Theme.Palette.solidOverlay)
        canvas.gradient(tile, radius: side * 0.22, from: Theme.Palette.indigo.opacity(0.22), to: Theme.Palette.mint.opacity(0.08), angle: 60)
        BrandMark.drawMark(in: tile.insetBy(side * 0.12, side * 0.12), on: canvas, tag: Theme.Palette.mint, eyes: Theme.Palette.solidOverlay)
    }

    /// Settings → About → Updates: where things stand, Check now, Update (or the download page),
    /// the automatic check and automatic installs (SPEC §2.11, §3.9).
    static func updates(_ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let update = model.state.update
        let settings = model.state.settings
        let actions = handlers.actions
        let title: String
        let symbol: String
        var description: String?
        let lastChecked = update.lastCheckedAt.map { UpdateCopy.lastChecked($0, now: model.state.now) + "." }
        var trailing: [SettingsTrailing] = []
        switch update.phase {
        case .idle:
            title = UpdateCopy.neverChecked
            symbol = "clock"
            description = "You have version \(update.currentVersion)."
        case .checking:
            title = UpdateCopy.checking
            symbol = "clock"
            description = lastChecked
        case .upToDate:
            title = UpdateCopy.upToDate
            symbol = "checkmark.circle"
            description = lastChecked
        case .available(let release):
            title = UpdateCopy.available(version: release.version)
            symbol = "arrow.down.circle"
            let notes = UpdateCopy.promptDetail(notes: release.notes)
            description = update.canInstall
                ? notes + " Update downloads it, checks its signature and reopens Breakpoint."
                : notes + " The download page has the new copy and how to install it."
        case .installing(let release, let step):
            title = UpdateCopy.available(version: release.version)
            symbol = "arrow.down.circle"
            description = step.text
        case .installFailed(let release, let reason):
            title = UpdateCopy.installFailedTitle(version: release.version)
            symbol = "exclamationmark.circle"
            description = reason + " The download page has the new copy."
        case .failed:
            title = UpdateCopy.failed
            symbol = "wifi.slash"
            description = "No connection, or no release is published yet. Breakpoint tries again in a few hours."
        }
        switch update.phase {
        case .checking, .installing:
            trailing = [.spinner(phase: spinnerPhase(model))]
        case .available:
            trailing = [.button("checkNow", "Check now") { actions.checkForUpdates() }]
            if update.canInstall {
                trailing.append(.button("installUpdate", "Update", role: .primary) { actions.installUpdate() })
            } else {
                trailing.append(.button("openUpdate", "Download page…", role: .primary) { actions.openUpdate() })
            }
        case .installFailed:
            trailing = [.button("openUpdate", "Open download page…", role: .primary) { actions.openUpdate() }]
        default:
            trailing = [.button("checkNow", "Check now") { actions.checkForUpdates() }]
        }
        page.section("Updates") { rows in
            rows.row(title, description: description, symbol: symbol, trailing: trailing)
            rows.divider()
            toggle(&rows, handlers, model, \.checkForUpdates, id: "checkForUpdates", title: "Check for updates automatically",
                   description: UpdateCopy.automaticDescription, symbol: "arrow.triangle.2.circlepath")
            rows.divider()
            toggle(&rows, handlers, model, \.installUpdatesAutomatically, id: "installUpdatesAutomatically",
                   title: "Install updates automatically", description: update.installBlocker ?? UpdateCopy.autoInstallDescription,
                   symbol: "arrow.down.app", enabled: settings.checkForUpdates && update.installBlocker == nil)
        }
    }

    // MARK: Sheets

    /// Options… on "Pause during calls", and on the Codex row (legacy notify).
    static func sheet(_ sheet: SettingsUI.Sheet, _ page: inout SettingsPage, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let look = page.look
        switch sheet {
        case .callOptions:
            page.canvas?.text("Call options", at: PointF(x: page.x, y: page.y), style: Theme.Typography.paneTitle, look.text)
            page.gap(24 + 16)
            page.section { rows in
                toggle(&rows, handlers, model, \.pauseForCamera, id: "pauseForCamera", title: "Also pause when the camera is on",
                       description: "Turn this off if your camera is often on outside calls.", symbol: "video")
            }
        case .codexOptions:
            let hooksInstalled = model.state.integration(.codex)?.canRemove ?? false
            let legacy = model.state.integration(.codexNotify)
            page.canvas?.text("Codex options", at: PointF(x: page.x, y: page.y), style: Theme.Typography.paneTitle, look.text)
            page.gap(24 + 16)
            page.paragraph("Older Codex versions have no hooks. For those, Breakpoint can add one notify line to ~\\.codex\\config.toml instead; it reports only when a turn finishes.",
                           indent: 0)
            page.gap(16)
            var trailing: [SettingsTrailing]
            if legacy?.isBusy == true {
                trailing = [.spinner(phase: spinnerPhase(model))]
            } else if legacy?.canRemove == true {
                trailing = [.button("legacy.remove", "Remove") { handlers.actions.uninstall(.codexNotify) }]
            } else {
                trailing = [.button("legacy.install", "Install", enabled: !hooksInstalled) { handlers.actions.install(.codexNotify) }]
            }
            var problem: String?
            if let error = legacy?.errorMessage {
                problem = error
            } else if let legacy, case .problem(let reason) = legacy.status {
                problem = reason
            }
            page.section { rows in
                rows.row("Use legacy notify (older Codex)",
                         description: hooksInstalled ? "Remove the Codex hooks first; the two are never installed together."
                             : "Refused if config.toml already has a notify line of its own.",
                         symbol: "bell.badge", trailing: trailing)
                if let problem {
                    rows.divider()
                    rows.gap(8)
                    let size = Canvas.measure(problem, style: Theme.Typography.rowDescription, width: rows.width - 16)
                    if let canvas = rows.canvas {
                        SettingsDraw.warning(canvas, centre: PointF(x: rows.x + 5, y: rows.y + 7), size: 10)
                        canvas.text(problem, at: PointF(x: rows.x + 16, y: rows.y), width: rows.width - 16, style: Theme.Typography.rowDescription,
                                    look.dark ? SettingsDraw.orange : SettingsDraw.orangeLight)
                    }
                    rows.gap(size.height + 8)
                }
            }
        }
        page.gap(-8)
        let width = Canvas.measure("Done", style: Theme.Typography.button).width + 40
        let done = RectF(x: page.x + page.width - max(88, width), y: page.y, width: max(88, width), height: 32)
        if let canvas = page.canvas, let controls = page.controls {
            controls.button(canvas, id: "sheet.done", done, "Done", role: .primary) { handlers.closeSheet() }
        }
        page.gap(32)
    }
}

/// A one-line text field (the Codex folder): typed into through the window's character messages
/// while it has the focus; Enter or leaving it keeps the text, Esc puts it back.
@MainActor
enum SettingsTextField {
    static func draw(_ canvas: Canvas, _ controls: Controls, id: String, _ rect: RectF, text: String, placeholder: String,
                     editing: Bool, action: @escaping () -> Void) {
        let look = controls.look
        canvas.fill(rect, radius: 4, look.dark ? Colour.white.opacity(editing ? 0.04 : 0.07) : Colour.white.opacity(editing ? 1 : 0.8))
        canvas.stroke(rect.insetBy(0.5, 0.5), radius: 4, width: 1, look.text.opacity(0.14))
        if editing {
            canvas.clipped(to: rect, radius: 4) {
                canvas.fill(RectF(x: rect.x, y: rect.maxY - 2, width: rect.width, height: 2), look.accent)
            }
        } else {
            canvas.fill(RectF(x: rect.x + 4, y: rect.maxY - 1, width: rect.width - 8, height: 1), look.text.opacity(0.35))
        }
        let inner = rect.insetBy(8, 0)
        let style = TextStyle(size: 12)
        let shown = text.isEmpty ? placeholder : text
        let size = Canvas.measure(shown, style: style)
        // Long text keeps its end (where typing goes) in view.
        let x = size.width > inner.width && !text.isEmpty ? inner.maxX - size.width - (editing ? 2 : 0) : inner.x
        canvas.clipped(to: inner, radius: 0) {
            canvas.text(shown, at: PointF(x: x, y: rect.midY - size.height / 2), style: style, text.isEmpty ? look.hint : look.text)
            if editing {
                let caretX = text.isEmpty ? inner.x : x + size.width + 1
                canvas.fill(RectF(x: caretX, y: rect.midY - 7, width: 1, height: 14), look.text)
            }
        }
        controls.region(id, rect, focusable: true, action: action)
        SettingsDraw.focusRing(canvas, controls, id: id, rect, radius: 4)
    }
}
