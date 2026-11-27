import Foundation

/// The symbols the shared presentation models name by SF Symbol (`BreakKind.symbolName`,
/// `MenuBarGlyphs`), drawn the Windows way: the break kinds and the agent sparkle as vector
/// drawings in the brand's line style (they carry the product's identity, SPEC §4.1), everything
/// else from the system's own icon font (Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets on
/// Windows 10, which share code points), so controls look like Windows controls.
@MainActor
public enum Glyphs {
    /// The system icon font.
    static let iconFamily: String = {
        // Windows 11 has both; Windows 10 only MDL2.
        let fluent = Canvas.measure("\u{E713}", style: TextStyle(size: 16, family: "Segoe Fluent Icons"))
        let mdl2 = Canvas.measure("\u{E713}", style: TextStyle(size: 16, family: "Segoe MDL2 Assets"))
        return fluent.width > 0 && abs(fluent.width - mdl2.width) < 8 ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
    }()

    /// Icon-font code points for SF Symbol names that have a system equivalent.
    static let fontGlyphs: [String: String] = [
        "gearshape": "\u{E713}",            // Settings
        "play.fill": "\u{E768}",            // Play
        "pause.fill": "\u{E769}",           // Pause
        "chevron.down": "\u{E70D}",         // ChevronDown
        "chevron.right": "\u{E76C}",        // ChevronRight
        "chevron.left": "\u{E76B}",         // ChevronLeft
        "checkmark": "\u{E73E}",            // CheckMark
        "xmark": "\u{E711}",                // Cancel
        "mic.fill": "\u{E720}",             // Microphone
        "video.fill": "\u{E714}",           // Video
        "moon.fill": "\u{E708}",            // QuietHours
        "clock": "\u{E823}",                // Recent
        "terminal": "\u{E756}",             // CommandPrompt
        "paperplane": "\u{E724}",           // Send
        "cursorarrow.rays": "\u{E8B0}",     // Cursor (SelectAll pointer)
        "arrow.uturn.backward": "\u{E7A7}", // Undo
        "info.circle": "\u{E946}",          // Info
        "exclamationmark.triangle": "\u{E7BA}", // Warning
        "arrow.down.circle": "\u{E896}",    // Download
        "link": "\u{E71B}",                 // Link
        "person": "\u{E77B}",               // Contact
        "bell": "\u{EA8F}",                 // Ringer
        "speaker.wave.2": "\u{E767}",       // Volume
        "keyboard": "\u{E765}",             // Keyboard
        "lock": "\u{E72E}",                 // Lock
        "doc.on.doc": "\u{E8C8}",           // Copy
        "square.and.arrow.up": "\u{EDE1}",  // Export
        "trash": "\u{E74D}",                // Delete
        "arrow.clockwise": "\u{E72C}",      // Refresh
        "sun.max": "\u{E706}",              // Brightness
        // The settings panes' icons (SettingsPane.systemImage) and a few more.
        "timer": "\u{E916}",                // Stopwatch
        "pause": "\u{E769}",                // Pause
        "moon": "\u{E708}",                 // QuietHours
        "point.3.connected.trianglepath.dotted": "\u{E71B}", // Link
        "hand.raised": "\u{E72E}",          // Lock (privacy)
        "info": "\u{E946}",                 // Info
        "hourglass": "\u{E916}",            // Stopwatch
        "clock.arrow.circlepath": "\u{E81C}", // History
        "play": "\u{E768}",                 // Play
    ]

    /// Draws `symbol` centred on `centre`, `size` DIPs tall, in `colour`.
    public static func draw(_ symbol: String, on canvas: Canvas, centre: PointF, size: Float, _ colour: Colour,
                            weight: Float = 1) {
        switch symbol {
        case "eye": eye(canvas, centre, size, colour, weight)
        case "figure.arms.open": stretch(canvas, centre, size, colour, weight)
        case "figure.walk": walk(canvas, centre, size, colour, weight)
        case "wind": wind(canvas, centre, size, colour, weight)
        case "sparkle": sparkle(canvas, centre, size, colour)
        case "sparkles":
            sparkle(canvas, PointF(x: centre.x - size * 0.12, y: centre.y + size * 0.08), size * 0.78, colour)
            sparkle(canvas, PointF(x: centre.x + size * 0.3, y: centre.y - size * 0.3), size * 0.4, colour)
        case "curlybraces":
            canvas.text("{ }", in: RectF(x: centre.x - size, y: centre.y - size * 0.7, width: size * 2, height: size * 1.4),
                        style: TextStyle(size: size * 0.95, weight: 700, align: .center, family: "Cascadia Mono"), colour)
        case "circle.hexagongrid":
            let r = size * 0.11
            for (dx, dy) in [(-0.25, -0.22), (0.25, -0.22), (-0.5, 0.2), (0, 0.2), (0.5, 0.2), (-0.25, 0.62), (0.25, 0.62)] {
                canvas.circle(PointF(x: centre.x + Float(dx) * size * 0.6, y: centre.y + (Float(dy) - 0.2) * size * 0.6), radius: r, colour)
            }
        default:
            // A single character names an icon-font glyph directly; anything unknown is a page.
            let glyph = fontGlyphs[symbol] ?? (symbol.unicodeScalars.count == 1 ? symbol : "\u{E7C3}")
            let box = RectF(x: centre.x - size, y: centre.y - size * 0.75, width: size * 2, height: size * 1.5)
            canvas.text(glyph, in: box, style: TextStyle(size: size, align: .center, family: iconFamily), colour)
        }
    }

