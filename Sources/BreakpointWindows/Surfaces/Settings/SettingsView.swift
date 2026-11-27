import BreakpointCore
import BreakpointRuntime
import Foundation

/// What the settings window keeps between frames that is not in `AppState` (what the macOS panes
/// keep in `@State`): the preview kind, the shortcut recorder, an open options sheet, the Codex
/// folder being typed, Copied, the volume being dragged, the pills flashing.
@MainActor
final class SettingsUI {
    enum Sheet: Equatable { case callOptions, codexOptions }

    var previewKind: BreakKind = .move
    /// The popover shortcut recorder is waiting for a key combination.
    var recording = false
    var recorderHint: String?
    var sheet: Sheet?
    /// The Codex folder as typed so far, while the field has the focus.
    var codexDraft: String?
    var copiedUntil: Date?
    var volumeDraft: Double?
    /// Rows whose install was just verified: their pill flashes mint (SPEC §4.6).
    var flashing: Set<IntegrationID> = []
    /// Whether this copy may register itself to open at login (General).
    var login: LoginItemAvailability = .available
    /// Busy spinners turn while true (never under Reduce Motion, never in snapshots).
    var spins = false

    let frames = SettingsFrames()
    /// Draws what takes no input: a dimmed section, everything under a sheet, rows under the header.
    let inert = Controls(look: .light)

    init() {}

    static let codexFieldID = "codexFolder.field"
    static let recorderID = "popoverShortcut"
}

/// Everything one frame of the window draws from.
@MainActor
struct SettingsModel {
    var state: AppState
    var pane: SettingsPane
    var scroll: Float = 0
    var look: Look
    var ui: SettingsUI
    /// Fill the window (transparency effects off, Windows 10, snapshots) instead of letting Mica
    /// show through.
    var opaque: Bool
}

/// What the window's controls do beyond `AppActions`.
@MainActor
struct SettingsHandlers {
    var actions: AppActions = .noop
    var select: (SettingsPane) -> Void = { _ in }
    /// Transient UI state changed: draw again.
    var changed: () -> Void = {}
    var startRecording: () -> Void = {}
    var revealData: () -> Void = {}
    var copyCommand: () -> Void = {}
    var chooseCodexFolder: () -> Void = {}
    var focusCodexField: () -> Void = {}
    var openSheet: (SettingsUI.Sheet) -> Void = { _ in }
    var closeSheet: () -> Void = {}

    init() {}
}

/// The settings window (SPEC §3.9): the sidebar (groups Breaks · Connections · You, 20 DIP tiles
/// on the mint → indigo ramp), the pane header (tile and 17 DIP title over a hairline) and the
/// pane, scrolled under the header. A pure drawing of `SettingsModel`, for the window and for
/// snapshots alike.
@MainActor
enum SettingsView {
    static let groups = ["Breaks", "Connections", "You"]

    // MARK: Geometry

    /// The pane's column: at most 640 wide, 24 in from the pane's edges, centred.
    static func column(windowWidth: Float) -> (x: Float, width: Float) {
        let pane = windowWidth - SettingsMetrics.sidebarWidth
        let width = min(SettingsMetrics.paneMaxWidth, pane - 2 * SettingsMetrics.paneInset)
        return (SettingsMetrics.sidebarWidth + (pane - width) / 2, width)
    }

    static func viewport(_ size: SizeF) -> RectF {
        RectF(x: SettingsMetrics.sidebarWidth, y: SettingsMetrics.headerHeight, width: size.width - SettingsMetrics.sidebarWidth,
              height: max(0, size.height - SettingsMetrics.headerHeight))
    }

    /// The pane's whole content height (top and bottom padding included).
    static func contentHeight(_ model: SettingsModel, windowWidth: Float) -> Float {
        let column = column(windowWidth: windowWidth)
        var page = SettingsPage(canvas: nil, controls: nil, inert: nil, look: model.look, x: column.x, width: column.width, y: 0)
        SettingsPanes.draw(model.pane, &page, model, SettingsHandlers())
        return SettingsMetrics.paneTop + page.y + SettingsMetrics.paneBottom - SettingsMetrics.sectionGap
    }

    static func maxScroll(_ model: SettingsModel, size: SizeF) -> Float {
        max(0, contentHeight(model, windowWidth: size.width) - viewport(size).height)
    }

    // MARK: Drawing

    static func draw(_ canvas: Canvas, _ controls: Controls, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let look = model.look
        let ui = model.ui
        ui.inert.look = look
        ui.inert.begin()
        ui.frames.rects.removeAll(keepingCapacity: true)
        let live: Controls = ui.sheet == nil ? controls : ui.inert
        background(canvas, look: look, opaque: model.opaque)

        // The pane, clipped under its header.
        let viewport = viewport(canvas.size)
        let column = column(windowWidth: canvas.size.width)
        canvas.clipped(to: viewport, radius: 0) {
            var page = SettingsPage(canvas: canvas, controls: live, inert: ui.inert, look: look, x: column.x, width: column.width,
                                    y: viewport.y + SettingsMetrics.paneTop - model.scroll, frames: ui.frames, scroll: model.scroll,
                                    viewportTop: viewport.y)
            SettingsPanes.draw(model.pane, &page, model, handlers)
        }
        header(canvas, model.pane, look: look)
        sidebar(canvas, live, model, handlers)
        if let sheet = ui.sheet { drawSheet(canvas, controls, sheet, model, handlers) }
    }

