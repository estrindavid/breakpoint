import CoreGraphics
import SwiftUI
import BreakpointCore

// SPEC §3.3 (backdrop), §4.6 (entrance and exit), §4.8.

/// The break overlay's backdrop, bottom to top:
///
/// 1. the behind-window blur of the live desktop (`.fullScreenUI`, dark);
/// 2. the deep scrim `#070A12` at 60% (75% Increase Contrast, 85% ambient);
/// 3. a vignette: the scrim colour deepening toward the display's edges;
/// 4. the Breakpoint aurora: five soft lights in mint, teal, indigo and deep blue, laid on in deep
///    tones and then added as light, drifting on a 60 s loop (`AuroraField`);
/// 5. a hush: a little more scrim behind the column, so the light never costs the text contrast;
/// 6. a fixed fine grain, so the gradients never band on any display.
///
/// Each layer moves on its own in the entrance and the exit (`BackdropFrame`, from
/// `BackdropTimeline`): the desktop softens first, the edges and then the whole screen darken,
/// and the light rises from behind the words; at the end the light goes first and the desktop
/// comes back into focus last.
///
/// - Reduce Motion: the aurora is still; the layers cross-fade together.
/// - Reduce Transparency: solid `#0B0F17`, the still aurora at 8%, and the grain.
/// - Increase Contrast: no aurora.
/// - Opaque glass rendering (snapshots, films): no live blur; an approximation of the dark
///   material's tint over whatever is drawn behind.
public struct OverlayBackdrop: View {
    private let frame: BackdropFrame
    private let ambient: Bool
    private let time: TimeInterval?
    private let traits = DesignTraits()

    /// - Parameters:
    ///   - frame: the layers' entrance / exit state (`.settled` at rest).
    ///   - ambient: `walk` ambient mode (scrim 85%, aurora still and at half strength).
    ///   - time: the backdrop's clock in seconds for films; `nil` follows the wall clock.
    public init(_ frame: BackdropFrame = .settled, ambient: Bool = false, time: TimeInterval? = nil) {
        self.frame = frame
        self.ambient = ambient
        self.time = time
    }

