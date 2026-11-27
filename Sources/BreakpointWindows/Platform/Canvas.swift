import CBreakpointWin32
import Foundation
import WinSDK

public struct PointF: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}

public struct SizeF: Equatable, Sendable {
    public var width: Float
    public var height: Float
    public init(width: Float, height: Float) { self.width = width; self.height = height }
}

public struct RectF: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public init(origin: PointF, size: SizeF) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public var minX: Float { x }
    public var minY: Float { y }
    public var maxX: Float { x + width }
    public var maxY: Float { y + height }
    public var midX: Float { x + width / 2 }
    public var midY: Float { y + height / 2 }
    public var size: SizeF { SizeF(width: width, height: height) }

    public func contains(_ p: PointF) -> Bool { p.x >= x && p.x < maxX && p.y >= y && p.y < maxY }
    public func insetBy(_ dx: Float, _ dy: Float) -> RectF { RectF(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy) }
    public func offsetBy(_ dx: Float, _ dy: Float) -> RectF { RectF(x: x + dx, y: y + dy, width: width, height: height) }
    func scaled(_ s: Float) -> RectF { RectF(x: x * s, y: y * s, width: width * s, height: height * s) }
    var integral: RectF {
        let left = x.rounded(.down), top = y.rounded(.down)
        return RectF(x: left, y: top, width: (maxX - left).rounded(.up), height: (maxY - top).rounded(.up))
    }
    var bp: BPRect { BPRect(x: x, y: y, width: width, height: height) }
}

/// A colour in sRGB with straight alpha.
public struct Colour: Equatable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float

    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Float = 1) {
        self.init(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, alpha)
    }

    public func opacity(_ alpha: Float) -> Colour { Colour(r, g, b, a * alpha) }

    /// Blends towards `other` by `t` (0…1).
    public func mixed(with other: Colour, _ t: Float) -> Colour {
        Colour(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
    }

    var bp: BPColor { BPColor(r: r, g: g, b: b, a: a) }

    public static let clear = Colour(0, 0, 0, 0)
    public static let white = Colour(1, 1, 1)
    public static let black = Colour(0, 0, 0)
}

/// Text style for `Canvas.text`.
public struct TextStyle: Hashable, Sendable {
    public var size: Float
    public var weight: Int
    public var monospacedDigits: Bool
    public var align: Align
    public var wrap: Bool
    public var italic: Bool
    public var family: String?

    public enum Align: Int, Sendable { case leading = 0, center = 1, trailing = 2 }

    public init(size: Float, weight: Int = 400, monospacedDigits: Bool = false, align: Align = .leading,
                wrap: Bool = false, italic: Bool = false, family: String? = nil) {
        self.size = size; self.weight = weight; self.monospacedDigits = monospacedDigits
        self.align = align; self.wrap = wrap; self.italic = italic; self.family = family
    }
}

/// A frame's drawing context (DIPs). Valid only inside a window's `draw`.
@MainActor
public struct Canvas {
    let surface: OpaquePointer?
    public let size: SizeF
    public let scale: Float

    public var bounds: RectF { RectF(x: 0, y: 0, width: size.width, height: size.height) }

    public func fill(_ rect: RectF, _ colour: Colour) { bp_fill_rect(surface, rect.bp, colour.bp) }
    public func fill(_ rect: RectF, radius: Float, _ colour: Colour) { bp_fill_rounded(surface, rect.bp, radius, colour.bp) }
    public func stroke(_ rect: RectF, radius: Float, width: Float, _ colour: Colour) {
        bp_stroke_rounded(surface, rect.bp, radius, width, colour.bp)
    }
    public func gradient(_ rect: RectF, radius: Float, from: Colour, to: Colour, angle: Float = 90) {
        bp_fill_rounded_gradient(surface, rect.bp, radius, from.bp, to.bp, angle)
    }
    public func circle(_ centre: PointF, radius: Float, _ colour: Colour) {
        bp_fill_ellipse(surface, centre.x, centre.y, radius, radius, colour.bp)
    }
    public func ellipse(_ centre: PointF, rx: Float, ry: Float, _ colour: Colour) {
        bp_fill_ellipse(surface, centre.x, centre.y, rx, ry, colour.bp)
    }
    public func ring(_ centre: PointF, radius: Float, width: Float, _ colour: Colour) {
        bp_stroke_ellipse(surface, centre.x, centre.y, radius, radius, width, colour.bp)
    }
    /// `from`…`to` in turns (0 = 12 o'clock, clockwise).
    public func arc(_ centre: PointF, radius: Float, from: Float, to: Float, width: Float, _ colour: Colour) {
        bp_stroke_arc(surface, centre.x, centre.y, radius, from, to, width, colour.bp)
    }
    public func line(_ a: PointF, _ b: PointF, width: Float, _ colour: Colour, round: Bool = true) {
        bp_line(surface, a.x, a.y, b.x, b.y, width, colour.bp, round ? 1 : 0)
    }
    public func glow(_ centre: PointF, rx: Float, ry: Float, _ colour: Colour) {
        bp_fill_radial(surface, centre.x, centre.y, rx, ry, colour.bp)
    }
    public func shadow(_ rect: RectF, radius: Float, blur: Float, offset: PointF = PointF(x: 0, y: 4), _ colour: Colour) {
        bp_shadow_rounded(surface, rect.bp, radius, blur, offset.x, offset.y, colour.bp)
    }
    /// A path: "M x y L x y C x1 y1 x2 y2 x y Z" as commands plus their numbers.
    public func path(_ commands: String, _ points: [Float], _ colour: Colour, stroke: Float = 0) {
        commands.withCString { command in
            points.withUnsafeBufferPointer { bp_path(surface, command, $0.baseAddress, Int32($0.count), colour.bp, stroke) }
        }
    }

