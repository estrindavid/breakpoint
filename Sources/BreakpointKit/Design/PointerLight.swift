import SwiftUI
import BreakpointRuntime

// How a control answers the pointer (SPEC §3.0 "Buttons", §4.6 "Controls").
//
// Hover: a soft light comes up inside the control where the pointer is and follows it with a
// slight lag, the rim catches that light, and the control rises 1 pt off the surface on a contact
// shadow. Press: the control sinks to 97% on a quick spring and the light blooms under the
// pointer; release settles back on a softer spring (no visible overshoot). The keyboard focus
// ring grows in instead of appearing.
//
// Reduce Motion: nothing moves or scales; the light sits still at the top edge and fades in and
// out (0.15 s); a press shows as a brighter light. Increase Contrast: a brighter rim.
//
// Every frame is a pure function of `ControlResponse`, so snapshots and films can set it directly
// (`.controlResponsePreview(_:)`) instead of moving a real pointer.

/// The state of a control under the pointer, as numbers that animate.
public struct ControlResponse: Equatable, Sendable {
    /// 0 … 1: how far the hover light has come up.
    public var hover: Double
    /// 0 … 1: how far the control has pressed in.
    public var press: Double
    /// Where the pointer is, in the control's unit square ((0, 0) top leading).
    public var location: UnitPoint
    /// 0 … 1: how far the keyboard focus ring has grown in.
    public var focus: Double

    public init(hover: Double = 0, press: Double = 0, location: UnitPoint = .center, focus: Double = 0) {
        self.hover = hover
        self.press = press
        self.location = location
        self.focus = focus
    }

    public static let rest = ControlResponse()
}

/// Which light a control's surface throws back.
public enum PointerLightTone: Sendable {
    /// Neutral glass on dark pop-ups, the popover and the overlay.
    case glass
    /// Neutral controls on light windows (onboarding, settings in light mode).
    case window
    /// A mint-filled primary.
    case mint
    /// Text-only buttons: a fainter light and rim.
    case quiet
}

private struct ControlResponsePreviewKey: EnvironmentKey {
    static let defaultValue: ControlResponse? = nil
}

private struct ControlResponsePreviewsKey: EnvironmentKey {
    static let defaultValue: [String: ControlResponse]? = nil
}

private struct ControlIsPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Forces every pointer-responsive control in the subtree into this state (snapshots and
    /// films). `nil` (the default) follows the real pointer.
    public var controlResponsePreview: ControlResponse? {
        get { self[ControlResponsePreviewKey.self] }
        set { self[ControlResponsePreviewKey.self] = newValue }
    }

    /// Per-button forced states, keyed by a `PillButton`'s title (films drive one button at a
    /// time inside a real surface). A title not in the map rests.
    public var controlResponsePreviews: [String: ControlResponse]? {
        get { self[ControlResponsePreviewsKey.self] }
        set { self[ControlResponsePreviewsKey.self] = newValue }
    }

    /// True inside the label of a pressed `PillButton` (a keycap in it presses too).
    public var controlIsPressed: Bool {
        get { self[ControlIsPressedKey.self] }
        set { self[ControlIsPressedKey.self] = newValue }
    }
}

extension View {
    /// Forces pointer-responsive controls in this subtree into `response` (snapshots and films).
    public func controlResponsePreview(_ response: ControlResponse?) -> some View {
        environment(\.controlResponsePreview, response)
    }

    /// Forces each `PillButton` in this subtree into the state under its title (films).
    public func controlResponsePreviews(_ responses: [String: ControlResponse]?) -> some View {
        environment(\.controlResponsePreviews, responses)
    }
}

/// Picks a `PillButton`'s entry out of `controlResponsePreviews`, when a film set one.
struct KeyedControlResponse: ViewModifier {
    let key: String
    @Environment(\.controlResponsePreviews) private var previews
    @Environment(\.controlResponsePreview) private var preview

    func body(content: Content) -> some View {
        content.environment(\.controlResponsePreview, previews.map { $0[key] ?? .rest } ?? preview)
    }
}

