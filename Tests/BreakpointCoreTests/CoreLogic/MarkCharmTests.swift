import Foundation
import Testing
@testable import BreakpointCore

/// The mark's one-shot movements and the rare lines in debugger voice (SPEC §3.7, §3.11, §4.1).
@Suite("Mark movements and debugger voice")
struct MarkCharmTests {
    // MARK: Which change earns which movement

    @Test func cuesFollowWhatHappened() {
        let working = MarkFacts(agent: .working)
        let none = MarkFacts()
        let needsYou = MarkFacts(agent: .needsYou)
        #expect(MarkCuePolicy.cue(from: working, to: none, runFinished: true) == .settle)
        // A run that was interrupted, failed, went stale or whose session ended is not "finished".
        #expect(MarkCuePolicy.cue(from: working, to: none, runFinished: false) == nil)
        // Another agent is still working: the dot stays.
        #expect(MarkCuePolicy.cue(from: working, to: working, runFinished: true) == nil)
        #expect(MarkCuePolicy.cue(from: working, to: needsYou, runFinished: false) == .lift)
        #expect(MarkCuePolicy.cue(from: none, to: needsYou, runFinished: false) == .lift)
        #expect(MarkCuePolicy.cue(from: needsYou, to: needsYou, runFinished: false) == nil)
        // Needs you wins over a finish in the same moment.
        #expect(MarkCuePolicy.cue(from: working, to: needsYou, runFinished: true) == .lift)

        let wrapped = MarkFacts(paused: true, wrappedUp: true)
        #expect(MarkCuePolicy.cue(from: none, to: wrapped, runFinished: false) == .fold)
        // Already showing the single bar (a call pause): nothing to fold.
        #expect(MarkCuePolicy.cue(from: MarkFacts(paused: true), to: wrapped, runFinished: false) == nil)
        // A manual pause is not the end of the day.
        #expect(MarkCuePolicy.cue(from: none, to: MarkFacts(paused: true), runFinished: false) == nil)
        // Nothing happened: nothing moves.
        #expect(MarkCuePolicy.cue(from: none, to: none, runFinished: false) == nil)
    }

    // MARK: Poses

    @Test func everyMovementStartsAtRestAndEndsInTheNewState() {
        for cue in MarkCue.allCases {
            #expect(MarkMotion.pose(cue, progress: 0) == .rest, "\(cue)")
        }
        #expect(MarkMotion.pose(.settle, progress: 1) == MarkPose(dotTravel: 1, dotScale: 0))
        #expect(MarkMotion.pose(.lift, progress: 1) == .rest)
        #expect(MarkMotion.pose(.fold, progress: 1) == MarkPose(fold: 1))
        // Out-of-range progress clamps (a late timer never overshoots).
        #expect(MarkMotion.pose(.fold, progress: 1.4) == MarkPose(fold: 1))
        #expect(MarkMotion.pose(.lift, progress: -1) == .rest)
    }

    @Test func liftGrowsAboutAPointAndSettles() {
        let frames = (0...60).map { MarkMotion.pose(.lift, progress: Double($0) / 60).barLift }
        let peak = frames.max() ?? 0
        #expect(abs(peak - MarkMotion.liftHeight) < 0.01)
        // The menu-bar mark is drawn at 18 pt × 0.72 over 13.5 grid units ≈ 0.96 pt per unit.
        let points = peak * (18 * 0.72 / 13.5)
        #expect(points > 0.8 && points < 1.3, "\(points) pt")
        #expect(frames.allSatisfy { $0 >= 0 })
        // One rise, one fall: no bounce.
        let peakIndex = frames.firstIndex(of: peak) ?? 0
        #expect(zip(frames[..<peakIndex], frames[1...peakIndex]).allSatisfy { $0 <= $1 })
        #expect(zip(frames[peakIndex...], frames[(peakIndex + 1)...]).allSatisfy { $0 >= $1 })
    }