    /// Mica shows through the sidebar; the pane sits on a lighter layer with a rounded corner, as
    /// Windows 11's own settings do. Opaque: the system's window colours.
    static func background(_ canvas: Canvas, look: Look, opaque: Bool) {
        let bounds = canvas.bounds
        if opaque { canvas.fill(bounds, look.dark ? Colour(hex: 0x202020) : Colour(hex: 0xF3F3F3)) }
        let layer = RectF(x: SettingsMetrics.sidebarWidth, y: 0, width: bounds.width - SettingsMetrics.sidebarWidth + 12,
                          height: bounds.height + 12)
        let fill = look.dark ? Colour.white.opacity(opaque ? 0.035 : 0.04) : Colour.white.opacity(opaque ? 0.6 : 0.5)
        canvas.fill(layer, radius: 8, fill)
        canvas.stroke(layer.insetBy(0.5, 0.5), radius: 8, width: 1,
                      look.dark ? Colour.black.opacity(0.3) : Colour.black.opacity(Appearance.highContrast ? 0.3 : 0.07))
    }

    private static func header(_ canvas: Canvas, _ pane: SettingsPane, look: Look) {
        let x = SettingsMetrics.sidebarWidth + SettingsMetrics.paneInset
        let midY = SettingsMetrics.headerHeight / 2 + 2
        SettingsDraw.tile(canvas, RectF(x: x, y: midY - 10, width: 20, height: 20), symbol: pane.systemImage, index: pane.index)
        let size = Canvas.measure(pane.title, style: Theme.Typography.paneTitle)
        canvas.text(pane.title, at: PointF(x: x + 30, y: midY - size.height / 2), style: Theme.Typography.paneTitle, look.text)
        let hairline = Appearance.highContrast ? look.text.opacity(Theme.TextStep.hairline.opacity) : look.text.opacity(look.dark ? 0.09 : 0.08)
        canvas.fill(RectF(x: SettingsMetrics.sidebarWidth + 1, y: SettingsMetrics.headerHeight - 1,
                          width: canvas.size.width - SettingsMetrics.sidebarWidth, height: 1), hairline)
    }

    static func sidebarID(_ pane: SettingsPane) -> String { "sidebar.\(pane.rawValue)" }

    private static func sidebar(_ canvas: Canvas, _ controls: Controls, _ model: SettingsModel, _ handlers: SettingsHandlers) {
        let look = model.look
        var y: Float = 10
        for group in groups {
            canvas.text(group, at: PointF(x: 20, y: y + 4), style: TextStyle(size: 11, weight: 600), look.secondary)
            y += 24
            for pane in SettingsPane.allCases where pane.group == group {
                let row = RectF(x: 8, y: y, width: SettingsMetrics.sidebarWidth - 16, height: 32)
                let id = sidebarID(pane)
                let selected = pane == model.pane
                if selected {
                    canvas.fill(row, radius: 5, look.dark ? Colour.white.opacity(0.07) : Colour.black.opacity(0.05))
                    canvas.fill(RectF(x: row.x, y: row.midY - 8, width: 3, height: 16), radius: 1.5, look.accent)
                } else if controls.isHovered(id) {
                    canvas.fill(row, radius: 5, look.dark ? Colour.white.opacity(0.04) : Colour.black.opacity(0.03))
                }
                SettingsDraw.tile(canvas, RectF(x: row.x + 12, y: row.midY - 10, width: 20, height: 20), symbol: pane.systemImage,
                                  index: pane.index)
                let size = Canvas.measure(pane.title, style: Theme.Typography.body)
                canvas.text(pane.title, at: PointF(x: row.x + 42, y: row.midY - size.height / 2), style: Theme.Typography.body, look.text)
                controls.region(id, row, focusable: true) { handlers.select(pane) }
                SettingsDraw.focusRing(canvas, controls, id: id, row.insetBy(2, 2), radius: 4)
                y += 34
            }
            y += 10
        }
    }

    // MARK: Sheets

    static func sheetWidth(_ sheet: SettingsUI.Sheet) -> Float { sheet == .callOptions ? 440 : 480 }

    private static func drawSheet(_ canvas: Canvas, _ controls: Controls, _ sheet: SettingsUI.Sheet, _ model: SettingsModel,
                                  _ handlers: SettingsHandlers) {
        let look = model.look
        canvas.fill(canvas.bounds, Colour.black.opacity(look.dark ? 0.45 : 0.3))
        let width = min(sheetWidth(sheet), canvas.size.width - 32)
        var measure = SettingsPage(canvas: nil, controls: nil, inert: nil, look: look, x: 20, width: width - 40, y: 0)
        SettingsPanes.sheet(sheet, &measure, model, handlers)
        let height = measure.y + 40
        let card = RectF(x: ((canvas.size.width - width) / 2).rounded(), y: max(16, ((canvas.size.height - height) / 2 - 20).rounded()),
                         width: width, height: height)
        canvas.shadow(card, radius: 8, blur: 24, offset: PointF(x: 0, y: 8), Colour.black.opacity(0.3))
        canvas.fill(card, radius: 8, look.dark ? Colour(hex: 0x2C2C2C) : Colour(hex: 0xFAFAFA))
        canvas.stroke(card.insetBy(0.5, 0.5), radius: 8, width: 1, look.dark ? Colour.white.opacity(0.1) : Colour.black.opacity(0.1))
        // Everything under the sheet was drawn with inert controls: clicks outside it do nothing.
        var page = SettingsPage(canvas: canvas, controls: controls, inert: model.ui.inert, look: look, x: card.x + 20,
                                width: width - 40, y: card.y + 20)
        SettingsPanes.sheet(sheet, &page, model, handlers)
    }
}
