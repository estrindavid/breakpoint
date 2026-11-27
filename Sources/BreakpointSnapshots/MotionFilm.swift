import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

// Pop-up motion frame by frame (SPEC §4.6 "Liquid pop-ups"), for review:
//
//   BreakpointSnapshots --motion-film before|after|reduce-motion [--scale S]
//       raw RGBA frames (960 × 600 pt × S, 60 fps) on stdout, for ffmpeg:
//       … | ffmpeg -f rawvideo -pix_fmt rgba -s 960x600 -r 60 -i - …
//   BreakpointSnapshots --motion-still VARIANT SECONDS OUT.png [--scale S]
//   BreakpointSnapshots --motion-strip before|after OUT.png [--scale S]
//       the nudge becoming the countdown chip, four moments in a 2 × 2 grid
//
// Every frame is a pure function of the film's time: the drawn desktop, a pointer, and the real
// pop-up views at that moment. "after" uses the same `LiquidMotion` poses and views as the live
// panels. "before" draws the plain pop-up motion for comparison: 8 pt drop + 6 pt blur + fade in
// 0.55 s; 4 pt drift + fade out; the card fading while the chip enters on its own at the pointer.
// Nothing is captured from a screen. The glass is the snapshots' opaque approximation (ImageRenderer cannot draw the
// behind-window material).

enum MotionFilm {
    static let size = CGSize(width: 960, height: 600)
    static let fps: Double = 60

    enum Variant: String, CaseIterable {
        case before
        case after
        case reduceMotion = "reduce-motion"
    }

    // The script (seconds).
    /// The eye-rest card arrives, counting down.
    static let cardIn: TimeInterval = 0.3
    /// Seconds left on the countdown when the card arrives.
    static let cardRemaining: TimeInterval = 6.4
    /// The countdown reaches 5: the card becomes the chip at the pointer.
    static var handoff: TimeInterval { cardIn + cardRemaining - Timing.autoStartChipAt }
    /// The pointer drifts and the chip follows.
    static let pointerMove: ClosedRange<TimeInterval> = 2.9...3.5
    /// A key press cancels the countdown: the chip leaves.
    static let chipCancel: TimeInterval = 3.9
    /// A stretch offer arrives and, ignored, times out.
    static let stretchIn: TimeInterval = 4.6
    static let stretchOut: TimeInterval = 6.0
    static let length: TimeInterval = 6.8

    static let pointerStart = CGPoint(x: 668, y: 318)
    static let pointerEnd = CGPoint(x: 724, y: 356)
    /// The card's top edge: the menu bar + 8 (§3.0).
    static let cardTop: CGFloat = GlassDesktop.menuBarHeight + 8

    // MARK: Entry points

    @MainActor
    static func run(_ args: [String]) -> Int32? {
        var scale: CGFloat = 1
        if let i = args.firstIndex(of: "--scale"), i + 1 < args.count, let s = Double(args[i + 1]) { scale = s }
        if let i = args.firstIndex(of: "--motion-film") {
            guard i + 1 < args.count, let variant = Variant(rawValue: args[i + 1]) else {
                return Film.usage("--motion-film needs one of \(Variant.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return Film.stream(Int((length * fps).rounded()), of: variant.rawValue) {
                render(MotionScene(variant: variant, t: Double($0) / fps), scale: scale)
            }
        }
        if let i = args.firstIndex(of: "--motion-still") {
            guard i + 3 < args.count, let variant = Variant(rawValue: args[i + 1]), let t = Double(args[i + 2]) else {
                return Film.usage("--motion-still VARIANT SECONDS OUT.png")
            }
            return Film.writeStill(render(MotionScene(variant: variant, t: t), scale: scale), to: args[i + 3])
        }
        if let i = args.firstIndex(of: "--motion-strip") {
            guard i + 2 < args.count, let variant = Variant(rawValue: args[i + 1]) else {
                return Film.usage("--motion-strip VARIANT OUT.png")
            }
            return Film.writeStill(render(MotionStrip(variant: variant), scale: scale), to: args[i + 2])
        }
        return nil
    }

    @MainActor
    private static func render<V: View>(_ view: V, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view
            .glassRendering(.opaque)
            .designOverrides(DesignOverrides(reduceMotion: false, reduceTransparency: false, increaseContrast: false,
                                             freezeContinuousAnimations: true))
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.cgImage
    }

    // MARK: Script values

    static func pointer(at t: TimeInterval) -> CGPoint {
        let s = LiquidMotion.smoothstep(pointerMove.lowerBound, pointerMove.upperBound, t)
        return CGPoint(x: LiquidMotion.lerp(pointerStart.x, pointerEnd.x, s), y: LiquidMotion.lerp(pointerStart.y, pointerEnd.y, s))
    }

    /// Seconds left on the eye-rest countdown.
    static func remaining(at t: TimeInterval) -> TimeInterval { cardIn + cardRemaining - t }

    /// The plain pop-up entrance ("before"): 0.55 s cubic-bezier(.25,.1,.25,1).
    static func oldArrival(_ since: TimeInterval) -> Double {
        LiquidMotion.timingCurve(0.25, 0.1, 0.25, 1, since / 0.55)
    }
}

// MARK: - One frame

/// The desktop and every pop-up at film time `t`.
@MainActor
struct MotionScene: View {
    let variant: MotionFilm.Variant
    let t: TimeInterval
    var showsLabel = true

