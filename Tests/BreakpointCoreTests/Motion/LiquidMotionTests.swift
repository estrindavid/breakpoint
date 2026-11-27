import Foundation
import Testing
@testable import BreakpointCore

@Suite("Liquid pop-up motion")
struct LiquidMotionTests {
    private let card = (width: 410.0, height: 122.0, radius: 28.0)

    // MARK: Curves

    @Test func springStartsAtZeroAndRests() {
        #expect(LiquidMotion.spring(0, response: 0.5, damping: 0.82) == 0)
        #expect(LiquidMotion.spring(-1, response: 0.5, damping: 0.82) == 0)
        let settled = LiquidMotion.spring(LiquidMotion.arrivalSettles, response: LiquidMotion.arrivalResponse,
                                          damping: LiquidMotion.arrivalDamping)
        #expect(abs(settled - 1) < 0.005)
    }

    @Test func arrivalSpringOvershootIsFaint() {
        // §4.6: springs never overshoot visibly. The peak stays within 1.5% of rest.
        var peak = 0.0
        for i in 0...600 {
            peak = max(peak, LiquidMotion.spring(Double(i) / 600, response: LiquidMotion.arrivalResponse,
                                                 damping: LiquidMotion.arrivalDamping))
        }
        #expect(peak > 1)
        #expect(peak < 1.015)
    }

    @Test func criticallyDampedSpringNeverOvershoots() {
        for i in 0...400 {
            #expect(LiquidMotion.spring(Double(i) / 200, response: 0.42, damping: 1) <= 1)
        }
    }

    @Test func timingCurveMatchesItsEnds() {
        #expect(LiquidMotion.timingCurve(0.42, 0, 1, 1, 0) == 0)
        #expect(abs(LiquidMotion.timingCurve(0.42, 0, 1, 1, 1) - 1) < 1e-9)
        // Ease-in: slower than linear early on.
        #expect(LiquidMotion.timingCurve(0.42, 0, 1, 1, 0.3) < 0.3)
        // Linear control points give back the input.
        #expect(abs(LiquidMotion.timingCurve(1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3, 0.37) - 0.37) < 1e-6)
    }

    // MARK: Pop-up poses

    @Test func everyModeRestsAsTheCardAtProgressOne() {
        let rest = MorphShape(x: 0, y: 0, width: card.width, height: card.height, radius: card.radius)
        for mode in [LiquidMotion.Mode.grow, .retract, .fade, .swell, .crossfade] {
            let pose = LiquidMotion.pose(mode, progress: 1, width: card.width, height: card.height, radius: card.radius)
            #expect(pose.shape == rest, "\(mode)")
            #expect(pose.isRest, "\(mode)")
        }
    }

    @Test func growStartsAsASmallCapsuleUnderTheMiddleOfTheTopEdge() {
        let pose = LiquidMotion.pose(.grow, progress: 0, width: card.width, height: card.height, radius: card.radius)
        #expect(pose.shape.y == 0)
        #expect(pose.shape.width < card.width / 3)
        #expect(pose.shape.height <= LiquidMotion.seedHeightRange.upperBound)
        #expect(abs(pose.shape.x + pose.shape.width / 2 - card.width / 2) < 1e-9)
        #expect(pose.shape.radius == pose.shape.height / 2)
        #expect(pose.shapeOpacity == 0)
        #expect(pose.contentOpacity == 0)
    }

    @Test func growSpreadsBeforeItDrops() {
        let pose = LiquidMotion.pose(.grow, progress: 0.3, width: card.width, height: card.height, radius: card.radius)
        let widthDone = (pose.shape.width - 90.2) / (card.width - 90.2)
        let heightDone = (pose.shape.height - 14) / (card.height - 14)
        #expect(widthDone > heightDone)
        // Content comes in late, once the glass is mostly open.
        #expect(pose.contentOpacity == 0)
    }

    @Test func leadingAnchorGrowsFromTheLeadingEnd() {
        let pose = LiquidMotion.pose(.grow, progress: 0.2, width: 140, height: 32, radius: 16, anchorX: 0)
        #expect(pose.shape.x == 0)
        #expect(pose.shape.width < 140)
    }

