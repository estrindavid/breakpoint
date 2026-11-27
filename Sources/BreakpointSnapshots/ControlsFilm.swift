import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

// Buttons under the pointer (SPEC §3.0 "Buttons", §4.6 "Controls"), frame by frame, for review:
//
//   BreakpointSnapshots --controls-film after|before|reduce-motion
//       raw RGBA frames (1280 × 600, 60 fps) on stdout, for ffmpeg (the card and the pointer stay
//       inside crop=880:330:380:16, for a close-up):
//       … | ffmpeg -f rawvideo -pix_fmt rgba -s 1280x600 -r 60 -i - …
//   BreakpointSnapshots --controls-still VARIANT SECONDS OUT.png
//       one frame of the same film
//
// Every frame is a pure function of the film's time: the drawn desktop, the real `NudgeCardView`
// in its hover state at the top right, and a pointer that
// crosses Start, clicks it, crosses Not now and holds it down, then leaves. Each button's state
// comes from the same springs the live style uses (`Theme.Motion`), integrated here and handed
// to the real `PillButton` through `controlResponsePreviews`; nothing is captured from a screen.
//
// `before` feeds the same pointer through plain timings instead of springs: the hover fill
// switches at once and a press eases over 0.12 s, with the light held still at the centre.

enum ControlsFilm {
    static let scene = CGSize(width: 640, height: 300)
    static let scale: CGFloat = 2
    static let fps: Double = 60
    static let length: TimeInterval = 6.4
    static let cardOrigin = CGPoint(x: 206, y: 22)

    enum Variant: String, CaseIterable {
        case before, after
        case reduceMotion = "reduce-motion"

        var caption: String {
            switch self {
            case .before: return "Before"
            case .after: return "After"
            case .reduceMotion: return "After, Reduce Motion"
            }
        }
    }

    // MARK: Entry points

    @MainActor
    static func run(_ args: [String]) -> Int32? {
        if let i = args.firstIndex(of: "--controls-film") {
            guard i + 1 < args.count, let variant = Variant(rawValue: args[i + 1]) else {
                return Film.usage("--controls-film needs one of \(Variant.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let layout = FilmLayout.measure()
            var sim = Simulation(variant: variant, layout: layout)
            return Film.stream(Int((length * fps).rounded()), of: variant.rawValue) { index in
                let t = Double(index) / fps
                sim.advance(to: t)
                return frame(variant, sim: sim, layout: layout, at: t)
            }
        }
        if let i = args.firstIndex(of: "--controls-still") {
            guard i + 3 < args.count, let variant = Variant(rawValue: args[i + 1]), let t = Double(args[i + 2]) else {
                return Film.usage("--controls-still VARIANT SECONDS OUT.png")
            }
            let layout = FilmLayout.measure()
            var sim = Simulation(variant: variant, layout: layout)
            sim.advance(to: t)
            return Film.writeStill(frame(variant, sim: sim, layout: layout, at: t), to: args[i + 3])
        }
        return nil
    }

    @MainActor
    private static func frame(_ variant: Variant, sim: Simulation, layout: FilmLayout, at t: TimeInterval) -> CGImage? {
        let view = FilmFrame(variant: variant, responses: sim.responses, pointer: Pointer.position(at: t, layout: layout),
                             pressed: Pointer.isDown(at: t))
            .frame(width: scene.width, height: scene.height)
            .environment(\.colorScheme, .dark)
            .glassRendering(.opaque)
            .designOverrides(DesignOverrides(reduceMotion: variant == .reduceMotion, reduceTransparency: false,
                                             increaseContrast: false, freezeContinuousAnimations: true))
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }
}

// MARK: - Layout

/// Where the nudge's two buttons sit in the scene, measured from the real components.
private struct FilmLayout {
    var start: CGRect
    var notNow: CGRect

    @MainActor static var nudge: NudgeState { AppState.preview(.breakDue(.move)).nudge! }

    @MainActor
    static func measure() -> FilmLayout {
        func size(_ view: some View) -> CGSize {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).glassRendering(.opaque))
            renderer.scale = 1
            guard let image = renderer.cgImage else { return .zero }
            return CGSize(width: image.width, height: image.height)
        }
        let card = size(NudgeCardView(nudge: nudge, actions: .noop, revealed: true, onClose: {}))
        let startSize = size(PillButton("Start", role: .primary, keycap: HotKeyCombo.nudgeStart.display) {})
        let notNowSize = size(PillButton("Not now", role: .secondary, keycap: HotKeyCombo.nudgeDismiss.display) {})
        // Row 2 of the card (SPEC §3.1): aligned to the text column, padding 14 from the bottom.
        let x = ControlsFilm.cardOrigin.x + Theme.Layout.cardPadding + Theme.Layout.badge + Theme.Layout.badgeToText
        let y = ControlsFilm.cardOrigin.y + card.height - Theme.Layout.cardPadding - Theme.Layout.buttonHeight
        let start = CGRect(x: x, y: y, width: startSize.width, height: Theme.Layout.buttonHeight)
        let notNow = CGRect(x: start.maxX + Theme.Layout.buttonGap, y: y, width: notNowSize.width,
                            height: Theme.Layout.buttonHeight)
        return FilmLayout(start: start, notNow: notNow)
    }
}