extension Theme.Motion {
    /// Hover light coming up / going down, and the 1 pt lift.
    public static let hoverIn = Animation.spring(response: 0.28, dampingFraction: 0.9)
    public static let hoverOut = Animation.spring(response: 0.4, dampingFraction: 1)
    /// The light following the pointer: a short lag, never a bounce.
    public static let pointerFollow = Animation.spring(response: 0.22, dampingFraction: 1)
    /// Press in (quick) and release (a softer settle; damping 0.8 keeps overshoot invisible).
    public static let pressDown = Animation.spring(response: 0.16, dampingFraction: 0.86)
    public static let pressRelease = Animation.spring(response: 0.34, dampingFraction: 0.8)
    /// Keyboard focus ring growing in.
    public static let focusRing = Animation.spring(response: 0.25, dampingFraction: 0.9)
    /// Reduce Motion: hover and press become this fade.
    public static let controlFade = Animation.easeInOut(duration: 0.15)

    /// Pressed controls scale to this.
    public static let pressScale: CGFloat = 0.97
    /// Hovered controls rise this far.
    public static let hoverLift: CGFloat = 1
    /// Where the light sits under Reduce Motion (top centre: light from above).
    public static let stillLightLocation = UnitPoint(x: 0.5, y: 0)

    static func hoverAnimation(_ hovering: Bool, reduceMotion: Bool) -> Animation {
        reduceMotion ? controlFade : (hovering ? hoverIn : hoverOut)
    }

    static func pressAnimation(_ pressed: Bool, reduceMotion: Bool) -> Animation {
        reduceMotion ? controlFade : (pressed ? pressDown : pressRelease)
    }
}

/// The light inside a control: a soft spot under the pointer and the rim catching it. Draws
/// nothing at rest. Animatable, so the spot glides and fades on the springs above.
public struct PointerLight<S: InsettableShape>: View, Animatable {
    private var hover: Double
    private var press: Double
    private var x: Double
    private var y: Double
    private let shape: S
    private let tone: PointerLightTone
    private let increaseContrast: Bool

    public init(_ response: ControlResponse, in shape: S, tone: PointerLightTone, increaseContrast: Bool = false) {
        hover = response.hover
        press = response.press
        x = response.location.x
        y = response.location.y
        self.shape = shape
        self.tone = tone
        self.increaseContrast = increaseContrast
    }

