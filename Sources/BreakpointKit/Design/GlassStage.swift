import SwiftUI
import BreakpointRuntime

/// A drawn desktop that glass surfaces inside `content` blur as if it were behind their window
/// (`GlassRendering.simulated`). Snapshots and films only: `ImageRenderer` cannot draw
/// behind-window materials, so without a stage every picture of the glass is a flat colour.
///
/// The stage fills its proposed size; `content` is centred on it (position it with padding,
/// frames or offsets). Every glass surface inside reads its own frame in the stage's coordinate
/// space and draws the matching, blurred part of `backdrop`.
public struct GlassStage<Backdrop: View, Content: View>: View {
    private let backdrop: Backdrop
    private let content: Content

    public init(@ViewBuilder backdrop: () -> Backdrop, @ViewBuilder content: () -> Content) {
        self.backdrop = backdrop()
        self.content = content()
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                backdrop.frame(width: proxy.size.width, height: proxy.size.height)
                content
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .environment(\.glassBackdrop, GlassBackdrop(view: AnyView(backdrop), size: proxy.size))
            .glassRendering(.simulated)
        }
        .coordinateSpace(name: GlassBackdrop.coordinateSpace)
    }
}

/// What a `GlassStage` hands its glass: the desktop and its size.
struct GlassBackdrop {
    static let coordinateSpace = "BreakpointGlassStage"
    var view: AnyView
    var size: CGSize
}

private struct GlassBackdropKey: EnvironmentKey {
    static let defaultValue: GlassBackdrop? = nil
}

extension EnvironmentValues {
    var glassBackdrop: GlassBackdrop? {
        get { self[GlassBackdropKey.self] }
        set { self[GlassBackdropKey.self] = newValue }
    }
}

/// The stage's desktop under `shape`, blurred and veiled the way the HUD material treats what is
/// behind a window (callers add the black tint, as over the live material). Falls back to the
/// opaque approximation outside a stage.
struct SimulatedGlassFill<S: Shape>: View {
    let shape: S
    @Environment(\.glassBackdrop) private var backdrop

    var body: some View {
        if let backdrop {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(GlassBackdrop.coordinateSpace))
                // Crop with a margin and flatten first, then blur: a blur over a moved view
                // samples the view where it was before the move.
                let margin = Theme.Glass.simulatedBlur * 2
                backdrop.view
                    .frame(width: backdrop.size.width, height: backdrop.size.height)
                    .offset(x: margin - frame.minX, y: margin - frame.minY)
                    .frame(width: proxy.size.width + 2 * margin, height: proxy.size.height + 2 * margin,
                           alignment: .topLeading)
                    .clipped()
                    .drawingGroup()
                    .blur(radius: Theme.Glass.simulatedBlur, opaque: true)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .overlay(Theme.Colors.glassApproximation.opacity(Theme.Glass.simulatedVeil))
            }
            .clipShape(shape)
            .allowsHitTesting(false)
        } else {
            shape.fill(Theme.Colors.glassApproximation)
        }
    }
}
