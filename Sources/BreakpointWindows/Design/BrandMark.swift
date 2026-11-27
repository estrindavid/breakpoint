import BreakpointCore
import CBreakpointWin32
import Foundation
import WinSDK

/// The gutter-tag mark (SPEC §4.1), drawn from the same 24-unit grid as the macOS
/// `BrandMarkShape` (and the README's hero): a rounded tag pointing right with two oval eyes.
/// Parts are separate so the tray icon composes its states by shape (§3.7).
@MainActor
public enum BrandMark {
    public enum Part { case tag, tagOutline, eyes, notchBlock, restBar }

    /// The mark's bounds on the grid, with room for a 1.5-unit outline stroke.
    static let bounds = RectF(x: 1.25, y: 5.25, width: 21.5, height: 13.5)

    /// Draws `part` fitted into `rect`.
    public static func draw(_ part: Part, in rect: RectF, on canvas: Canvas, _ colour: Colour, pose: MarkPose = .rest) {
        let s = min(rect.width / bounds.width, rect.height / bounds.height)
        let ox = rect.midX - bounds.width * s / 2 - bounds.minX * s
        let oy = rect.midY - bounds.height * s / 2 - bounds.minY * s
        func p(_ x: Float, _ y: Float) -> [Float] { [ox + x * s, oy + y * s] }
        switch part {
        case .tag, .tagOutline:
            // M5 6h9.6c.5 0 1 .2 1.3.6l5.3 4.5c.5.5.5 1.3 0 1.8l-5.3 4.5c-.3.4-.8.6-1.3.6H5
            // a3 3 0 0 1-3-3V9a3 3 0 0 1 3-3z  (quarter arcs as cubic curves, k = 0.5523)
            let k: Float = 3 * 0.5523
            let points = p(5, 6) + p(14.6, 6)
                + p(15.1, 6) + p(15.6, 6.2) + p(15.9, 6.6)
                + p(21.2, 11.1)
                + p(21.7, 11.6) + p(21.7, 12.4) + p(21.2, 12.9)
                + p(15.9, 17.4)
                + p(15.6, 17.8) + p(15.1, 18) + p(14.6, 18)
                + p(5, 18)
                + p(5 - k, 18) + p(2, 15 + k) + p(2, 15)
                + p(2, 9)
                + p(2, 9 - k) + p(5 - k, 6) + p(5, 6)
            canvas.path("MLCLCLCLCLCZ", points, colour, stroke: part == .tagOutline ? 1.5 * s : 0)
        case .eyes:
            for eye in eyeRects(pose) {
                let r = RectF(x: ox + eye.x * s, y: oy + eye.y * s, width: eye.width * s, height: eye.height * s)
                let fold = Float(min(1, max(0, pose.fold)))
                let radius = (min(r.width, r.height) / 2) * (1 - fold) + s * fold
                canvas.fill(r, radius: radius, colour)
            }
        case .notchBlock:
            canvas.fill(RectF(x: ox + 5.25 * s, y: oy + 7.75 * s, width: 9.5 * s, height: 8.5 * s), radius: 2.25 * s, colour)
        case .restBar:
            canvas.fill(RectF(x: ox + 6.5 * s, y: oy + 11 * s, width: 7 * s, height: 2 * s), radius: s, colour)
        }
    }

    /// The two eyes at `pose` (as `BrandMarkShape.barRects` on macOS): 3 × 3.6 ovals 1.6 apart,
    /// lifted by `barLift`, folding into the rest bar with `fold`.
    static func eyeRects(_ pose: MarkPose) -> [RectF] {
        let f = Float(min(1, max(0, pose.fold)))
        let lift = Float(max(0, pose.barLift))
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * f }
        let height = mix(3.6, 2) + lift
        let y = mix(11.4, 12) - height / 2
        let width = mix(3, 4)
        return [RectF(x: mix(10 - 0.8 - 3, 6.5), y: y, width: width, height: height),
                RectF(x: mix(10 + 0.8, 9.5), y: y, width: width, height: height)]
    }

    /// The whole mark: a filled tag with the eyes cut out in `background` (or punched through
    /// when `background` is clear, by drawing them in the tag's own surroundings).
    public static func drawMark(in rect: RectF, on canvas: Canvas, tag: Colour, eyes: Colour, pose: MarkPose = .rest) {
        draw(.tag, in: rect, on: canvas, tag)
        draw(.eyes, in: rect, on: canvas, eyes, pose: pose)
    }
}

