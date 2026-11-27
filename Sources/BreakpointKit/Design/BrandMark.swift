import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

/// The gutter-tag mark (SPEC §4.1): a rounded tag pointing right with two small oval eyes, set a
/// little above centre, on a 24-unit grid (the README's hero draws the same path,
/// docs/readme/src/kit.js); everything is drawn in code.
///
/// Parts are separate shapes so the menu bar (§3.7) can compose its states by **shape**:
/// - `.tag`: the tag silhouette. `.tagOutline` strokes it.
/// - `.pauseBars`: the two eyes (the name is historical: they were once two upright bars).
/// - `.notchBlock`: the rounded block around the eyes ("notch filled").
/// - `.restBar`: one horizontal bar (the paused state's "pause bar").
public struct BrandMarkShape: Shape {
    public enum Part: Sendable {
        case tag, pauseBars, notchBlock, restBar
    }

    public var part: Part
    /// A moment of one of the menu bar's movements (SPEC §3.7): only `.pauseBars` changes with it.
    public var pose: MarkPose

    public init(_ part: Part, pose: MarkPose = .rest) {
        self.part = part
        self.pose = pose
    }

    /// The mark's bounds on the 24-unit grid, with room for a 1.5-unit outline stroke.
    static let bounds = CGRect(x: 1.25, y: 5.25, width: 21.5, height: 13.5)

    /// Width ÷ height of the mark.
    public static var aspectRatio: CGFloat { bounds.width / bounds.height }

    /// Scale from grid units to points when the mark is fitted into `rect`.
    public static func scale(in rect: CGRect) -> CGFloat {
        min(rect.width / bounds.width, rect.height / bounds.height)
    }

    public func path(in rect: CGRect) -> Path {
        gridPath().applying(Self.transform(in: rect))
    }

    /// Grid units → points when the mark is fitted into `rect`.
    static func transform(in rect: CGRect) -> CGAffineTransform {
        let s = scale(in: rect)
        let origin = CGPoint(x: rect.midX - bounds.width * s / 2 - bounds.minX * s,
                             y: rect.midY - bounds.height * s / 2 - bounds.minY * s)
        return CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: s, y: s)
    }

    /// The centre of the notch (between the two eyes) in `rect`: where the settling dot goes.
    static func notchCentre(in rect: CGRect) -> CGPoint {
        CGPoint(x: 10, y: Eyes.centreY).applying(transform(in: rect))
    }

    /// The resting eyes on the grid: two 3 × 3.6 ovals 1.6 apart, centred across the tag and set
    /// 0.6 above its middle, as eyes sit in a face. (They replaced two 2 × 5.5 upright bars, which
    /// read as a pause button.)
    enum Eyes {
        static let width: CGFloat = 3
        static let height: CGFloat = 3.6
        static let gap: CGFloat = 1.6
        static let centreY: CGFloat = 11.4
        static var leftX: CGFloat { 10 - gap / 2 - width }
        static var rightX: CGFloat { 10 + gap / 2 }
    }

    /// The two eyes at `pose`, each drawn as a rounded rect with `eyeCorner` radii (an ellipse at
    /// rest). `barLift` makes both taller about their centre (the eyes widen); `fold` squashes them
    /// into two overlapping halves of the rest bar (x 6.5–10.5 and 9.5–13.5, 2 units high, centred
    /// on y 12), whose union is exactly `.restBar`.
    static func barRects(_ pose: MarkPose) -> [CGRect] {
        let f = CGFloat(min(1, max(0, pose.fold)))
        let lift = CGFloat(max(0, pose.barLift))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * f }
        let height = mix(Eyes.height, 2) + lift
        let y = mix(Eyes.centreY, 12) - height / 2
        let width = mix(Eyes.width, 4)
        return [CGRect(x: mix(Eyes.leftX, 6.5), y: y, width: width, height: height),
                CGRect(x: mix(Eyes.rightX, 9.5), y: y, width: width, height: height)]
    }

    /// Corner radii of an eye drawn in `bar` (circular corners): half its size (an ellipse) at rest, easing to the rest
    /// bar's 1-unit round ends as it folds.
    static func eyeCorner(_ bar: CGRect, fold: Double) -> CGSize {
        let f = CGFloat(min(1, max(0, fold)))
        return CGSize(width: bar.width / 2 + (1 - bar.width / 2) * f,
                      height: bar.height / 2 + (1 - bar.height / 2) * f)
    }

    private func gridPath() -> Path {
        switch part {
        case .tag:
            // M5 6h9.6c.5 0 1 .2 1.3.6l5.3 4.5c.5.5.5 1.3 0 1.8l-5.3 4.5c-.3.4-.8.6-1.3.6H5
            // a3 3 0 0 1-3-3V9a3 3 0 0 1 3-3z
            var p = Path()
            p.move(to: CGPoint(x: 5, y: 6))
            p.addLine(to: CGPoint(x: 14.6, y: 6))
            p.addCurve(to: CGPoint(x: 15.9, y: 6.6), control1: CGPoint(x: 15.1, y: 6), control2: CGPoint(x: 15.6, y: 6.2))
            p.addLine(to: CGPoint(x: 21.2, y: 11.1))
            p.addCurve(to: CGPoint(x: 21.2, y: 12.9), control1: CGPoint(x: 21.7, y: 11.6), control2: CGPoint(x: 21.7, y: 12.4))
            p.addLine(to: CGPoint(x: 15.9, y: 17.4))
            p.addCurve(to: CGPoint(x: 14.6, y: 18), control1: CGPoint(x: 15.6, y: 17.8), control2: CGPoint(x: 15.1, y: 18))
            p.addLine(to: CGPoint(x: 5, y: 18))
            p.addArc(center: CGPoint(x: 5, y: 15), radius: 3, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: 2, y: 9))
            p.addArc(center: CGPoint(x: 5, y: 9), radius: 3, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.closeSubpath()
            return p
        case .pauseBars:
            var p = Path()
            for bar in Self.barRects(pose) {
                p.addRoundedRect(in: bar, cornerSize: Self.eyeCorner(bar, fold: pose.fold), style: .circular)
            }
            return p
        case .notchBlock:
            return Path(roundedRect: CGRect(x: 5.25, y: 7.75, width: 9.5, height: 8.5),
                        cornerSize: CGSize(width: 2.25, height: 2.25), style: .continuous)
        case .restBar:
            return Path(roundedRect: CGRect(x: 6.5, y: 11, width: 7, height: 2), cornerSize: CGSize(width: 1, height: 1))
        }
    }
}