// MARK: - The pointer's path

private enum Pointer {
    /// (time, point in the scene); eased between stops.
    static func stops(_ layout: FilmLayout) -> [(TimeInterval, CGPoint)] {
        let s = layout.start, n = layout.notNow
        return [
            (0.0, CGPoint(x: 596, y: 162)),
            (0.4, CGPoint(x: 596, y: 162)),
            (1.2, CGPoint(x: s.minX + s.width * 0.18, y: s.midY + 5)),
            (2.0, CGPoint(x: s.minX + s.width * 0.62, y: s.midY - 2)),
            (2.9, CGPoint(x: s.minX + s.width * 0.62, y: s.midY - 2)),
            (3.6, CGPoint(x: n.minX + n.width * 0.3, y: n.midY + 3)),
            (4.1, CGPoint(x: n.minX + n.width * 0.55, y: n.midY)),
            (5.1, CGPoint(x: n.minX + n.width * 0.55, y: n.midY)),
            (5.7, CGPoint(x: 600, y: 160)),
            (ControlsFilm.length, CGPoint(x: 600, y: 160)),
        ]
    }

    /// Mouse button down: a click on Start, then a longer hold on Not now.
    static let downs: [ClosedRange<TimeInterval>] = [2.25...2.42, 4.35...4.85]

    static func isDown(at t: TimeInterval) -> Bool { downs.contains { $0.contains(t) } }

    static func position(at t: TimeInterval, layout: FilmLayout) -> CGPoint {
        let list = stops(layout)
        guard let next = list.firstIndex(where: { $0.0 > t }) else { return list.last!.1 }
        guard next > 0 else { return list[0].1 }
        let (t0, p0) = list[next - 1], (t1, p1) = list[next]
        let u = (t - t0) / (t1 - t0)
        let e = u * u * (3 - 2 * u)
        return CGPoint(x: p0.x + (p1.x - p0.x) * e, y: p0.y + (p1.y - p0.y) * e)
    }
}

// MARK: - The buttons' state over time

/// A damped spring as SwiftUI's `spring(response:dampingFraction:)` defines it.
private struct SpringValue {
    var value: Double
    var velocity: Double = 0

    mutating func step(toward target: Double, response: Double, damping: Double, dt: Double) {
        let stiffness = pow(2 * .pi / response, 2)
        let friction = 4 * .pi * damping / response
        let steps = 10
        let h = dt / Double(steps)
        for _ in 0..<steps {
            velocity += (-stiffness * (value - target) - friction * velocity) * h
            value += velocity * h
        }
    }
}

/// A timed ease from one value to another (the "before" press, and Reduce Motion fades).
private struct Tween {
    var from: Double = 0
    var to: Double = 0
    var start: TimeInterval = -10
    let duration: TimeInterval
    let easeInOut: Bool

    func value(at t: TimeInterval) -> Double {
        let u = min(max((t - start) / duration, 0), 1)
        let e = easeInOut ? u * u * (3 - 2 * u) : 1 - (1 - u) * (1 - u)
        return from + (to - from) * e
    }

    mutating func retarget(_ target: Double, at t: TimeInterval) {
        guard target != to else { return }
        from = value(at: t)
        to = target
        start = t
    }
}