    public var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(hover, press), AnimatablePair(x, y)) }
        set {
            hover = newValue.first.first
            press = newValue.first.second
            x = newValue.second.first
            y = newValue.second.second
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = UnitPoint(x: x, y: y)
            // The spot is about three control-heights across: a light you can see move on a 28 or
            // 34 pt capsule; on a tall card it is capped so it stays a spot.
            let reach = min(size.height, 44) * 1.6
            let sheen = sheenPeak
            let rim = rimPeak
            ZStack {
                if sheen > 0.001 {
                    shape.fill(RadialGradient(colors: [sheenColor.opacity(sheen), sheenColor.opacity(sheen * 0.35),
                                                       sheenColor.opacity(0)],
                                              center: center, startRadius: 0, endRadius: reach))
                }
                if rim > 0.001 {
                    shape.strokeBorder(RadialGradient(colors: [rimColor.opacity(rim), rimColor.opacity(0)],
                                                      center: center, startRadius: 0, endRadius: reach * 1.15),
                                       lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var hoverAmount: Double { min(max(hover, 0), 1) }
    private var pressAmount: Double { min(max(press, 0), 1) }

    private var sheenPeak: Double {
        let (rest, bloom): (Double, Double)
        switch tone {
        case .glass: (rest, bloom) = (0.16, 0.10)
        case .window: (rest, bloom) = (0.75, 0.2)
        case .mint: (rest, bloom) = (0.32, 0.14)
        case .quiet: (rest, bloom) = (0.10, 0.08)
        }
        return rest * hoverAmount + bloom * pressAmount
    }

    private var rimPeak: Double {
        let peak: Double
        switch tone {
        case .glass: peak = increaseContrast ? 0.75 : 0.5
        case .window: peak = increaseContrast ? 0.35 : 0.2
        case .mint: peak = 0.55
        case .quiet: peak = increaseContrast ? 0.3 : 0
        }
        return peak * max(hoverAmount, pressAmount)
    }

    private var sheenColor: Color { .white }
    private var rimColor: Color { tone == .window ? .black : .white }
}

/// A soft shadow just below a lifted control, outside its shape only (it never darkens a
/// translucent fill). `lift` 0 … 1.
struct ContactShadow<S: InsettableShape>: View {
    let shape: S
    let lift: Double
    let dark: Bool

    var body: some View {
        shape
            .fill(Color.black.opacity((dark ? 0.32 : 0.16) * lift))
            .blur(radius: 2.5)
            .offset(y: 1 + 1.5 * lift)
            .mask {
                Rectangle()
                    .padding(-12)
                    .overlay(shape.fill(Color.black).blendMode(.destinationOut))
                    .compositingGroup()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Follows the pointer over a view: `hovering` and `location` (unit square), set inside the
/// right animations. Under Reduce Motion the location stays at the top edge.
struct PointerTracking: ViewModifier {
    @Binding var hovering: Bool
    @Binding var location: UnitPoint
    let reduceMotion: Bool
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let unit = reduceMotion || size.width <= 0 || size.height <= 0
                        ? Theme.Motion.stillLightLocation
                        : UnitPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
                    if hovering {
                        withAnimation(reduceMotion ? nil : Theme.Motion.pointerFollow) { location = unit }
                    } else {
                        // The light comes up where the pointer enters; it does not fly in.
                        var still = Transaction()
                        still.disablesAnimations = true
                        withTransaction(still) { location = unit }
                        withAnimation(Theme.Motion.hoverAnimation(true, reduceMotion: reduceMotion)) { hovering = true }
                    }
                case .ended:
                    withAnimation(Theme.Motion.hoverAnimation(false, reduceMotion: reduceMotion)) { hovering = false }
                }
            }
    }
}

/// A button style for any control that is not a `PillButton` (icon buttons, the × on pop-ups,
/// settings cards): the same light, lift and press, drawn over the label in `shape`.
public struct PointerResponseStyle<S: InsettableShape>: ButtonStyle {
    private let shape: S
    private let tone: PointerLightTone?
    private let lifts: Bool

    /// `tone` nil picks glass in dark appearance and window in light. `lifts` false keeps the
    /// control flat on hover (for controls that sit inside a row or touch an edge).
    public init(_ shape: S, tone: PointerLightTone? = nil, lifts: Bool = true) {
        self.shape = shape
        self.tone = tone
        self.lifts = lifts
    }

    public func makeBody(configuration: Configuration) -> some View {
        PointerResponseBody(configuration: configuration, shape: shape, tone: tone, lifts: lifts)
    }
}

private struct PointerResponseBody<S: InsettableShape>: View {
    let configuration: ButtonStyleConfiguration
    let shape: S
    let tone: PointerLightTone?
    let lifts: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlResponsePreview) private var preview
    @State private var hovering = false
    @State private var location = UnitPoint.center
    private let traits = DesignTraits()

    var body: some View {
        let reduceMotion = traits.reduceMotion
        let response = self.response
        let lift = lifts && !reduceMotion ? response.hover * (1 - response.press) : 0
        configuration.label
            .overlay(PointerLight(response, in: shape, tone: tone ?? (scheme == .dark ? .glass : .window),
                                  increaseContrast: traits.increaseContrast))
            .background(ContactShadow(shape: shape, lift: lift, dark: scheme == .dark))
            .contentShape(shape)
            .scaleEffect(reduceMotion ? 1 : 1 - (1 - Theme.Motion.pressScale) * response.press)
            .offset(y: -Theme.Motion.hoverLift * lift)
            .animation(Theme.Motion.pressAnimation(configuration.isPressed, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
            .modifier(PointerTracking(hovering: $hovering, location: $location, reduceMotion: reduceMotion))
    }

    private var response: ControlResponse {
        var response = preview ?? ControlResponse(hover: hovering && isEnabled ? 1 : 0,
                                                  press: configuration.isPressed ? 1 : 0, location: location)
        // Reduce Motion: the light never travels; it sits at the top edge.
        if traits.reduceMotion { response.location = Theme.Motion.stillLightLocation }
        return response
    }
}