    // MARK: The brand's line glyphs (on a 24-unit grid, scaled to `size`)

    private static func points(_ centre: PointF, _ size: Float, _ grid: [Float]) -> [Float] {
        let s = size / 24
        return grid.enumerated().map { index, value in
            index % 2 == 0 ? centre.x + (value - 12) * s : centre.y + (value - 12) * s
        }
    }

    private static func eye(_ canvas: Canvas, _ c: PointF, _ size: Float, _ colour: Colour, _ weight: Float) {
        let stroke = size * 0.09 * weight
        // Upper and lower lids as two curves, then the iris.
        canvas.path("MC", points(c, size, [1.8, 12, 6.5, 4.2, 17.5, 4.2, 22.2, 12]), colour, stroke: stroke)
        canvas.path("MC", points(c, size, [1.8, 12, 6.5, 19.8, 17.5, 19.8, 22.2, 12]), colour, stroke: stroke)
        canvas.circle(c, radius: size * 0.155, colour)
    }

    private static func stretch(_ canvas: Canvas, _ c: PointF, _ size: Float, _ colour: Colour, _ weight: Float) {
        let stroke = size * 0.1 * weight
        let head = points(c, size, [12, 3.6])
        canvas.circle(PointF(x: head[0], y: head[1]), radius: size * 0.115, colour)
        canvas.path("MLL", points(c, size, [3, 6.5, 12, 10, 21, 6.5]), colour, stroke: stroke)
        canvas.path("ML", points(c, size, [12, 10, 12, 15]), colour, stroke: stroke)
        canvas.path("MLL", points(c, size, [7.5, 22, 12, 15, 16.5, 22]), colour, stroke: stroke)
    }

    private static func walk(_ canvas: Canvas, _ c: PointF, _ size: Float, _ colour: Colour, _ weight: Float) {
        let stroke = size * 0.1 * weight
        let head = points(c, size, [13.5, 3.4])
        canvas.circle(PointF(x: head[0], y: head[1]), radius: size * 0.11, colour)
        canvas.path("ML", points(c, size, [12.5, 8, 11, 14.5]), colour, stroke: stroke)            // torso
        canvas.path("MLL", points(c, size, [7, 12, 10, 8.6, 12.5, 8]), colour, stroke: stroke)     // back arm
        canvas.path("MLL", points(c, size, [12.5, 8, 15, 11, 18, 12]), colour, stroke: stroke)     // front arm
        canvas.path("MLL", points(c, size, [11, 14.5, 14, 17.5, 15.5, 22]), colour, stroke: stroke) // front leg
        canvas.path("MLL", points(c, size, [11, 14.5, 9.5, 18.5, 6.5, 21.5]), colour, stroke: stroke) // back leg
    }

    private static func wind(_ canvas: Canvas, _ c: PointF, _ size: Float, _ colour: Colour, _ weight: Float) {
        let stroke = size * 0.09 * weight
        canvas.path("MLC", points(c, size, [2.5, 8.5, 15, 8.5, 19.5, 8.5, 19.5, 3.5, 15.5, 4.6]), colour, stroke: stroke)
        canvas.path("MLC", points(c, size, [2.5, 13, 18.5, 13, 23, 13, 23, 18.5, 18.5, 17.6]), colour, stroke: stroke)
        canvas.path("ML", points(c, size, [2.5, 17.5, 10, 17.5]), colour, stroke: stroke)
    }

    private static func sparkle(_ canvas: Canvas, _ c: PointF, _ size: Float, _ colour: Colour) {
        canvas.path("MQQQQZ", points(c, size, [12, 1.5, 13.2, 10.8, 22.5, 12, 13.2, 13.2, 12, 22.5, 10.8, 13.2, 1.5, 12, 10.8, 10.8, 12, 1.5]),
                    colour)
    }
}
