import BreakpointCore
import BreakpointRuntime
import Foundation

// SPEC §3.10 step 3: detected tools, each with Install. Install is the whole step: a spinner while
// Breakpoint writes the hooks and checks them, then a mint ✓ "Connected" pill whose ✓ hops once. A
// failed check shows one orange line (what is wrong and what to do) with Install again. Codex alone
// keeps its trust line until Codex is first heard from. Nothing is written until Install is pressed.

@MainActor
enum OnboardingConnect {
    static let cardWidth: Float = 456
    static let codexTrustLine = "One step in Codex: open /hooks and trust the entries."

    static func page(_ canvas: Canvas, _ controls: Controls, look: Look, content: RectF, state: AppState, model: OnboardingModel,
                     handlers: OnboardingView.Handlers, now: Date) {
        var y = OnboardingView.header(canvas, look: look, content: content, title: "Connect your agent",
                                      sentence: "Breakpoint adds a few small hooks to your tool’s settings, so it knows when an agent starts and stops. Nothing is written until you press Install.")
        let rows = state.integrations.filter { IntegrationID.settingsRows.contains($0.id) }
        let detected = rows.filter { $0.status != .notFound }
        let missing = rows.filter { $0.status == .notFound }
        let x = content.midX - cardWidth / 2
        if detected.isEmpty {
            let text = "No supported tools found on this PC yet. You can connect one later in Settings → Integrations."
            let size = Canvas.measure(text, style: Theme.Typography.bodyWrapped, width: cardWidth - 32)
            let rect = RectF(x: x, y: y, width: cardWidth, height: size.height + 32)
            OnboardingView.card(canvas, rect, look: look)
            canvas.text(text, at: PointF(x: x + 16, y: y + 16), width: cardWidth - 32, style: Theme.Typography.bodyWrapped, look.secondary)
            y += rect.height
        } else {
            let heights = detected.map { row(nil, nil, $0, at: PointF(x: x, y: 0), look: look, model: model, handlers: handlers, now: now) }
            let total = heights.reduce(0, +) + Float(detected.count - 1)
            OnboardingView.card(canvas, RectF(x: x, y: y, width: cardWidth, height: total), look: look)
            for (index, item) in detected.enumerated() {
                if index > 0 {
                    canvas.fill(RectF(x: x + 46, y: y, width: cardWidth - 46, height: 1), look.stroke.opacity(0.7))
                    y += 1
                }
                y += row(canvas, controls, item, at: PointF(x: x, y: y), look: look, model: model, handlers: handlers, now: now)
            }
        }
        if !missing.isEmpty {
            y += 10
            canvas.text("Not on this PC: \(missing.map(\.displayName).joined(separator: ", ")).", at: PointF(x: x + 4, y: y),
                        width: cardWidth - 8, style: Theme.Typography.rowDescription, look.secondary)
        }
    }

    /// One tool: its tile, name and the line under it, and Install / the spinner / Connected.
    /// Returns its height (nil canvas: measure only).
    private static func row(_ canvas: Canvas?, _ controls: Controls?, _ row: IntegrationRowState, at origin: PointF, look: Look,
                            model: OnboardingModel, handlers: OnboardingView.Handlers, now: Date) -> Float {
        let buttons = trailingButtons(row)
        let trailingWidth: Float
        if row.isBusy {
            trailingWidth = 16
        } else if case .connected = row.status {
            trailingWidth = pillWidth
        } else {
            trailingWidth = buttons.map { OnboardingView.buttonWidth($0.title) }.reduce(0, +) + Float(max(0, buttons.count - 1)) * 6
        }
        let textX = origin.x + 12 + 24 + 10
        let textWidth = cardWidth - (textX - origin.x) - 8 - trailingWidth - 12
        let detailStyle = Theme.Typography.rowDescription
        let lines = detailLines(row)
        let warning = isWarning(row)
        let detailIndent: Float = warning ? 16 : 0
        let nameHeight = Canvas.measure(row.displayName, style: Theme.Typography.bodySemibold).height
        let lineHeights = lines.map { Canvas.measure($0.text, style: detailStyle, width: textWidth - ($0.orange && warning ? detailIndent : 0)).height }
        let textHeight = nameHeight + (lines.isEmpty ? 0 : 2 + lineHeights.reduce(0, +))
        let height = max(46, textHeight + 12)
        guard let canvas, let controls else { return height }

        let midY = origin.y + height / 2
        SourceTile.draw(canvas, RectF(x: origin.x + 12, y: midY - 12, width: 24, height: 24),
                        symbol: MenuBarGlyphs.integrationSymbol(row.id), look: look)
        var y = midY - textHeight / 2
        canvas.text(row.displayName, at: PointF(x: textX, y: y), style: Theme.Typography.bodySemibold, look.text)
        y += nameHeight + 2
        let orange = look.dark ? Colour(hex: 0xFF9F0A) : Colour(hex: 0xC25400)
        for (index, line) in lines.enumerated() {
            var lx = textX
            if line.orange, warning, index == 0 {
                OnboardingView.icon(canvas, "\u{E7BA}", centre: PointF(x: lx + 6, y: y + 7), size: 11, orange)
                lx += detailIndent
            }
            canvas.text(line.text, at: PointF(x: lx, y: y), width: textWidth - (lx - textX), style: detailStyle,
                        line.orange ? orange : look.secondary)
            y += lineHeights[index]
        }

        let right = origin.x + cardWidth - 12
        if row.isBusy {
            spinner(canvas, centre: PointF(x: right - 8, y: midY), look: look, model: model, now: now)
        } else if case .connected = row.status {
            connectedPill(canvas, at: PointF(x: right - pillWidth, y: midY - Theme.Size.smallButtonHeight / 2), look: look,
                          progress: model.hop(row.id, at: now), reduceMotion: model.reduceMotion)
        } else {
            var bx = right
            for button in buttons.reversed() {
                let w = OnboardingView.buttonWidth(button.title)
                bx -= w
                let action = button.action
                controls.button(canvas, id: "\(row.id.rawValue).\(button.title)",
                                RectF(x: bx, y: midY - Theme.Size.smallButtonHeight / 2, width: w, height: Theme.Size.smallButtonHeight),
                                button.title, role: button.role) {
                    action == .install ? handlers.install(row.id) : handlers.uninstall(row.id)
                }
                bx -= 6
            }
        }
        return height
    }