    private typealias F = MotionFilm

    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassDesktop(canvas: F.size, viewport: CGRect(origin: .zero, size: F.size))
            eyeRestCard
            chip
            stretchCard
            FilmPointer().offset(x: F.pointer(at: t).x, y: F.pointer(at: t).y)
            if showsLabel { label }
        }
        .frame(width: F.size.width, height: F.size.height, alignment: .topLeading)
        .clipped()
    }

    private var label: some View {
        FilmCaption(variant == .before ? "Before" : variant == .after ? "After" : "After · Reduce Motion")
            .offset(x: 16, y: F.size.height - 40)
    }

    private func cardX(_ width: CGFloat) -> CGFloat { ((F.size.width - width) / 2).rounded() }

    // MARK: The eye-rest card and the chip

    private var eyeRestNudge: NudgeState {
        AppState.preview(.autoStart(remaining: max(Timing.autoStartChipAt, F.remaining(at: t)))).nudge!
    }

    @ViewBuilder private var eyeRestCard: some View {
        let since = t - F.cardIn
        let width = Theme.Layout.nudgeSize.width
        if since >= 0 {
            let card = NudgeCardView(nudge: eyeRestNudge, actions: .noop)
            switch variant {
            case .after:
                if t < F.handoff {
                    card.modifier(LiquidPopupPose(mode: .grow, progress: arrivalSpring(since)))
                        .offset(x: cardX(width), y: F.cardTop)
                }
            case .before:
                let fadeOut = t < F.handoff ? 0 : LiquidMotion.timingCurve(0, 0, 0.58, 1, (t - F.handoff) / 0.2)
                if fadeOut < 1 { oldEntrance(card, since: since).opacity(1 - fadeOut).offset(x: cardX(width), y: F.cardTop) }
            case .reduceMotion:
                let fadeOut = t < F.handoff ? 0 : easeInOut((t - F.handoff) / 0.2)
                if fadeOut < 1 {
                    card.modifier(LiquidPopupPose(mode: .crossfade, progress: min(easeInOut(since / 0.2), 1 - fadeOut)))
                        .offset(x: cardX(width), y: F.cardTop)
                }
            }
        }
    }

    private var chipSize: CGSize {
        NSHostingView(rootView: CountdownChipView(kind: .eyes, remaining: 5).fixedSize()).fittingSize
    }

    private func chipTopLeft(_ t: TimeInterval) -> CGPoint {
        let p = F.pointer(at: t)
        return CGPoint(x: p.x + Theme.Layout.countdownChipPointerOffset, y: p.y + Theme.Layout.countdownChipPointerOffset)
    }

    @ViewBuilder private var chip: some View {
        let since = t - F.handoff
        let leaving = t - F.chipCancel
        if since >= 0, leaving < 0.4 {
            let remaining = F.remaining(at: min(t, F.chipCancel))
            let view = CountdownChipView(kind: .eyes, remaining: remaining)
            let at = chipTopLeft(t)
            switch variant {
            case .after:
                if since < LiquidMotion.handoffDuration {
                    morph(since: since, remaining: remaining)
                } else if leaving < 0 {
                    view.offset(x: at.x, y: at.y)
                } else {
                    let p = 1 - easeIn(leaving / Theme.Motion.popupOutTimeoutDuration)
                    if p > 0 { view.modifier(LiquidPopupPose(mode: .retract, progress: p, anchorX: 0)).offset(x: at.x, y: at.y) }
                }
            case .before:
                let fade = leaving < 0 ? 0 : LiquidMotion.timingCurve(0, 0, 0.58, 1, leaving / 0.2)
                if fade < 1 { oldEntrance(view, since: since).opacity(1 - fade).offset(x: at.x, y: at.y) }
            case .reduceMotion:
                let fade = leaving < 0 ? 0 : easeInOut(leaving / 0.2)
                let p = min(easeInOut(since / 0.2), 1 - fade)
                if p > 0 { view.modifier(LiquidPopupPose(mode: .crossfade, progress: p)).offset(x: at.x, y: at.y) }
            }
        }
    }

    /// The live handoff: the same `LiquidMotion.handoff` frame and view the chip's panel draws.
    @ViewBuilder private func morph(since: TimeInterval, remaining: TimeInterval) -> some View {
        let width = Theme.Layout.nudgeSize.width
        let cardNudge = AppState.preview(.autoStart(remaining: Timing.autoStartChipAt)).nudge!
        let cardView = NudgeCardView(nudge: cardNudge, actions: .noop).fixedSize()
        let cardHeight = NSHostingView(rootView: cardView).fittingSize.height
        let at = chipTopLeft(t)
        let size = chipSize
        let padding = Double(Theme.Layout.cardPadding)
        let frame = LiquidMotion.handoff(
            at: since,
            from: MorphShape(x: cardX(width), y: F.cardTop, width: width, height: cardHeight, radius: Theme.Radius.card),
            to: MorphShape(x: at.x, y: at.y, width: size.width, height: size.height, radius: size.height / 2),
            fromBadge: .circle(x: padding, y: padding, diameter: Theme.Layout.badge),
            toBadge: .circle(x: CountdownChipView.badgeInset, y: (size.height - Theme.Layout.countdownChipBadge) / 2,
                             diameter: Theme.Layout.countdownChipBadge))
        NudgeChipMorphView(frame: frame, card: AnyView(cardView), kind: .eyes, remaining: remaining)
            .offset(x: frame.shape.x, y: frame.shape.y)
    }

    // MARK: The stretch offer that times out

    @ViewBuilder private var stretchCard: some View {
        let since = t - F.stretchIn
        let leaving = t - F.stretchOut
        let width = Theme.Layout.nudgeSize.width
        if since >= 0, leaving < 0.4 {
            let card = NudgeCardView(nudge: AppState.preview(.breakDue(.move)).nudge!, actions: .noop)
            switch variant {
            case .after:
                if leaving < 0 {
                    card.modifier(LiquidPopupPose(mode: .grow, progress: arrivalSpring(since))).offset(x: cardX(width), y: F.cardTop)
                } else {
                    let p = 1 - easeIn(leaving / Theme.Motion.popupOutTimeoutDuration)
                    if p > 0 { card.modifier(LiquidPopupPose(mode: .retract, progress: p)).offset(x: cardX(width), y: F.cardTop) }
                }
            case .before:
                let q = leaving < 0 ? 0 : easeIn(leaving / 0.35)
                if q < 1 {
                    oldEntrance(card, since: since).opacity(1 - q).offset(x: cardX(width), y: F.cardTop - 4 * q)
                }
            case .reduceMotion:
                let fade = leaving < 0 ? 0 : easeInOut(leaving / 0.2)
                let p = min(easeInOut(since / 0.2), 1 - fade)
                if p > 0 { card.modifier(LiquidPopupPose(mode: .crossfade, progress: p)).offset(x: cardX(width), y: F.cardTop) }
            }
        }
    }

    // MARK: Curves

    private func arrivalSpring(_ since: TimeInterval) -> Double {
        LiquidMotion.spring(since, response: LiquidMotion.arrivalResponse, damping: LiquidMotion.arrivalDamping)
    }

    private func easeIn(_ x: Double) -> Double { LiquidMotion.timingCurve(0.42, 0, 1, 1, x) }
    private func easeInOut(_ x: Double) -> Double { LiquidMotion.timingCurve(0.42, 0, 0.58, 1, x) }

    /// The plain entrance ("before"): from 8 pt above, 6 pt blur, fading in.
    private func oldEntrance<V: View>(_ view: V, since: TimeInterval) -> some View {
        let q = MotionFilm.oldArrival(since)
        return view.opacity(q).blur(radius: 6 * (1 - q)).offset(y: -8 * (1 - q))
    }
}

// MARK: - Strip

/// The handoff in four moments (2 × 2), cropped to the path from the card to the pointer.
@MainActor
struct MotionStrip: View {
    let variant: MotionFilm.Variant
    static let moments: [TimeInterval] = [0, 0.08, 0.16, 0.8]
    static let crop = CGRect(x: 262, y: 14, width: 624, height: 414)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(variant == .before ? "Before: the card fades, a chip appears by the pointer"
                 : "After: the card becomes the chip")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { cell(Self.moments[0]); cell(Self.moments[1]) }
                GridRow { cell(Self.moments[2]); cell(Self.moments[3]) }
            }
        }
        .padding(20)
        .background(Color(white: 0.08))
    }

    private func cell(_ moment: TimeInterval) -> some View {
        MotionScene(variant: variant, t: MotionFilm.handoff + moment, showsLabel: false)
            .offset(x: -Self.crop.minX, y: -Self.crop.minY)
            .frame(width: Self.crop.width, height: Self.crop.height, alignment: .topLeading)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(String(format: "+%.2f s", moment))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
