import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

/// `BreakpointSnapshots --window-probe DIR`: renders the capsule controls three ways and writes
/// each image to DIR, then prints how much ink sits in the outermost pixel columns of every
/// capsule (a flat end shows as a full-height column of ink):
/// 1. `ImageRenderer` (no window);
/// 2. an `NSHostingView` in a window that is never ordered in, captured with `cacheDisplay`;
/// 3. the same in a real window that is ordered in **off every display** (so nothing appears on
///    screen and nothing takes focus), captured with the view's own `cacheDisplay`.
/// No screen capture is used. The window is closed before the probe returns.
@MainActor
enum WindowProbe {
    static func run(into directory: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 520, height: 150)
        var report: [String] = []
        for (name, image) in [("image-renderer", imageRendered()),
                              ("unordered-window", windowRendered(size: size, ordered: false)),
                              ("ordered-window", windowRendered(size: size, ordered: true))] {
            guard let image else {
                report.append("\(name): could not render")
                continue
            }
            try? SnapshotRenderingEngine.writePNG(image, to: directory.appendingPathComponent("\(name).png"))
            report.append("\(name): \(endColumns(image))")
        }
        report.forEach { print($0) }
        return 0
    }

    /// A row of capsules on dark glass: the pop-up roles, the small size and the wind-down card.
    private static var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                PillButton("Start", role: .primary) {}
                PillButton("Not now", role: .secondary) {}
                PillButton("Undo", role: .secondary, size: .small) {}
                PillButton("Back to work", role: .mintPrimary) {}
            }
        }
        .padding(24)
        .frame(width: 520, height: 150, alignment: .topLeading)
        .background(Color(hex: 0x151A22))
        .environment(\.colorScheme, .dark)
        .glassRendering(.opaque)
    }

    private static func imageRendered() -> CGImage? {
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        return renderer.cgImage
    }

    private static func windowRendered(size: CGSize, ordered: Bool) -> CGImage? {
        let hosting = NSHostingView(rootView: sheet)
        // Far outside every display: an ordered window there is real but never visible.
        let origin = CGPoint(x: -40_000, y: -40_000)
        let window = NSWindow(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.ignoresMouseEvents = true
        if ordered { window.orderFrontRegardless() }
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage
    }

    /// For each capsule found on the first button row: the share of the button's height that is
    /// inked in its leftmost and rightmost columns. A round end inks a few pixels in its outermost
    /// column; a flat end inks most of the height.
    private static func endColumns(_ image: CGImage) -> String {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return "no pixels" }
        let width = image.width, height = image.height, stride = image.bytesPerRow, bpp = image.bitsPerPixel / 8
        func luminance(_ x: Int, _ y: Int) -> Int {
            let i = y * stride + x * bpp
            return (Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3
        }
        let background = luminance(2, 2)
        // The button row: rows 48…116 at 2x (24 pt padding, 34 pt buttons).
        let rows = (2 * 24)..<(2 * 24 + 2 * 34)
        func inked(_ x: Int) -> Int { rows.filter { abs(luminance(x, $0) - background) > 6 }.count }
        var spans: [(Int, Int)] = []
        var start: Int?
        for x in 0..<width {
            let ink = inked(x) > 0
            if ink, start == nil { start = x }
            if !ink, let s = start {
                if x - s > 20 { spans.append((s, x - 1)) }
                start = nil
            }
        }
        _ = height
        return spans.map { span in
            let left = Double(inked(span.0)) / Double(rows.count)
            let right = Double(inked(span.1)) / Double(rows.count)
            return String(format: "[%d–%d ends %.0f%%/%.0f%%]", span.0, span.1, left * 100, right * 100)
        }.joined(separator: " ")
    }
}