    public func clipped(to rect: RectF, radius: Float, _ body: () -> Void) {
        bp_push_clip_rounded(surface, rect.bp, radius)
        body()
        bp_pop_clip(surface)
    }
    public func withOpacity(_ opacity: Float, _ body: () -> Void) {
        guard opacity < 0.999 else { return body() }
        guard opacity > 0.001 else { return }
        bp_push_opacity(surface, opacity)
        body()
        bp_pop_opacity(surface)
    }
    public func transformed(dx: Float = 0, dy: Float = 0, scale: Float = 1, about origin: PointF = PointF(x: 0, y: 0),
                            _ body: () -> Void) {
        bp_push_transform(surface, dx, dy, scale, origin.x, origin.y)
        body()
        bp_pop_transform(surface)
    }

    /// Draws `text` at `origin` (top left of its box), `width` wide (0 = its own width). Returns
    /// the size it took.
    @discardableResult
    public func text(_ text: String, at origin: PointF, width: Float = 0, style: TextStyle, _ colour: Colour) -> SizeF {
        let layout = TextCache.layout(text, style: style, width: width)
        guard let layout else { return SizeF(width: 0, height: 0) }
        bp_draw_text_layout(surface, layout.pointer, origin.x, origin.y, colour.bp)
        return layout.size
    }

    /// Text centred in `rect` vertically (and horizontally with `.center`).
    @discardableResult
    public func text(_ text: String, in rect: RectF, style: TextStyle, _ colour: Colour) -> SizeF {
        let size = Canvas.measure(text, style: style, width: rect.width)
        return self.text(text, at: PointF(x: rect.x, y: rect.y + (rect.height - size.height) / 2), width: rect.width,
                         style: style, colour)
    }

    public static func measure(_ text: String, style: TextStyle, width: Float = 0) -> SizeF {
        TextCache.layout(text, style: style, width: width)?.size ?? SizeF(width: 0, height: 0)
    }
}

/// Laid-out text, kept between frames (layout is the costly part of text). Bounded: the least
/// recently used layouts go first.
@MainActor
enum TextCache {
    final class Layout {
        let pointer: OpaquePointer
        let size: SizeF
        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
            let measured = bp_text_layout_size(pointer)
            size = SizeF(width: measured.width, height: measured.height)
        }
        deinit { bp_text_layout_release(pointer) }
    }

    struct Key: Hashable {
        let text: String
        let style: TextStyle
        let width: Float
    }

    private static var layouts: [Key: Layout] = [:]
    private static var order: [Key] = []
    private static let limit = 600

    static func layout(_ text: String, style: TextStyle, width: Float) -> Layout? {
        let key = Key(text: text, style: style, width: width)
        if let found = layouts[key] { return found }
        let utf16 = Array(text.utf16)
        let family = style.family.map { Array($0.utf16) + [0] }
        let made: OpaquePointer? = utf16.withUnsafeBufferPointer { chars in
            let call = { (familyPointer: UnsafePointer<UInt16>?) -> OpaquePointer? in
                let bpStyle = BPTextStyle(family: familyPointer, size: style.size, weight: Int32(style.weight),
                                          italic: style.italic ? 1 : 0, monospacedDigits: style.monospacedDigits ? 1 : 0,
                                          align: BPTextAlign(rawValue: Int32(style.align.rawValue)), wrap: style.wrap ? 1 : 0,
                                          lineSpacing: 0)
                return bp_text_layout(chars.baseAddress, Int32(chars.count), bpStyle, width)
            }
            if let family { return family.withUnsafeBufferPointer { call($0.baseAddress) } }
            return call(nil)
        }
        guard let made else { return nil }
        let layout = Layout(made)
        layouts[key] = layout
        order.append(key)
        if order.count > limit {
            let evicted = order.takeFirst(order.count - limit)
            for key in evicted { layouts[key] = nil }
        }
        return layout
    }
}

extension Array {
    /// Removes and returns the first `n` elements.
    mutating func takeFirst(_ n: Int) -> ArraySlice<Element> {
        let head = self[..<Swift.min(n, count)]
        removeSubrange(..<head.endIndex)
        return head
    }
}