    public var body: some View {
        ZStack {
            if traits.reduceTransparency {
                Theme.Colors.solidOverlay
                    .opacity(frame.dim)
                if !traits.increaseContrast {
                    AuroraLights(phase: 0, bloom: 1, palette: .light)
                        .opacity(Theme.Backdrop.auroraReducedTransparencyOpacity * frame.glow)
                }
            } else {
                Group {
                    if traits.glassRendering == .live {
                        VisualEffectBackground(material: .fullScreenUI, blending: .behindWindow)
                    } else {
                        // Snapshots: the dark material's own tint over the (stand-in, pre-blurred)
                        // desktop, so contrast is judged against roughly what the live blur shows.
                        Self.materialApproximation
                    }
                }
                .opacity(frame.blur)
                Theme.Colors.scrim.opacity(scrimOpacity * frame.dim)
                Vignette()
                    .opacity(frame.vignette)
                if !traits.increaseContrast {
                    Aurora(animated: drifts, time: time, bloom: traits.reduceMotion ? 1 : frame.bloom,
                           strength: frame.glow * (ambient ? 0.5 : 1))
                }
                Hush()
                    .opacity(frame.dim)
            }
            Grain()
                .opacity(Theme.Backdrop.grainOpacity * max(frame.dim, frame.blur))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The aurora drifts in the app (unless Reduce Motion or ambient), and in films, whose clock
    /// is given even though snapshots freeze live animation.
    private var drifts: Bool {
        guard !ambient, !traits.reduceMotion else { return false }
        return traits.runsContinuousAnimations || time != nil
    }

    /// Approximation of the dark `.fullScreenUI` material's tint (opaque rendering only).
    static let materialApproximation = Color(hex: 0x1C1F26).opacity(0.55)

    private var scrimOpacity: Double {
        if ambient { return Theme.Backdrop.scrimOpacityAmbient }
        return traits.increaseContrast ? Theme.Backdrop.scrimOpacityIncreasedContrast : Theme.Backdrop.scrimOpacity
    }
}

// MARK: - Vignette

/// The scrim colour deepening toward the edges, clear around the column (centred where the
/// column's text group is, 44% down).
private struct Vignette: View {
    var body: some View {
        EllipticalGradient(
            stops: [
                .init(color: Theme.Colors.scrim.opacity(0), location: 0),
                .init(color: Theme.Colors.scrim.opacity(0), location: Theme.Backdrop.vignetteClearRadius),
                .init(color: Theme.Colors.scrim.opacity(Theme.Backdrop.vignetteOpacity * 0.5), location: 0.72),
                .init(color: Theme.Colors.scrim.opacity(Theme.Backdrop.vignetteOpacity), location: 1),
            ],
            center: UnitPoint(x: AuroraField.gatherPoint.x, y: AuroraField.gatherPoint.y),
            startRadiusFraction: 0, endRadiusFraction: 1.05)
    }
}

/// A soft extra scrim behind the column's text group, over the aurora: the light lives around
/// the words, never under them.
private struct Hush: View {
    var body: some View {
        GeometryReader { proxy in
            RadialGradient(
                stops: [
                    .init(color: Theme.Colors.scrim.opacity(Theme.Backdrop.hushOpacity), location: 0),
                    .init(color: Theme.Colors.scrim.opacity(Theme.Backdrop.hushOpacity * 0.75), location: 0.4),
                    .init(color: Theme.Colors.scrim.opacity(Theme.Backdrop.hushOpacity * 0.3), location: 0.75),
                    .init(color: Theme.Colors.scrim.opacity(0), location: 1),
                ],
                center: UnitPoint(x: AuroraField.gatherPoint.x, y: 0.5),
                startRadius: 0, endRadius: proxy.size.width * Theme.Backdrop.hushRadius)
            .scaleEffect(x: 1, y: 0.8)
        }
    }
}

// MARK: - Aurora

/// The Breakpoint aurora: `AuroraField`'s lights laid over the scrim in deep tones, then the
/// same lights added as light, both on one clock. `strength` scales both passes (the entrance,
/// the exit, ambient).
struct Aurora: View {
    let animated: Bool
    /// A fixed clock reading (films); `nil` follows the wall clock when animated.
    var time: TimeInterval?
    /// 0: the lights gathered behind the words (start of the entrance), 1: at rest.
    var bloom: Double = 1
    var strength: Double = 1

    var body: some View {
        if animated, let time {
            passes(phase: AuroraField.phase(at: time))
        } else if animated {
            TimelineView(.animation(minimumInterval: BreakTiming.auroraFrameInterval)) { context in
                passes(phase: AuroraField.phase(at: context.date.timeIntervalSinceReferenceDate))
            }
        } else {
            passes(phase: 0)
        }
    }

    private func passes(phase: Double) -> some View {
        ZStack {
            AuroraLights(phase: phase, bloom: bloom, palette: .deep)
                .opacity(Theme.Backdrop.auroraDeepStrength * strength)
            AuroraLights(phase: phase, bloom: bloom, palette: .light)
                .opacity(Theme.Backdrop.auroraStrength * strength)
                .blendMode(.plusLighter)
        }
    }
}

/// One pass of the aurora's lights, each a soft round light with a Gaussian-like falloff, added
/// together. Drawn at full strength; callers set its opacity.
struct AuroraLights: View {
    let phase: Double
    let bloom: Double
    let palette: Palette

    enum Palette {
        /// The brand colours, added as light.
        case light
        /// Deep, saturated versions, laid over the scrim so the grey of the blurred desktop turns
        /// to colour instead of washing out.
        case deep
    }

    var body: some View { field(phase: phase) }

    /// A light's falloff: opacity at fractions of its radius (close to a Gaussian, so the lights
    /// have no visible rim).
    private static let falloff: [(location: CGFloat, opacity: Double)] = [
        (0, 1), (0.15, 0.86), (0.3, 0.6), (0.45, 0.34), (0.6, 0.16), (0.75, 0.06), (0.9, 0.015), (1, 0),
    ]

    static func color(_ hue: AuroraField.Hue, _ palette: Palette) -> Color {
        switch (hue, palette) {
        case (.mint, .light): return Theme.Colors.mint
        case (.teal, .light): return Theme.Backdrop.auroraTeal
        case (.indigo, .light): return Theme.Colors.indigo
        case (.deep, .light): return Theme.Backdrop.auroraDeep
        case (_, .deep): return Theme.Backdrop.auroraDeepTones[hue.deepToneIndex]
        }
    }

    private func field(phase: Double) -> some View {
        let lights = AuroraField.lights(phase: phase, bloom: bloom)
        return Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let longSide = max(size.width, size.height)
            context.blendMode = .plusLighter
            for light in lights {
                let color = Self.color(light.hue, palette)
                let stops = Self.falloff.map {
                    Gradient.Stop(color: color.opacity($0.opacity * light.intensity), location: $0.location)
                }
                context.fill(Path(rect), with: .radialGradient(
                    Gradient(stops: stops),
                    center: CGPoint(x: size.width * light.x, y: size.height * light.y),
                    startRadius: 0, endRadius: longSide * light.radius))
            }
        }
        .drawingGroup()
    }
}

extension AuroraField.Hue {
    fileprivate var deepToneIndex: Int {
        switch self {
        case .mint: return 0
        case .teal: return 1
        case .indigo: return 2
        case .deep: return 3
        }
    }
}

// MARK: - Grain

/// A fixed tile of fine monochrome noise, one texel per pixel on a Retina display, drawn at a few
/// percent so smooth gradients never show steps. Generated once in code (no resources).
private struct Grain: View {
    var body: some View {
        Image(decorative: GrainTile.image, scale: 2)
            .resizable(resizingMode: .tile)
    }
}

enum GrainTile {
    /// The tile: `Theme.Backdrop.grainTile` square, 8-bit grey, from a fixed seed.
    static let image: CGImage = make(size: Theme.Backdrop.grainTile)

    static func make(size: Int) -> CGImage {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 0, count: size * size)
        for i in bytes.indices {
            // xorshift64*: deterministic, evenly spread.
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let value = state &* 0x2545_F491_4F6C_DD1D
            bytes[i] = UInt8(truncatingIfNeeded: value >> 56)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