/// The app's icon (window title bars, the taskbar while Settings is open, the installer), drawn
/// in code like the macOS one: the mark in the brand mint on a dark rounded square.
@MainActor
public enum AppIcon {
    public static let large: HICON? = make(size: Int(GetSystemMetrics(SM_CXICON)) * 2)
    public static let small: HICON? = make(size: Int(GetSystemMetrics(SM_CXSMICON)) * 2)

    static func make(size: Int) -> HICON? {
        let drawer: BPIconDrawer = { surface, _ in
            MainActor.assumeIsolated { AppIcon.draw(on: surface) }
        }
        drawingSize = size
        return bp_make_icon(Int32(size), drawer, nil).map { HICON($0.assumingMemoryBound(to: HICON__.self)) }
    }

    /// The icon at `drawingSize`: the mark in mint on a dark rounded square with a faint brand glow.
    static func draw(on surface: OpaquePointer?) {
        let side = Float(drawingSize)
        let canvas = Canvas(surface: surface, size: SizeF(width: side, height: side), scale: 1)
        let tile = RectF(x: 0, y: 0, width: side, height: side).insetBy(side * 0.04, side * 0.04)
        canvas.fill(tile, radius: side * 0.22, Theme.Palette.solidOverlay)
        canvas.gradient(tile, radius: side * 0.22, from: Theme.Palette.indigo.opacity(0.22), to: Theme.Palette.mint.opacity(0.08), angle: 60)
        BrandMark.drawMark(in: tile.insetBy(side * 0.12, side * 0.12), on: canvas, tag: Theme.Palette.mint, eyes: Theme.Palette.solidOverlay)
    }

    /// The size of the icon being drawn (the C callback carries no context).
    nonisolated(unsafe) static var drawingSize = 32
}

extension AppIcon {
    /// Writes the icon as a .ico with the sizes Windows asks for (Start menu, taskbar, Explorer),
    /// each drawn at its own size from the same code as the window icon.
    public static func writeICO(to url: URL) throws {
        let sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
        var images: [[UInt8]] = []
        for size in sizes {
            drawingSize = size
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            let drawer: BPIconDrawer = { surface, _ in
                MainActor.assumeIsolated { AppIcon.draw(on: surface) }
            }
            guard bp_render_pixels(Int32(size), Int32(size), 1, drawer, nil, &pixels) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            images.append(dib(size: size, premultiplied: pixels))
        }
        var data = Data()
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        le16(0); le16(1); le16(sizes.count)
        var offset = 6 + 16 * sizes.count
        for (size, image) in zip(sizes, images) {
            data.append(UInt8(size >= 256 ? 0 : size)); data.append(UInt8(size >= 256 ? 0 : size))
            data.append(0); data.append(0); le16(1); le16(32); le32(image.count); le32(offset)
            offset += image.count
        }
        for image in images { data.append(contentsOf: image) }
        try data.write(to: url)
    }

    /// One icon image: a BITMAPINFOHEADER (double height), bottom-up straight-alpha BGRA, and an
    /// all-clear AND mask.
    private static func dib(size: Int, premultiplied pixels: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        le32(40); le32(size); le32(size * 2); le16(1); le16(32); le32(0); le32(size * size * 4); le32(0); le32(0); le32(0); le32(0)
        for row in (0..<size).reversed() {
            for column in 0..<size {
                let i = (row * size + column) * 4
                let a = pixels[i + 3]
                func straight(_ c: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, Int(c) * 255 / Int(a))) }
                out.append(straight(pixels[i])); out.append(straight(pixels[i + 1])); out.append(straight(pixels[i + 2])); out.append(a)
            }
        }
        let maskRow = ((size + 31) / 32) * 4
        out.append(contentsOf: [UInt8](repeating: 0, count: maskRow * size))
        return out
    }
}
