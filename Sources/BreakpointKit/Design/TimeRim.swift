import SwiftUI
import BreakpointCore

// The time rim (SPEC §3.5, §4.6): a self-dismissing card's lit edge is its timer.
//
// A brighter line runs just inside the card's glass rim, centred on the top edge. It draws itself out from
// the top centre as the card arrives, then draws back toward the top centre at the card's own
// pace, so the card visibly runs out before it drifts away. With the pointer on the card it stops
// and brightens a little (held); when the pointer leaves it eases back up to what the card has left
// (at least half, `Timing.cardHoverResumeFloor`) and carries on. Under Reduce Motion the line
// never moves along the edge: the whole rim stays lit and fades instead.

extension Theme.Glass {
    /// The time rim's line (§3.5).
    public enum TimeRim {
        /// Width of the lit line.
        public static let width: CGFloat = 1.5
        /// The line runs this far inside the card's edge, just within the glass rim, so a dark
        /// hairline of glass separates it from whatever is behind the card (it stays legible on a
        /// white window as well as a dark one).
        public static let inset: CGFloat = 2
        /// White opacity of the line while running / while held (pointer on the card).
        public static let opacity: Double = 0.45
        public static let heldOpacity: Double = 0.70
        /// Under Increase Contrast.
        public static let opacityIncreasedContrast: Double = 0.80
        public static let heldOpacityIncreasedContrast: Double = 1.0
        /// The line's two ends fade over about this many points.
        public static let endSoftness: CGFloat = 1.5
        /// The drawn line under this fraction of the perimeter is not drawn at all.
        public static let minimumFraction: Double = 0.002
    }
}

extension Theme.Motion {
    /// Time rim: the line eases up to what the card has left (arrival, pointer leaving), ease-out.
    public static let timeRimRefill: TimeInterval = 0.45
    /// Time rim: held brightening and its release, 0.2 s.
    public static let timeRimHeld = Animation.easeOut(duration: 0.2)
    /// Time rim: redraws at most this often while it runs.
    public static let timeRimFrameInterval: TimeInterval = 1.0 / 30
}

/// What the rim shows at one moment: the share of the edge still lit, and whether it is held.
public struct TimeRimFrame: Equatable, Sendable {
    public var fraction: Double
    public var held: Bool

    public init(fraction: Double, held: Bool = false) {
        self.fraction = min(1, max(0, fraction))
        self.held = held
    }
}

/// A live rim: the card's countdown plus an optional refill, a short ease from `refillFrom` up to
/// the countdown (the rim drawing itself out on arrival, or easing back up when the pointer
/// leaves). A pure function of time, so the film and the app draw the same frames.
public struct TimeRimTimeline: Equatable, Sendable {
    public var countdown: CardCountdown
    public var refillFrom: Double?
    public var refillStart: Date?

    public init(countdown: CardCountdown, refillFrom: Double? = nil, refillStart: Date? = nil) {
        self.countdown = countdown
        self.refillFrom = refillFrom
        self.refillStart = refillStart
    }

    /// A rim for a card that just appeared: drawn out from nothing.
    public static func arriving(_ countdown: CardCountdown, at date: Date) -> TimeRimTimeline {
        TimeRimTimeline(countdown: countdown, refillFrom: 0, refillStart: date)
    }

    /// The pointer came onto the card at `date`.
    public func held(at date: Date) -> TimeRimTimeline {
        TimeRimTimeline(countdown: countdown.held(at: date))
    }

    /// The pointer left the card at `date`: the countdown resumes (topped up to the floor) and the
    /// line eases up from where it was drawn.
    public func resumed(at date: Date, reduceMotion: Bool) -> TimeRimTimeline {
        let drawn = frame(at: date, reduceMotion: reduceMotion).fraction
        let next = countdown.resumed(at: date)
        guard next.fraction(at: date) > drawn + 0.001 else { return TimeRimTimeline(countdown: next) }
        return TimeRimTimeline(countdown: next, refillFrom: drawn, refillStart: date)
    }

