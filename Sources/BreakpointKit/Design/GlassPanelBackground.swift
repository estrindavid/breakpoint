import AppKit
import SwiftUI
import BreakpointRuntime

/// The one implementation of pop-up glass (SPEC §4.5).
///
/// - **macOS 26 and later:** the system Liquid Glass (`glassEffect`, dark), which bends, tints and
///   lights itself from what is behind the panel, under an 18% black veil for text contrast.
/// - **macOS 14 and 15:** HUD material (dark in both system modes) + a 12% black tint that clears
///   towards the rim, lit by `GlassLighting`: a bevelled rim that reads as thickness, a soft band
///   of gathered light just inside it, and a still sheen from the top-leading corner.
/// - Reduce Transparency: solid `#151A22` with a 12% rim (no lighting, no system glass).
/// - Increase Contrast: rim 30% white, no sheen or band.
/// - `glassRendering == .opaque` (snapshots): an opaque approximation, lit like macOS 14 and 15;
///   `.simulated`: the same over a blurred, drawn desktop (`GlassStage`).
///
/// Put it behind content with `.background(GlassPanelBackground(shape))`, or use `GlassCard`.
/// The window hosting it must be transparent and leave `Theme.Glass.shadowMargin` around it.
public struct GlassPanelBackground<S: InsettableShape>: View {
    private let shape: S
    private let showsShadow: Bool
    private let traits = DesignTraits()

    public init(_ shape: S, shadow: Bool = true) {
        self.shape = shape
        self.showsShadow = shadow
    }

    public var body: some View {
        ZStack {
            if showsShadow { GlassShadow(shape: shape) }
            if traits.usesSystemGlass {
                SystemGlass(shape: shape)
            } else {
                fill
                if !traits.reduceTransparency && !traits.increaseContrast {
                    GlassLighting(shape: shape)
                }
                shape.strokeBorder(rim, lineWidth: 1)
            }
        }
    }

    @ViewBuilder private var fill: some View {
        if traits.reduceTransparency {
            shape.fill(Theme.Colors.solidPopup)
        } else if traits.glassRendering == .opaque {
            shape.fill(Theme.Colors.glassApproximation)
        } else if traits.glassRendering == .simulated {
            ZStack {
                SimulatedGlassFill(shape: shape)
                GlassTint(shape: shape)
            }
        } else {
            ZStack {
                VisualEffectBackground(material: .hudWindow, blending: .behindWindow)
                GlassTint(shape: shape)
            }
            .clipShape(shape)
        }
    }

    private var rim: AnyShapeStyle {
        if traits.increaseContrast { return AnyShapeStyle(Color.white.opacity(Theme.Glass.rimIncreasedContrast)) }
        if traits.reduceTransparency { return AnyShapeStyle(Color.white.opacity(Theme.Glass.rimSolid)) }
        return GlassLighting<S>.rimStyle
    }
}

/// The system Liquid Glass (macOS 26) in `shape`, dark, under the pop-up veil. Increase Contrast
/// adds the 30% rim on top of the system's own border.
struct SystemGlass<S: InsettableShape>: View {
    let shape: S
    private let traits = DesignTraits()

    var body: some View {
        if #available(macOS 26.0, *) {
            ZStack {
                shape.fill(Color.black.opacity(Theme.Glass.liquidVeil))
                    .glassEffect(.regular, in: shape)
                if traits.increaseContrast {
                    shape.strokeBorder(Color.white.opacity(Theme.Glass.rimIncreasedContrast), lineWidth: 1)
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

extension DesignTraits {
    /// Pop-up glass is the system Liquid Glass: live rendering on macOS 26 or later, and not
    /// Reduce Transparency (which keeps the solid fill of SPEC §4.8).
    var usesSystemGlass: Bool {
        guard glassRendering == .live, !reduceTransparency else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// The two-layer pop-up shadow, drawn only outside `shape` so translucent glass is not darkened.
struct GlassShadow<S: Shape>: View {
    let shape: S

    var body: some View {
        ZStack {
            ForEach(Array(Theme.Glass.shadows.enumerated()), id: \.offset) { _, spec in
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(spec.opacity), radius: spec.radius, x: 0, y: spec.y)
            }
        }
        .mask {
            Rectangle()
                .padding(-200)
                .overlay(shape.fill(Color.black).blendMode(.destinationOut))
                .compositingGroup()
        }
        .allowsHitTesting(false)
    }
}

/// `NSVisualEffectView` in SwiftUI, forced to the dark appearance.
public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blending: NSVisualEffectView.BlendingMode
    public var emphasized: Bool

    public init(material: NSVisualEffectView.Material, blending: NSVisualEffectView.BlendingMode, emphasized: Bool = false) {
        self.material = material
        self.blending = blending
        self.emphasized = emphasized
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        update(view)
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) { update(view) }

    private func update(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blending
        view.isEmphasized = emphasized
    }
}

/// A glass pop-up card: dark glass, given radius and padding, dark colour scheme for its content.
public struct GlassCard<Content: View>: View {
    private let radius: CGFloat
    private let padding: EdgeInsets
    private let content: Content

    public init(radius: CGFloat = Theme.Radius.card, padding: CGFloat = Theme.Layout.cardPadding,
                @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.padding = EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)
        self.content = content()
    }

    public init(radius: CGFloat, padding: EdgeInsets, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .glassSurface(radius: radius) { GlassPanelBackground(RoundedRectangle(cornerRadius: radius, style: .continuous)) }
            .environment(\.colorScheme, .dark)
    }
}

/// A glass capsule (away note, toasts, countdown chip).
public struct GlassCapsule<Content: View>: View {
    private let height: CGFloat
    private let leadingInset: CGFloat
    private let trailingInset: CGFloat
    private let content: Content

    public init(height: CGFloat = Theme.Layout.capsuleHeight, leadingInset: CGFloat = 16, trailingInset: CGFloat = 16,
                @ViewBuilder content: () -> Content) {
        self.height = height
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(height: height)
            .glassSurface(radius: height / 2) { GlassPanelBackground(Capsule(style: .circular)) }
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Glass drawn by the pop-up's motion

/// Inside a pop-up, the glass is drawn by the pop-up's motion rather than by the card, so it can
/// change shape on its own (grow out of a point, fold away, become the countdown chip) while the
/// card's content keeps its layout. `GlassCard` and `GlassCapsule` then draw no glass and report
/// their corner radius instead (`GlassSurfaceRadiusKey`). Set by `PopupMotion` only.
private struct GlassSurfaceHostedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var glassSurfaceHosted: Bool {
        get { self[GlassSurfaceHostedKey.self] }
        set { self[GlassSurfaceHostedKey.self] = newValue }
    }
}

/// The corner radius of a card whose glass is hosted (nil when there is none).
public struct GlassSurfaceRadiusKey: PreferenceKey {
    public static let defaultValue: CGFloat? = nil
    public static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

private struct GlassSurface<Glass: View>: ViewModifier {
    let radius: CGFloat
    let glass: Glass
    @Environment(\.glassSurfaceHosted) private var hosted

    func body(content: Content) -> some View {
        if hosted {
            content.preference(key: GlassSurfaceRadiusKey.self, value: radius)
        } else {
            content.background(glass)
        }
    }
}

extension View {
    /// `glass` behind this view, unless a pop-up's motion hosts it (then only `radius` is reported).
    fileprivate func glassSurface<Glass: View>(radius: CGFloat, @ViewBuilder _ glass: () -> Glass) -> some View {
        modifier(GlassSurface(radius: radius, glass: glass()))
    }
}