    @Test func settleAndFoldMoveOneWay() {
        let settle = (0...40).map { MarkMotion.pose(.settle, progress: Double($0) / 40) }
        #expect(zip(settle, settle.dropFirst()).allSatisfy { $0.dotTravel <= $1.dotTravel && $0.dotScale >= $1.dotScale })
        #expect(settle.allSatisfy { $0.barLift == 0 && $0.fold == 0 })
        let fold = (0...40).map { MarkMotion.pose(.fold, progress: Double($0) / 40).fold }
        #expect(zip(fold, fold.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(MarkMotion.keyFrames(.fold, count: 5).count == 5)
        #expect(MarkMotion.keyFrames(.fold, count: 5).last == MarkPose(fold: 1))
    }

    @Test func onboardingHopGoesUpFourPointsOnce() {
        let offsets = (0...50).map { MarkMotion.hopOffset(progress: Double($0) / 50) }
        #expect(offsets.first == 0 && offsets.last == 0)
        #expect(abs((offsets.min() ?? 0) + 4) < 0.01)
        #expect(offsets.allSatisfy { $0 <= 0 })
    }

    // MARK: Debugger voice: rare, and inside the copy rules

    @Test func debuggerLinesAreAtMostOneInFiveOfARotation() {
        for kind in BreakKind.allCases {
            let variants = BreakCopyLibrary.copy(for: kind).variants
            let debugger = variants.filter { Copy.debuggerVoice.contains($0.title) }
            #expect(debugger.count * 5 <= variants.count, "\(kind): \(debugger.count) of \(variants.count)")
            // Over any run of rotations, never two within five breaks of the same kind.
            let shown = (0..<100).map { Copy.debuggerVoice.contains(BreakCopyLibrary.copy(for: kind).variant(rotation: $0).title) }
            for start in 0..<(shown.count - 4) {
                #expect(shown[start..<(start + 5)].filter { $0 }.count <= 1, "\(kind) at rotation \(start)")
            }
        }
        let nightly = Copy.wrappedUpDetails.filter { Copy.debuggerVoice.contains($0) }
        #expect(nightly.count * 5 <= Copy.wrappedUpDetails.count)
        // Every debugger line in a break table is really in it (no stale entries in the set).
        let titles = Set(BreakKind.allCases.flatMap { BreakCopyLibrary.copy(for: $0).variants.map(\.title) })
        for line in Copy.debuggerVoice where !line.hasSuffix(".") {
            #expect(titles.contains(line), "\(line)")
        }
    }

    @Test func debuggerLinesNeverReachTheNudge() {
        for kind in BreakKind.allCases {
            for length in [20.0, 60, 120, 300, 360, 600] {
                #expect(!Copy.debuggerVoice.contains(Copy.nudgeTitle(kind: kind, length: length)))
            }
        }
    }

    @Test func debuggerLinesFollowTheWordingRules() {
        for line in Copy.debuggerVoice.union(Copy.wrappedUpDetails) {
            #expect(!line.contains("!"))
            #expect(!line.lowercased().split { !$0.isLetter }.contains("should"))
            #expect(!line.lowercased().contains("look away"))
            #expect(line.split(separator: " ").count <= 12)
        }
        for title in Copy.debuggerVoice where !title.hasSuffix(".") {
            #expect((2...5).contains(title.split(separator: " ").count), "\(title)")
        }
    }

    @Test func oneWrappedUpLinePerNight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixture.utc
        let evening = Fixture.date(23, 30)
        let small = Fixture.date(2, 0, day: 23)        // the same night, after midnight
        let next = Fixture.date(23, 30, day: 23)
        #expect(Copy.wrappedUpDetail(now: evening, calendar: calendar) == Copy.wrappedUpDetail(now: small, calendar: calendar))
        #expect(Copy.wrappedUpDetail(now: evening, calendar: calendar) != Copy.wrappedUpDetail(now: next, calendar: calendar))
        let nights = (0..<10).map { Copy.wrappedUpDetail(now: evening.addingTimeInterval(Double($0) * 86_400), calendar: calendar) }
        #expect(Set(nights).count == Copy.wrappedUpDetails.count)
    }
}
