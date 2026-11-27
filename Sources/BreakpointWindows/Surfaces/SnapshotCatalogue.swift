import BreakpointCore
import BreakpointRuntime
import Foundation

/// Every Windows surface in every state the shared previews describe (`AppState.preview`), as
/// PNGs: `Breakpoint.exe --debug-snapshots DIR` (debug builds). The review loop for the Windows
/// UI, as `swift run BreakpointSnapshots` is on the Mac; each surface family adds its own pages.
@MainActor
public enum SnapshotCatalogue {
    /// Scenarios that change what the flyout and the pop-ups say.
    static let scenarios: [(String, PreviewScenario)] = [
        ("idle", .idle), ("agent-working", .agentWorking), ("break-due", .breakDue(.move)),
        ("auto-start", .autoStart(remaining: 6)), ("on-break", .onBreak(.move, progress: 0.4)),
        ("paused-call", .pausedForCall), ("paused-manual", .pausedManual), ("away-credited", .awayCredited),
        ("wind-down", .windDown(wrapUp: false)), ("wind-down-note", .windDown(wrapUp: true)),
        ("several-agents", .severalAgents), ("resume-one", .resume(.one)), ("resume-several", .resume(.several)),
        ("resume-needs-you", .resume(.needsYou)), ("toast", .toast), ("first-run", .firstRun),
    ]

    /// Writes every page into `directory` and returns how many images it wrote.
    @discardableResult
    public static func writeAll(to directory: URL) throws -> Int {
        var count = 0
        count += try flyout(directory.appendingPathComponent("flyout"))
        count += try trayMarks(directory.appendingPathComponent("tray"))
        count += try glyphs(directory.appendingPathComponent("design"))
        for page in pages { count += try page(directory) }
        return count
    }

    /// Further pages (pop-ups, overlay, onboarding, settings, tour), each writing into its own
    /// folder under the directory it is given and returning its image count.
    static var pages: [(URL) throws -> Int] {
        [popupSnapshots, overlaySnapshots, onboardingSnapshots, settingsSnapshots, tourSnapshots]
    }

    static func flyout(_ directory: URL) throws -> Int {
        var count = 0
        for (name, scenario) in scenarios {
            let state = AppState.preview(scenario)
            let height = FlyoutView.height(state)
            try Snapshot.write(directory.appendingPathComponent("\(name).png"), size: SizeF(width: FlyoutView.width, height: height)) {
                canvas, controls in FlyoutView.draw(canvas, controls, state, handlers: FlyoutView.Handlers())
            }
            count += 1
        }
        // Totals at each stage of use, and the keyboard focus ring.
        for stage in PreviewData.TotalsStage.allCases {
            let state = AppState.preview(.idle)
            state.totals = PreviewData().totals(stage)
            try Snapshot.write(directory.appendingPathComponent("totals-\(stage.rawValue).png"),
                               size: SizeF(width: FlyoutView.width, height: FlyoutView.height(state))) { canvas, controls in
                FlyoutView.draw(canvas, controls, state, handlers: FlyoutView.Handlers())
            }
            count += 1
        }
        let state = AppState.preview(.idle)
        try Snapshot.write(directory.appendingPathComponent("focus.png"), size: SizeF(width: FlyoutView.width, height: FlyoutView.height(state)),
                           focused: "pause") { canvas, controls in
            controls.debugShowFocus()
            FlyoutView.draw(canvas, controls, state, handlers: FlyoutView.Handlers())
        }
        return count + 1
    }

    /// The tray mark in every state, at the tray's sizes (16, 20, 24, 32 px) on a dark and a light
    /// taskbar, enlarged 4× so the pixels can be judged.
    static func trayMarks(_ directory: URL) throws -> Int {
        var count = 0
        let sizes: [Float] = [16, 20, 24, 32]
        for light in [false, true] {
            let variants: [(MarkVariant, MarkBadge)] = MarkVariant.allCases.filter { $0 != .brand }.flatMap { variant in
                MarkBadge.allCases.map { (variant, $0) }
            }
            let cell: Float = 40
            let width = Float(sizes.count) * cell + 8, height = Float(variants.count) * cell + 8
            try Snapshot.write(directory.appendingPathComponent("marks-\(light ? "light" : "dark")-taskbar.png"),
                               size: SizeF(width: width, height: height), scale: 4,
                               background: { $0.fill($0.bounds, light ? Colour(hex: 0xEEEEEE) : Colour(hex: 0x1C1C1C)) }) { canvas, _ in
                for (row, (variant, badge)) in variants.enumerated() {
                    for (column, size) in sizes.enumerated() {
                        let origin = PointF(x: 4 + Float(column) * cell + (cell - size) / 2, y: 4 + Float(row) * cell + (cell - size) / 2)
                        TrayMark.draw(canvas, in: RectF(x: origin.x, y: origin.y, width: size, height: size), variant: variant,
                                      badge: badge, colour: light ? Colour(0.1, 0.1, 0.12) : Colour.white)
                    }
                }
            }
            count += 1
        }
        return count
    }

    /// Every glyph the shared models name, and the kind badges.
    static func glyphs(_ directory: URL) throws -> Int {
        let symbols = BreakKind.allCases.map(\.symbolName)
            + [AgentSource.claudeCode, .cursor, .codex, .copilot, .gemini, .shell].map(MenuBarGlyphs.sourceSymbol)
            + Glyphs.fontGlyphs.keys.sorted() + SettingsPane.allCases.map(\.systemImage)
        let columns = 8
        let cell: Float = 64
        let rows = (symbols.count + columns - 1) / columns
        try Snapshot.write(directory.appendingPathComponent("glyphs.png"),
                           size: SizeF(width: Float(columns) * cell, height: Float(rows) * cell + 80)) { canvas, _ in
            for (index, symbol) in symbols.enumerated() {
                let x = Float(index % columns) * cell, y = Float(index / columns) * cell
                Glyphs.draw(symbol, on: canvas, centre: PointF(x: x + cell / 2, y: y + 24), size: 20, Colour.white)
                canvas.text(symbol, in: RectF(x: x + 2, y: y + 44, width: cell - 4, height: 16),
                            style: TextStyle(size: 8, align: .center), Colour.white.opacity(0.6))
            }
            let y = Float(rows) * cell + 40
            for (index, kind) in BreakKind.allCases.enumerated() {
                KindBadge.draw(canvas, centre: PointF(x: 40 + Float(index) * 60, y: y), symbol: kind.symbolName,
                               ringProgress: index == 0 ? 0.6 : nil)
            }
            KindBadge.draw(canvas, centre: PointF(x: 280, y: y), symbol: "sparkle", tone: .agent)
            KindBadge.draw(canvas, centre: PointF(x: 340, y: y), symbol: "sparkle", tone: .needsYou)
            KindBadge.draw(canvas, centre: PointF(x: 400, y: y), diameter: 28, symbol: "terminal", tone: .neutral)
        }
        return 1
    }
}