    @Test func retractFoldsUpAndDriftsUp() {
        let pose = LiquidMotion.pose(.retract, progress: 0, width: card.width, height: card.height, radius: card.radius)
        #expect(pose.shapeOpacity == 0)
        #expect(pose.shape.y == -LiquidMotion.retractDrift)
        #expect(pose.shape.height < card.height / 4)
        // Half-way out, the words have gone and the glass is still there.
        let half = LiquidMotion.pose(.retract, progress: 0.4, width: card.width, height: card.height, radius: card.radius)
        #expect(half.contentOpacity == 0)
        #expect(half.shapeOpacity == 1)
    }

    @Test func fadeSettlesAndSwellGrows() {
        let fade = LiquidMotion.pose(.fade, progress: 0, width: card.width, height: card.height, radius: card.radius)
        #expect(fade.opacity == 0)
        #expect(fade.scale == LiquidMotion.fadeScale)
        let swell = LiquidMotion.pose(.swell, progress: 0, width: card.width, height: card.height, radius: card.radius)
        #expect(swell.scale == LiquidMotion.swellScale)
    }

    @Test func crossfadeOnlyChangesOpacity() {
        for p in stride(from: 0.0, through: 1.0, by: 0.25) {
            let pose = LiquidMotion.pose(.crossfade, progress: p, width: card.width, height: card.height, radius: card.radius)
            #expect(pose.scale == 1)
            #expect(pose.contentBlur == 0)
            #expect(pose.contentOffsetY == 0)
            #expect(pose.shape.width == card.width)
            #expect(pose.opacity == p)
        }
    }

    @Test func radiusNeverExceedsHalfTheHeight() {
        for i in 0...50 {
            let pose = LiquidMotion.pose(.grow, progress: Double(i) / 50, width: card.width, height: card.height, radius: card.radius)
            #expect(pose.shape.radius <= pose.shape.height / 2 + 1e-9)
        }
    }

    // MARK: Handoff

    private let from = MorphShape(x: 551, y: 920, width: 410, height: 122, radius: 28)
    private let to = MorphShape(x: 1020, y: 400, width: 140, height: 32, radius: 16)
    private let fromBadge = MorphShape.circle(x: 14, y: 14, diameter: 44)
    private let toBadge = MorphShape.circle(x: 5, y: 5, diameter: 22)

    @Test func handoffStartsAsTheCardAndEndsAsTheChip() {
        let start = LiquidMotion.handoff(at: 0, from: from, to: to, fromBadge: fromBadge, toBadge: toBadge)
        #expect(start.shape == from)
        #expect(start.badge == fromBadge)
        #expect(start.cardOpacity == 1)
        #expect(start.chipOpacity == 0)
        #expect(!start.finished)
        let end = LiquidMotion.handoff(at: LiquidMotion.handoffDuration, from: from, to: to, fromBadge: fromBadge, toBadge: toBadge)
        #expect(end.shape == to)
        #expect(end.badge == toBadge)
        #expect(end.chipOpacity == 1)
        #expect(end.finished)
    }

    @Test func handoffIsAlmostAtRestBeforeItFinishes() {
        let late = LiquidMotion.handoff(at: LiquidMotion.handoffDuration - 1.0 / 60, from: from, to: to,
                                        fromBadge: fromBadge, toBadge: toBadge)
        #expect(abs(late.shape.x - to.x) < 1)
        #expect(abs(late.shape.y - to.y) < 1)
        #expect(abs(late.shape.width - to.width) < 1)
    }

    @Test func handoffGathersHeightBeforeItArrives() {
        let early = LiquidMotion.handoff(at: 0.15, from: from, to: to, fromBadge: fromBadge, toBadge: toBadge)
        let heightDone = (from.height - early.shape.height) / (from.height - to.height)
        let glideDone = (early.shape.x - from.x) / (to.x - from.x)
        #expect(heightDone > glideDone)
        #expect(early.shape.radius <= early.shape.height / 2 + 1e-9)
    }

    @Test func cardWordsAreGoneBeforeTheChipsArrive() {
        let t = LiquidMotion.handoffCardFade
        let frame = LiquidMotion.handoff(at: t, from: from, to: to, fromBadge: fromBadge, toBadge: toBadge)
        #expect(frame.cardOpacity == 0)
        #expect(frame.chipOpacity == 0)
    }
}