private struct ButtonSim {
    let rect: CGRect
    var hover = SpringValue(value: 0)
    var press = SpringValue(value: 0)
    var x = SpringValue(value: 0.5)
    var y = SpringValue(value: 0.5)
    var hoverTween: Tween
    var pressTween: Tween
    var wasInside = false

    init(rect: CGRect, variant: ControlsFilm.Variant) {
        self.rect = rect
        let fade = variant == .reduceMotion
        hoverTween = Tween(duration: fade ? 0.15 : 0.0001, easeInOut: true)
        pressTween = Tween(duration: fade ? 0.15 : 0.12, easeInOut: fade)
    }

    func response(_ variant: ControlsFilm.Variant, at t: TimeInterval) -> ControlResponse {
        switch variant {
        case .after:
            return ControlResponse(hover: hover.value, press: press.value, location: UnitPoint(x: x.value, y: y.value))
        case .before, .reduceMotion:
            return ControlResponse(hover: hoverTween.value(at: t), press: pressTween.value(at: t),
                                   location: Theme.Motion.stillLightLocation)
        }
    }
}

private struct Simulation {
    let variant: ControlsFilm.Variant
    let layout: FilmLayout
    var buttons: [String: ButtonSim]
    var time: TimeInterval = 0

    init(variant: ControlsFilm.Variant, layout: FilmLayout) {
        self.variant = variant
        self.layout = layout
        buttons = ["Start": ButtonSim(rect: layout.start, variant: variant),
                   "Not now": ButtonSim(rect: layout.notNow, variant: variant)]
    }

    var responses: [String: ControlResponse] { buttons.mapValues { $0.response(variant, at: time) } }

    /// Steps the springs at 600 Hz up to `t`.
    mutating func advance(to t: TimeInterval) {
        let dt = 1.0 / 600
        while time + dt <= t + 1e-9 {
            time += dt
            step(dt)
        }
    }

    private mutating func step(_ dt: Double) {
        let point = Pointer.position(at: time, layout: layout)
        let down = Pointer.isDown(at: time)
        for key in buttons.keys {
            var b = buttons[key]!
            let capsule = Path(roundedRect: b.rect, cornerRadius: b.rect.height / 2)
            let inside = capsule.contains(point)
            let pressed = inside && down
            let unitX = min(max((point.x - b.rect.minX) / b.rect.width, 0), 1)
            let unitY = min(max((point.y - b.rect.minY) / b.rect.height, 0), 1)
            if inside && !b.wasInside {
                // The light comes up where the pointer enters.
                b.x = SpringValue(value: unitX)
                b.y = SpringValue(value: unitY)
            } else if inside {
                b.x.step(toward: unitX, response: 0.22, damping: 1, dt: dt)
                b.y.step(toward: unitY, response: 0.22, damping: 1, dt: dt)
            }
            b.hover.step(toward: inside ? 1 : 0, response: inside ? 0.28 : 0.4, damping: inside ? 0.9 : 1, dt: dt)
            b.press.step(toward: pressed ? 1 : 0, response: pressed ? 0.16 : 0.34, damping: pressed ? 0.86 : 0.8, dt: dt)
            b.hoverTween.retarget(inside ? 1 : 0, at: time)
            b.pressTween.retarget(pressed ? 1 : 0, at: time)
            b.wasInside = inside
            buttons[key] = b
        }
    }
}

// MARK: - The frame

private struct FilmFrame: View {
    let variant: ControlsFilm.Variant
    let responses: [String: ControlResponse]
    let pointer: CGPoint
    let pressed: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassDesktop(viewport: CGRect(x: 130, y: 0, width: ControlsFilm.scene.width,
                                          height: ControlsFilm.scene.height))
            NudgeCardView(nudge: FilmLayout.nudge, actions: .noop, revealed: true, onClose: {})
                .fixedSize()
                .controlResponsePreviews(responses)
                .offset(x: ControlsFilm.cardOrigin.x, y: ControlsFilm.cardOrigin.y)
            FilmPointer()
                .scaleEffect(pressed ? 0.92 : 1, anchor: .topLeading)
                .offset(x: pointer.x, y: pointer.y)
            FilmCaption(variant.caption)
                .offset(x: 212, y: 150)
        }
        .frame(width: ControlsFilm.scene.width, height: ControlsFilm.scene.height, alignment: .topLeading)
        .clipped()
    }
}