    private struct Line {
        let text: String
        let orange: Bool
    }

    private static func isWarning(_ row: IntegrationRowState) -> Bool {
        if case .problem = row.status { return true }
        return false
    }

    /// Under the name: where the hooks live (or Codex's trust step, or the install's own note), or
    /// the failed check's one orange line; and the last install's error.
    private static func detailLines(_ row: IntegrationRowState) -> [Line] {
        var lines: [Line] = []
        switch row.status {
        case .notInstalled: lines.append(Line(text: shortLine(row.id), orange: false))
        case .connected(let lastEvent): lines.append(Line(text: connectedLine(row, lastEvent: lastEvent), orange: false))
        case .problem(let reason): lines.append(Line(text: reason, orange: true))
        case .notFound: break
        }
        if let error = row.errorMessage { lines.append(Line(text: error, orange: true)) }
        return lines
    }

    static func connectedLine(_ row: IntegrationRowState, lastEvent: Date?) -> String {
        if row.id == .codex { return lastEvent == nil ? codexTrustLine : shortLine(row.id) }
        return row.notes.isEmpty ? shortLine(row.id) : row.notes.joined(separator: " ")
    }

    static func shortLine(_ id: IntegrationID) -> String {
        switch id {
        case .claudeCode: return "Hooks in ~/.claude/settings.json"
        case .cursor: return "Hooks in ~/.cursor/hooks.json"
        case .codex, .codexNotify: return "Hooks in ~/.codex/hooks.json"
        case .copilot: return "One file in ~/.copilot/hooks"
        case .gemini: return "Hooks in ~/.gemini/settings.json"
        case .shell: return "Breaks during long commands"
        }
    }

    private enum Action { case install, uninstall }

    private static func trailingButtons(_ row: IntegrationRowState) -> [(title: String, role: Controls.Role, action: Action)] {
        switch row.status {
        case .problem where row.installState == .installed:
            // A failed install check: trying again is the one thing to do here.
            return [("Install again", .primary, .install)]
        case .problem where row.canRemove:
            let label: String
            switch row.installState {
            case .outdated: label = "Update"
            case .modified: label = "Restore"
            default: label = "Install again"
            }
            return [("Remove", .quiet, .uninstall), (label, .primary, .install)]
        case .notInstalled, .problem:
            return [("Install", .primary, .install)]
        case .connected, .notFound:
            return []
        }
    }

    // MARK: Spinner and pill

    /// A small indeterminate arc, one turn a second (still under reduced motion).
    private static func spinner(_ canvas: Canvas, centre: PointF, look: Look, model: OnboardingModel, now: Date) {
        let turn = model.reduceMotion || model.frozen ? 0 : Float(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1))
        let colour = look.secondary
        let start = turn, end = turn + 0.7
        if end <= 1 {
            canvas.arc(centre, radius: 7, from: start, to: end, width: 2, colour)
        } else {
            canvas.arc(centre, radius: 7, from: start, to: 1, width: 2, colour)
            canvas.arc(centre, radius: 7, from: 0, to: end - 1, width: 2, colour)
        }
    }

    static var pillWidth: Float {
        (10 + 12 + 5 + Canvas.measure("Connected", style: Theme.Typography.bodySemibold).width + 10).rounded(.up)
    }

    /// ✓ "Connected": a mint pill. Just verified, the ✓ hops 4 DIPs once and the pill flashes mint
    /// (0.4 s; a 0.2 s fade without the hop under reduced motion).
    static func connectedPill(_ canvas: Canvas, at origin: PointF, look: Look, progress: Double, reduceMotion: Bool) {
        let t = min(1, max(0, progress))
        let elapsed = t * OnboardingView.hopDuration
        let flashLength = reduceMotion ? 0.2 : 0.4
        let flash = Float(max(0, 1 - elapsed / flashLength))
        let rect = RectF(x: origin.x, y: origin.y, width: pillWidth, height: Theme.Size.smallButtonHeight)
        canvas.fill(rect, radius: rect.height / 2, look.accent.opacity(0.12 + 0.22 * flash))
        let hop = reduceMotion ? 0 : Float(MarkMotion.hopOffset(progress: t))
        let check = PointF(x: rect.x + 10 + 6, y: rect.midY + hop)
        canvas.path("MLL", [check.x - 4, check.y, check.x - 1.2, check.y + 3, check.x + 4.2, check.y - 3.2], look.accent, stroke: 1.8)
        let size = Canvas.measure("Connected", style: Theme.Typography.bodySemibold)
        canvas.text("Connected", at: PointF(x: rect.x + 10 + 12 + 5, y: rect.midY - size.height / 2), style: Theme.Typography.bodySemibold,
                    look.text)
    }
}
