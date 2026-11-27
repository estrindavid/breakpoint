import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.3 Ending, §4.6 (completion moment).

/// The closing moment of a completed break as pure functions of the seconds since it completed,
/// so the live overlay and the snapshots draw the same frames (like `OverlayFrame`).
///
/// | t (s) | Event |
/// |---|---|
/// | 0.00 | instruction, kind line, guide, controls and hint fade out over 0.2 s; the title fades out over 0.15 s |
/// | 0.00 | the ring closes from where it was to full over 0.45 s (ease-in-out) |
/// | 0.15 | the closing line fades in over 0.15 s |
/// | 0.30 | the check draws over 0.3 s (ease-out) and the disc fills mint 20% |
/// | 1.20 | `Timing.completionMoment`: the normal exit begins |
///
/// Reduce Motion: no sweep or draw; in one 0.2 s cross-fade the break's content fades out (0.1 s),
/// then the closed ring with its check and the closing line fade in (0.1 s).
public struct CompletionFrame: Equatable, Sendable {
    /// Opacity of what the break showed (instruction, kind line, guide, controls, hint).
    public var content: Double = 1
    /// Opacity of the break's own title.
    public var title: Double = 1
    /// Opacity of the closing line.
    public var line: Double = 0
    /// Opacity of the completion mark.
    public var mark: Double = 0
    /// How far the ring has closed from its starting point, 0…1.
    public var ring: Double = 0
    /// How much of the check is drawn, 0…1.
    public var check: Double = 0

    public init() {}

    public static func at(_ t: TimeInterval, reduceMotion: Bool) -> CompletionFrame {
        typealias M = Theme.Motion
        func progress(_ start: TimeInterval, _ duration: TimeInterval) -> Double {
            OverlayFrame.progress(t, start: start, duration: duration)
        }
        var f = CompletionFrame()
        if reduceMotion {
            // Out, then in, so two titles never sit on top of each other.
            let out = progress(0, M.reduceMotionFade / 2), into = progress(M.reduceMotionFade / 2, M.reduceMotionFade / 2)
            f.content = 1 - out; f.title = 1 - out; f.line = into; f.mark = into; f.ring = 1; f.check = 1
            return f
        }
        let half = M.completionTitleSwap / 2
        f.content = 1 - CubicBezier.easeOut(progress(0, M.completionFade))
        f.title = 1 - CubicBezier.easeOut(progress(0, half))
        f.line = CubicBezier.easeOut(progress(half, half))
        f.mark = 1
        f.ring = CubicBezier.easeInOut(progress(0, M.completionRingClose))
        f.check = CubicBezier.easeOut(progress(M.completionCheckAt, M.completionCheckDraw))
        return f
    }
}

/// The ring closing into a mint check: the kind's ring (or a 64 pt one on `eyes`) drawn as a
/// `LuminousRing`, its arc running from `startProgress` to full with the glow leading, then a
/// check drawn inside over a 20% mint disc.
public struct CompletionMark: View {
    private let diameter: CGFloat
    private let lineWidth: CGFloat
    private let startProgress: Double
    private let frame: CompletionFrame

    public init(diameter: CGFloat, lineWidth: CGFloat, startProgress: Double, frame: CompletionFrame) {
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.startProgress = startProgress
        self.frame = frame
    }

    /// The mark for a kind: its size, stroke and where its ring stood when the break completed.
    public static func `for`(_ activeBreak: ActiveBreakState, frame: CompletionFrame) -> CompletionMark {
        typealias L = Theme.Layout
        switch activeBreak.kind {
        case .eyes:
            return CompletionMark(diameter: L.completionMarkEyes, lineWidth: L.walkRingStroke, startProgress: 0, frame: frame)
        case .walk:
            return CompletionMark(diameter: L.walkRing, lineWidth: L.walkRingStroke, startProgress: activeBreak.progress,
                                  frame: frame)
        case .breathe:
            return CompletionMark(diameter: L.breatheRing, lineWidth: L.breatheRingStroke, startProgress: 1, frame: frame)
        case .move:
            var start = 1.0
            if let step = activeBreak.step {
                if let pace = TempoPacing.frame(tempo: step.step.tempo, at: min(step.elapsed, step.step.duration - 0.001)) {
                    start = pace.motion == .around ? 0 : pace.fullness
                } else {
                    start = step.progress
                }
            }
            return CompletionMark(diameter: L.moveRing, lineWidth: L.moveRingStroke, startProgress: start, frame: frame)
        }
    }

    public var body: some View {
        let closed = startProgress + (1 - startProgress) * frame.ring
        // The same luminous ring the break drew, so the close reads as that ring finishing.
        return LuminousRing(progress: min(max(closed, 0), 1), lineWidth: lineWidth) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.mint.opacity(0.20 * frame.check))
                    .padding(lineWidth)
                CheckShape()
                    .trim(from: 0, to: CGFloat(frame.check))
                    .stroke(Theme.Colors.mint, style: StrokeStyle(lineWidth: lineWidth * Theme.Layout.completionCheckStroke,
                                                                  lineCap: .round, lineJoin: .round))
                    .frame(width: diameter * Theme.Layout.completionCheckWidth,
                           height: diameter * Theme.Layout.completionCheckWidth * 0.75)
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(frame.mark)
        .accessibilityElement()
        .accessibilityLabel("Break complete")
    }
}

/// A check mark in its frame: short stroke down to the lower third, long stroke up to the corner.
struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
