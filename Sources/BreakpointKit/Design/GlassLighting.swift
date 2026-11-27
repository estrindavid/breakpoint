import SwiftUI
import BreakpointRuntime

// The hand-built glass's light (SPEC §4.5), for macOS 14 and 15 and every snapshot. macOS 26
// uses the system Liquid Glass instead (`SystemGlass`). Everything here is still: no animation,
// no pointer tracking, so it costs nothing after the first frame.

/// The 12% black tint over the material, clearing towards the rim so the edge of the slab shows
/// more of what is behind it while text in the middle keeps its contrast. Under Increase Contrast
/// the tint stays even.
struct GlassTint<S: InsettableShape>: View {
    let shape: S
    private let traits = DesignTraits()

    var body: some View {
        let band = Theme.Glass.edgeBand
        shape.fill(Color.black.opacity(Theme.Glass.tint))
            .mask {
                ZStack {
                    shape.fill(Color.white.opacity(traits.increaseContrast ? 1 : Theme.Glass.edgeTintFraction))
                    shape.inset(by: band / 2).fill(Color.white).blur(radius: band / 2)
                }
            }
            .allowsHitTesting(false)
    }
}

/// Light on the glass: a soft band of gathered light just inside the rim (brighter at the top),
/// a still sheen from the top-leading corner and a thin shade inside the bottom rim, so the
/// surface reads as a thick, polished slab. Draw it between the fill and the rim.
struct GlassLighting<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        let band = Theme.Glass.edgeBand
        ZStack {
            // Gathered light: added to what is behind, so over a warm desktop the edge glows warm.
            shape.strokeBorder(
                LinearGradient(stops: [
                    .init(color: .white.opacity(Theme.Glass.edgeLightTop), location: 0),
                    .init(color: .white.opacity(Theme.Glass.edgeLightBottom), location: 0.6),
                    .init(color: .white.opacity(Theme.Glass.edgeLightBottom), location: 1),
                ], startPoint: .top, endPoint: .bottom),
                lineWidth: band)
                .blur(radius: band / 2)
                .blendMode(.plusLighter)
            // Sheen.
            shape.fill(LinearGradient(stops: [
                .init(color: .white.opacity(Theme.Glass.sheen), location: 0),
                .init(color: .white.opacity(Theme.Glass.sheen * 0.35), location: 0.3),
                .init(color: .white.opacity(0), location: 0.55),
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            .blendMode(.plusLighter)
            // Glint: the rim's highlight spread a little inwards, where the light is strongest.
            shape.strokeBorder(GlassLighting.rimStyle, lineWidth: 3)
                .blur(radius: 2)
                .opacity(Theme.Glass.glint)
                .blendMode(.plusLighter)
            // Shade on the inside of the bottom rim.
            shape.inset(by: 1).strokeBorder(LinearGradient(stops: [
                .init(color: .black.opacity(0), location: 0.45),
                .init(color: .black.opacity(Theme.Glass.innerShade), location: 1),
            ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }

    /// The 1 pt rim: brightest where the light from the top-leading corner meets the edge, a
    /// fainter counter-highlight on the bottom-trailing edge, the plain 10% rim on the sides.
    static var rimStyle: AnyShapeStyle {
        let side = Theme.Glass.rim
        let high = Theme.Glass.rimHighlight
        let counter = Theme.Glass.rimCounterHighlight
        // Angles run clockwise from the trailing edge (0) through the bottom (0.25), the leading
        // edge (0.5) and the top (0.75).
        return AnyShapeStyle(AngularGradient(stops: [
            .init(color: .white.opacity(side), location: 0),
            .init(color: .white.opacity(counter), location: 0.12),
            .init(color: .white.opacity(side), location: 0.25),
            .init(color: .white.opacity(side * 0.8), location: 0.42),
            .init(color: .white.opacity(Theme.Glass.rimTop), location: 0.52),
            .init(color: .white.opacity(high), location: 0.63),
            .init(color: .white.opacity(Theme.Glass.rimTop + 0.06), location: 0.76),
            .init(color: .white.opacity(Theme.Glass.rimTop), location: 0.88),
            .init(color: .white.opacity(side), location: 1),
        ], center: .center))
    }
}