    static func refillDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? Theme.Motion.reduceMotionFade : Theme.Motion.timeRimRefill
    }

    public func frame(at date: Date, reduceMotion: Bool) -> TimeRimFrame {
        let live = countdown.fraction(at: date)
        guard let from = refillFrom, let start = refillStart else {
            return TimeRimFrame(fraction: live, held: countdown.isHeld)
        }
        let progress = date.timeIntervalSince(start) / Self.refillDuration(reduceMotion: reduceMotion)
        guard progress < 1 else { return TimeRimFrame(fraction: live, held: countdown.isHeld) }
        let t = max(0, progress)
        let eased = 1 - pow(1 - t, 3)                        // ease-out cubic
        return TimeRimFrame(fraction: from + (live - from) * eased, held: countdown.isHeld)
    }

    /// The rim changes with time (running, or easing up); a held rim is still.
    public var isMoving: Bool { !countdown.isHeld }
}

/// Where a card's rim comes from: the app's live countdown, or a fixed frame (snapshots, film).
public enum TimeRimSource: Equatable, Sendable {
    case live(TimeRimTimeline)
    case still(TimeRimFrame)
}

extension View {
    /// Lays the time rim over a card whose glass is a continuous rounded rectangle of `cornerRadius`.
    public func timeRim(_ source: TimeRimSource?, cornerRadius: CGFloat) -> some View {
        overlay {
            if let source {
                TimeRimView(source: source, shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                            cornerRadius: cornerRadius)
            }
        }
    }

    /// Lays the time rim over a capsule card (away note, toasts).
    public func capsuleTimeRim(_ source: TimeRimSource?) -> some View {
        overlay {
            if let source {
                TimeRimView(source: source, shape: Capsule(style: .circular), cornerRadius: nil)
            }
        }
    }
}

/// Draws a `TimeRimSource`, running a clock only while a live rim moves.
struct TimeRimView<S: InsettableShape>: View {
    let source: TimeRimSource
    let shape: S
    let cornerRadius: CGFloat?
    private let traits = DesignTraits()

    var body: some View {
        Group {
            switch source {
            case .still(let frame):
                TimeRimLine(shape: shape, cornerRadius: cornerRadius, frame: frame)
            case .live(let timeline):
                TimelineView(.animation(minimumInterval: Theme.Motion.timeRimFrameInterval, paused: !timeline.isMoving)) { context in
                    TimeRimLine(shape: shape, cornerRadius: cornerRadius,
                                frame: timeline.frame(at: context.date, reduceMotion: traits.reduceMotion))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One frame of the rim: the lit line on the glass rim, trimmed symmetrically about the top centre
/// (or, under Reduce Motion, whole and faded by the fraction).
struct TimeRimLine<S: InsettableShape>: View {
    let shape: S
    let cornerRadius: CGFloat?
    let frame: TimeRimFrame
    private let traits = DesignTraits()

    var body: some View {
        let f = frame.fraction
        let visible = f >= Theme.Glass.TimeRim.minimumFraction
        shape.inset(by: Theme.Glass.TimeRim.inset)
            .strokeBorder(Color.white.opacity(lineOpacity), lineWidth: Theme.Glass.TimeRim.width)
            .opacity(traits.reduceMotion ? f : (visible ? 1 : 0))
            .mask {
                if traits.reduceMotion {
                    Rectangle()
                } else {
                    RimSweepPath(cornerRadius: cornerRadius, inset: Theme.Glass.TimeRim.inset + Theme.Glass.TimeRim.width / 2)
                        .trim(from: (1 - f) / 2, to: (1 + f) / 2)
                        .stroke(style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                        .blur(radius: Theme.Glass.TimeRim.endSoftness)
                }
            }
            .animation(Theme.Motion.timeRimHeld, value: frame.held)
    }

    private var lineOpacity: Double {
        typealias R = Theme.Glass.TimeRim
        if traits.increaseContrast { return frame.held ? R.heldOpacityIncreasedContrast : R.opacityIncreasedContrast }
        return frame.held ? R.heldOpacity : R.opacity
    }
}

/// The card's outline as one path that starts and ends at the bottom centre and runs round through
/// the top centre, so a trim symmetric about 0.5 is a line centred on the top edge. Circular
/// corners of `cornerRadius` (a capsule when `nil`); it only shapes the mask, the line itself is
/// the card's own shape.
struct RimSweepPath: Shape {
    let cornerRadius: CGFloat?
    let inset: CGFloat

    func path(in bounds: CGRect) -> Path {
        let r = bounds.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        let radius = max(0, min(cornerRadius.map { $0 - inset } ?? r.height / 2, min(r.width, r.height) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.midX, y: r.maxY), radius: radius)
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}