/// The mark as a view, in one of the states of SPEC §3.7 (plus `.brand` for icons and onboarding).
/// Draws in the current foreground style; use `.foregroundStyle` to colour it.
public struct BrandMark: View {
    /// How the mark is drawn (declared in BreakpointRuntime, where `AppState` uses it).
    public typealias Variant = MarkVariant

    /// The menu-bar badge layer (declared in BreakpointRuntime, where `AppState` uses it).
    public typealias Badge = MarkBadge

    private let variant: Variant
    private let badge: Badge
    private let badgeOpacity: Double
    private let pose: MarkPose

    public init(_ variant: Variant = .brand, badge: Badge = .none, badgeOpacity: Double = 1, pose: MarkPose = .rest) {
        self.variant = variant
        self.badge = badge
        self.badgeOpacity = badgeOpacity
        self.pose = pose
    }

    public var body: some View {
        ZStack {
            BrandMarkGlyph(variant: variant, badge: badge, pose: pose).fill(style: FillStyle(eoFill: false))
            if badge == .working {
                BrandMarkGlyph.BadgeDot(pose: pose).opacity(badgeOpacity)
            }
        }
        .aspectRatio(BrandMarkShape.aspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// One `Path` for a mark state and badge, built with path boolean operations (no blend modes),
/// so it renders identically in windows, `ImageRenderer` and template images. The working dot is
/// separate (`BadgeDot`) so its opacity can breathe.
public struct BrandMarkGlyph: Shape {
    public var variant: BrandMark.Variant
    public var badge: BrandMark.Badge
    /// A moment of a menu-bar movement: taller eyes (`lift`), eyes folding into the rest bar
    /// (`fold`), or the working dot settling into the notch (`settle`).
    public var pose: MarkPose

    public init(variant: BrandMark.Variant, badge: BrandMark.Badge = .none, pose: MarkPose = .rest) {
        self.variant = variant
        self.badge = badge
        self.pose = pose
    }

    public func path(in rect: CGRect) -> Path {
        let s = BrandMarkShape.scale(in: rect)
        let tag = BrandMarkShape(.tag).path(in: rect)
        let bars = BrandMarkShape(.pauseBars, pose: pose).path(in: rect)
        let outline = tag.strokedPath(StrokeStyle(lineWidth: 1.5 * s, lineJoin: .round))
        var glyph: Path
        switch variant {
        case .brand, .onBreak:
            glyph = tag.subtracting(bars)
        case .idle:
            glyph = outline.union(bars)
        case .due:
            glyph = outline.union(BrandMarkShape(.notchBlock).path(in: rect).subtracting(bars))
        case .paused:
            glyph = outline.union(BrandMarkShape(.restBar).path(in: rect))
        }
        guard badge != .none else { return glyph }
        let (centre, diameter) = Self.badgeGeometry(in: rect, pose: badge == .working ? pose : .rest)
        guard diameter > 0.01 else { return glyph }
        // The halo shrinks with a settling dot, so the eyes it passes over are only nicked.
        let halo = diameter + 3 * s * CGFloat(min(1, max(0, pose.dotScale)))
        glyph = glyph.subtracting(Path(ellipseIn: CGRect(x: centre.x - halo / 2, y: centre.y - halo / 2, width: halo, height: halo)))
        if badge == .needsYou {
            let ring = Path(ellipseIn: CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter))
                .insetRing(lineWidth: 1.5 * s)
            glyph = glyph.union(ring)
        }
        return glyph
    }

    /// The badge's centre and diameter. The working dot moves with `pose`: from its corner toward
    /// the notch (`dotTravel`) while it shrinks (`dotScale`).
    static func badgeGeometry(in rect: CGRect, pose: MarkPose = .rest) -> (centre: CGPoint, diameter: CGFloat) {
        let s = BrandMarkShape.scale(in: rect)
        let rest = 6.5 * s
        let corner = CGPoint(x: rect.maxX - rest / 2, y: rect.maxY - rest / 2)
        let notch = BrandMarkShape.notchCentre(in: rect)
        let t = CGFloat(min(1, max(0, pose.dotTravel)))
        let centre = CGPoint(x: corner.x + (notch.x - corner.x) * t, y: corner.y + (notch.y - corner.y) * t)
        return (centre, rest * CGFloat(min(1, max(0, pose.dotScale))))
    }

    /// The working badge's filled dot.
    public struct BadgeDot: Shape {
        public var pose: MarkPose
        public init(pose: MarkPose = .rest) { self.pose = pose }
        public func path(in rect: CGRect) -> Path {
            let (centre, d) = BrandMarkGlyph.badgeGeometry(in: rect, pose: pose)
            guard d > 0.01 else { return Path() }
            return Path(ellipseIn: CGRect(x: centre.x - d / 2, y: centre.y - d / 2, width: d, height: d))
        }
    }
}

private extension Path {
    /// The ring of `lineWidth` inside this (circular) path's edge.
    func insetRing(lineWidth: CGFloat) -> Path {
        let r = boundingRect
        let inner = Path(ellipseIn: r.insetBy(dx: lineWidth, dy: lineWidth))
        return subtracting(inner)
    }
}

extension BrandMark {
    /// A template image of the mark for `NSStatusItem` (§3.7), `pointHeight` tall, rendered at 2×.
    /// The width follows the mark's aspect ratio (plus room for the badge).
    @MainActor
    public static func templateImage(_ variant: Variant, badge: Badge = .none, badgeOpacity: Double = 1,
                                     pose: MarkPose = .rest,
                                     pointHeight: CGFloat = Theme.Layout.menuBarMark) -> NSImage {
        let markHeight = pointHeight * 0.72
        let size = CGSize(width: (markHeight * BrandMarkShape.aspectRatio).rounded(.up) + 1, height: pointHeight)
        let view = BrandMark(variant, badge: badge, badgeOpacity: badgeOpacity, pose: pose)
            .foregroundStyle(Color.black)
            .frame(width: size.width, height: markHeight)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: size)
        image.size = size
        image.isTemplate = true
        image.accessibilityDescription = "Breakpoint"
        return image
    }
}
