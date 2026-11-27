import Foundation
import Testing
@testable import BreakpointCore

@Suite("Overlay backdrop: entrance, exit and aurora (SPEC §3.3, §4.6)")
struct OverlayAtmosphereTests {
    typealias T = BackdropTimeline

    /// Samples 0…`end` in 10 ms steps.
    func samples(to end: TimeInterval) -> [TimeInterval] {
        stride(from: 0, through: end + 0.2, by: 0.01).map { $0 }
    }

    func layers(_ f: BackdropFrame) -> [Double] { [f.blur, f.vignette, f.dim, f.glow, f.bloom] }

    @Test func entranceStartsClearAndSettlesByItsEnd() {
        #expect(T.entrance(at: 0) == BackdropFrame.clear)
        #expect(T.entrance(at: -1) == BackdropFrame.clear)
        #expect(T.entrance(at: T.entranceTotal) == BackdropFrame.settled)
        #expect(T.entrance(at: T.entranceTotal + 10) == BackdropFrame.settled)
        // The backdrop is fully in when the content's last step ends (SPEC §4.6, ≈ 1.55 s).
        #expect(abs(T.entranceTotal - 1.55) < 1e-9)
    }

    @Test func entranceLayersOnlyRiseAndStayInRange() {
        var previous = BackdropFrame.clear
        for t in samples(to: T.entranceTotal) {
            let f = T.entrance(at: t)
            for (now, before) in zip(layers(f), layers(previous)) {
                #expect(now >= before - 1e-12)
                #expect((0...1).contains(now))
            }
            previous = f
        }
    }

    /// The desktop softens first, then the edges, then the whole screen darkens, then the light.
    @Test func entranceIsStagedSoftenThenDimThenLight() {
        #expect(T.blurIn.start <= T.vignetteIn.start)
        #expect(T.vignetteIn.start < T.dimIn.start)
        #expect(T.dimIn.start < T.glowIn.start)
        #expect(T.blurIn.end < T.dimIn.end)
        #expect(T.dimIn.end < T.glowIn.end)
        // A quarter of a second in: mostly soft, barely dim, no light yet.
        let early = T.entrance(at: 0.25)
        #expect(early.blur > 0.8)
        #expect(early.dim < 0.15)
        #expect(early.glow == 0)
        // The light is still gathering behind the words when the title arrives (0.55 s).
        let title = T.entrance(at: 0.55)
        #expect(title.bloom > 0 && title.bloom < 0.5)
    }

    @Test func exitStartsSettledAndEndsClear() {
        #expect(layers(T.exit(at: 0)) == layers(.settled))
        let end = T.exit(at: T.exitTotal)
        #expect(end.blur == 0 && end.vignette == 0 && end.dim == 0 && end.glow == 0)
        // The lights stay where they are while they fade.
        #expect(end.bloom == 1)
        #expect(abs(T.exitTotal - 0.75) < 1e-9)
    }

    @Test func exitLayersOnlyFall() {
        var previous = BackdropFrame.settled
        for t in samples(to: T.exitTotal) {
            let f = T.exit(at: t)
            for (now, before) in zip(layers(f), layers(previous)) {
                #expect(now <= before + 1e-12)
                #expect((0...1).contains(now))
            }
            previous = f
        }
    }

    /// Letting go is the entrance in reverse: the light goes first, the desktop focuses last.
    @Test func exitLetsGoLightFirstFocusLast() {
        #expect(T.glowOut.start <= T.dimOut.start)
        #expect(T.dimOut.start <= T.vignetteOut.start)
        #expect(T.vignetteOut.start < T.blurOut.start)
        #expect(T.glowOut.end < T.blurOut.end)
        #expect(T.dimOut.end < T.blurOut.end)
        let mid = T.exit(at: 0.4)
        #expect(mid.glow == 0)
        #expect(mid.blur > 0.5)
    }

    @Test func uniformFrameIsOneCrossFade() {
        let half = BackdropFrame(uniform: 0.5)
        #expect(half.blur == 0.5 && half.vignette == 0.5 && half.dim == 0.5 && half.glow == 0.5)
        // Reduce Motion never moves the lights.
        #expect(half.bloom == 1)
    }

    @Test func easingCurvesHoldTheirEnds() {
        for curve in [T.Ease.out, T.Ease.outCubic, T.Ease.inOut] {
            #expect(curve(0) == 0)
            #expect(abs(curve(1) - 1) < 1e-12)
            var last = 0.0
            for p in stride(from: 0.0, through: 1.0, by: 0.01) {
                #expect(curve(p) >= last - 1e-12)
                last = curve(p)
            }
        }
    }

    // MARK: Aurora

    @Test func auroraLoopsExactlyOnceAMinute() {
        #expect(AuroraField.period == 60)
        for t in [0.0, 7.3, 21, 44.9] {
            let a = AuroraField.lights(phase: AuroraField.phase(at: t))
            let b = AuroraField.lights(phase: AuroraField.phase(at: t + 60))
            for (x, y) in zip(a, b) {
                #expect(abs(x.x - y.x) < 1e-9 && abs(x.y - y.y) < 1e-9)
            }
        }
        // Phase 1 closes every path back onto phase 0.
        for (x, y) in zip(AuroraField.lights(phase: 0), AuroraField.lights(phase: 1)) {
            #expect(abs(x.x - y.x) < 1e-9 && abs(x.y - y.y) < 1e-9)
        }
        #expect(AuroraField.phase(at: -15) == 0.75)
    }

    @Test func auroraDriftsSlowlyAndStaysNearTheDisplay() {
        var previous = AuroraField.lights(phase: 0)
        for step in 1...600 {
            let lights = AuroraField.lights(phase: Double(step) / 600)
            for (now, before) in zip(lights, previous) {
                // 0.1 s apart: never more than a fraction of a percent of the display.
                #expect(hypot(now.x - before.x, now.y - before.y) < 0.003)
                #expect((-0.1...1.1).contains(now.x) && (-0.1...1.1).contains(now.y))
                #expect((0...1).contains(now.intensity))
            }
            previous = lights
        }
    }

    @Test func auroraUsesTheBrandFamilyWithMintFirst() {
        let lights = AuroraField.lights(phase: 0.3)
        #expect(lights.count == 5)
        #expect(lights.first?.hue == .mint)
        #expect(Set(lights.map(\.hue)) == Set(AuroraField.Hue.allCases))
        // The strongest light is mint (the accent); indigo never outshines it.
        let mint = lights.filter { $0.hue == .mint }.map(\.intensity).max()!
        #expect(lights.allSatisfy { $0.intensity <= mint })
    }

    @Test func auroraBloomsOutFromBehindTheWords() {
        let gathered = AuroraField.lights(phase: 0.2, bloom: 0)
        let rest = AuroraField.lights(phase: 0.2, bloom: 1)
        let centre = AuroraField.gatherPoint
        for (g, r) in zip(gathered, rest) {
            #expect(hypot(g.x - centre.x, g.y - centre.y) < hypot(r.x - centre.x, r.y - centre.y))
            #expect(g.radius < r.radius)
        }
        // Out-of-range bloom is clamped.
        #expect(AuroraField.lights(phase: 0.2, bloom: 3) == rest)
    }
}
