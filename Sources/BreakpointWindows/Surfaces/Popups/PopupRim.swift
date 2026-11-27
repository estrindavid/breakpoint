import BreakpointCore
import BreakpointRuntime
import Foundation

// The time rim (SPEC §3.5, §4.6), as `TimeRim.swift` draws it on the Mac: a self-dismissing
// card's lit edge is its timer. A brighter line runs just inside the window's edge, centred on
// the top edge; it draws itself out from the top centre as the card arrives and back toward it at
// the card's own pace. Held (pointer on the card) it stops and brightens; when the pointer leaves
// it eases back up to what the card has left (at least half) and carries on. Under Reduce Motion
// the line never travels: the whole rim stays lit and fades instead.

/// What the rim shows at one moment.
struct PopupRimFrame: Equatable {
    var fraction: Double
    var held: Bool

    init(fraction: Double, held: Bool = false) {
        self.fraction = min(1, max(0, fraction))
        self.held = held
    }
}

/// A live rim: the card's countdown plus an optional refill (an ease-out from `refillFrom` up to
/// the countdown). A pure function of time (`TimeRimTimeline`).
struct PopupRimTimeline: Equatable {
    var countdown: CardCountdown
    var refillFrom: Double?
    var refillStart: Date?

    static let refill: TimeInterval = 0.45
    static let reduceMotionFade: TimeInterval = 0.2

    static func arriving(_ countdown: CardCountdown, at date: Date) -> PopupRimTimeline {
        PopupRimTimeline(countdown: countdown, refillFrom: 0, refillStart: date)
    }

    func held(at date: Date) -> PopupRimTimeline {
        PopupRimTimeline(countdown: countdown.held(at: date))
    }

    func resumed(at date: Date, reduceMotion: Bool) -> PopupRimTimeline {
        let drawn = frame(at: date, reduceMotion: reduceMotion).fraction
        let next = countdown.resumed(at: date)
        guard next.fraction(at: date) > drawn + 0.001 else { return PopupRimTimeline(countdown: next) }
        return PopupRimTimeline(countdown: next, refillFrom: drawn, refillStart: date)
    }

    func frame(at date: Date, reduceMotion: Bool) -> PopupRimFrame {
        let live = countdown.fraction(at: date)
        guard let from = refillFrom, let start = refillStart else { return PopupRimFrame(fraction: live, held: countdown.isHeld) }
        let progress = date.timeIntervalSince(start) / (reduceMotion ? Self.reduceMotionFade : Self.refill)
        guard progress < 1 else { return PopupRimFrame(fraction: live, held: countdown.isHeld) }
        let t = max(0, progress)
        let eased = 1 - pow(1 - t, 3)
        return PopupRimFrame(fraction: from + (live - from) * eased, held: countdown.isHeld)
    }

    /// The rim changes with time; a held rim is still.
    var isMoving: Bool { !countdown.isHeld }
}

@MainActor
enum PopupRim {
    static let width: Float = 1.5
    static let inset: Float = 2

    /// Draws `frame` on the edge of `rect` (the card), whose corners are `radius`.
    static func draw(_ canvas: Canvas, _ rect: RectF, radius: Float, frame: PopupRimFrame) {
        let contrast = Appearance.highContrast
        let opacity: Float = frame.held ? (contrast ? 1.0 : 0.70) : (contrast ? 0.80 : 0.45)
        let path = rect.insetBy(inset + width / 2, inset + width / 2)
        let r = max(0, min(radius - inset, path.height / 2, path.width / 2))
        if Appearance.reduceMotion {
            guard frame.fraction > 0.002 else { return }
            canvas.stroke(path, radius: r, width: width, Colour.white.opacity(opacity * Float(frame.fraction)))
            return
        }
        guard frame.fraction >= 0.002 else { return }
        let outline = Outline(rect: path, radius: r)
        let half = Float(frame.fraction) * outline.perimeter / 2
        let points = outline.points(from: -half, to: half)
        guard points.count >= 4 else { return }
        let commands = "M" + String(repeating: "L", count: points.count / 2 - 1)
        canvas.path(commands, points, Colour.white.opacity(opacity), stroke: width)
    }

    /// The rounded outline as one path measured from the top centre, clockwise.
    private struct Outline {
        let rect: RectF
        let radius: Float
        let segments: [(length: Float, point: (Float) -> PointF)]

        init(rect: RectF, radius: Float) {
            self.rect = rect
            self.radius = radius
            let r = radius
            let straightTop = rect.width / 2 - r
            let side = rect.height - 2 * r
            let bottom = rect.width - 2 * r
            let arc = Float.pi / 2 * r
            func corner(_ cx: Float, _ cy: Float, _ start: Float) -> (Float) -> PointF {
                { t in
                    let angle = start + (t / max(arc, 0.0001)) * Float.pi / 2
                    return PointF(x: cx + r * cos(angle), y: cy + r * sin(angle))
                }
            }
            let (l, t, rr, b) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
            segments = [
                (straightTop, { s in PointF(x: rect.midX + s, y: t) }),
                (arc, corner(rr - r, t + r, -Float.pi / 2)),
                (side, { s in PointF(x: rr, y: t + r + s) }),
                (arc, corner(rr - r, b - r, 0)),
                (bottom, { s in PointF(x: rr - r - s, y: b) }),
                (arc, corner(l + r, b - r, Float.pi / 2)),
                (side, { s in PointF(x: l, y: b - r - s) }),
                (arc, corner(l + r, t + r, Float.pi)),
                (straightTop, { s in PointF(x: l + r + s, y: t) }),
            ]
        }

        var perimeter: Float { segments.reduce(0) { $0 + $1.length } }

        func point(at s: Float) -> PointF {
            var s = s.truncatingRemainder(dividingBy: perimeter)
            if s < 0 { s += perimeter }
            for segment in segments {
                if s <= segment.length { return segment.point(s) }
                s -= segment.length
            }
            return segments.last.map { $0.point($0.length) } ?? PointF(x: rect.midX, y: rect.minY)
        }

        /// Points along the outline from `a` to `b` (arc lengths, negative = anticlockwise of the
        /// top centre): every corner sampled every few degrees, straight runs by their ends.
        func points(from a: Float, to b: Float) -> [Float] {
            var stops: [Float] = [a]
            var start: Float = -perimeter
            // Segment boundaries over two laps cover any range within ±perimeter.
            for _ in 0..<2 {
                for segment in segments {
                    let isArc = segment.length > 0 && abs(segment.length - Float.pi / 2 * radius) < 0.001 && radius > 0
                    if isArc {
                        let steps = 8
                        for i in 0...steps {
                            let s = start + segment.length * Float(i) / Float(steps)
                            if s > a && s < b { stops.append(s) }
                        }
                    } else if start > a && start < b {
                        stops.append(start)
                    }
                    start += segment.length
                }
            }
            stops.append(b)
            stops.sort()
            var result: [Float] = []
            result.reserveCapacity(stops.count * 2)
            for s in stops {
                let p = point(at: s)
                result.append(p.x)
                result.append(p.y)
            }
            return result
        }
    }
}
