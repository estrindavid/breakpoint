import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

// The time rim (SPEC §3.5) frame by frame, for review:
//
//   BreakpointSnapshots --rim-film before|after|reduce-motion
//       raw RGBA frames (1280 × 720, 30 fps) on stdout, for ffmpeg:
//       … | ffmpeg -f rawvideo -pix_fmt rgba -s 1280x720 -r 30 -i - …
//   BreakpointSnapshots --rim-still VARIANT SECONDS OUT.png
//       one frame of the same film
//
// Every frame is a pure function of the film's time: the drawn desktop, a resume card and an
// away note arriving together, the pointer resting on the away note for a while, the resume card
// timing out and the away note sliding up into its place, then timing out too. The cards' motion
// uses the design system's own timings; the rim uses the same `CardCountdown` and
// `TimeRimTimeline` the live surface uses. Nothing is captured from a screen.

enum CardRimFilm {
    static let size = CGSize(width: 640, height: 360)
    static let scale: CGFloat = 2
    static let fps: Double = 30

    // The story (seconds from the film's start).
    static let arrive: TimeInterval = 0.3
    static let hoverIn: TimeInterval = 7.3
    static let hoverOut: TimeInterval = 9.5
    static let length: TimeInterval = 15.4

    enum Variant: String, CaseIterable {
        /// No rim: hover pauses invisibly, leaving restarts at half.
        case before
        /// The time rim.
        case after
        /// The time rim under Reduce Motion: the whole rim fades instead of drawing back.
        case reduceMotion = "reduce-motion"

        var hasRim: Bool { self != .before }
        var reduceMotion: Bool { self == .reduceMotion }
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
        if let i = args.firstIndex(of: "--rim-film") {
            guard i + 1 < args.count, let variant = Variant(rawValue: args[i + 1]) else {
                return Film.usage("--rim-film needs one of \(Variant.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return Film.stream(Int((length * fps).rounded()), of: variant.rawValue) { frame(variant, at: Double($0) / fps) }
        }
        if let i = args.firstIndex(of: "--rim-still") {
            guard i + 3 < args.count, let variant = Variant(rawValue: args[i + 1]), let t = Double(args[i + 2]) else {
                return Film.usage("--rim-still VARIANT SECONDS OUT.png")
            }
            return Film.writeStill(frame(variant, at: t), to: args[i + 3])
        }
        return nil
    }

    @MainActor
    static func frame(_ variant: Variant, at t: TimeInterval) -> CGImage? {
        let view = RimFilmScene(variant: variant, t: t, resumeHeight: resumeHeight)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .glassRendering(.opaque)
            .designOverrides(DesignOverrides(reduceMotion: variant.reduceMotion, reduceTransparency: false,
                                             increaseContrast: false, freezeContinuousAnimations: true))
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    /// The resume card's height, for the stack's slide when it leaves.
    @MainActor static let resumeHeight: CGFloat = {
        let view = ResumeCardView(card: BreakSnapshots.resumeContent(.one), onDismiss: {})
            .fixedSize()
            .glassRendering(.opaque)
        return NSHostingView(rootView: view).fittingSize.height
    }()
}

// MARK: - The scene

/// One frame: desktop, menu bar, the two cards where the stack puts them, and the pointer.
private struct RimFilmScene: View {
    let variant: CardRimFilm.Variant
    let t: TimeInterval
    let resumeHeight: CGFloat

    typealias F = CardRimFilm
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var full: TimeInterval { Timing.cardAutoHide }
    private var rm: Bool { variant.reduceMotion }

    // Card lifetimes.
    private var resumeTimeout: TimeInterval { F.arrive + full }
    private var noteTimeout: TimeInterval {
        // Held from hoverIn to hoverOut, then resumed with what it had (at least half).
        let left = full - (F.hoverIn - F.arrive)
        return F.hoverOut + max(left, full * Timing.cardHoverResumeFloor)
    }
    private var exitDuration: TimeInterval { PopupExit.timeout.duration(reduceMotion: rm) }
    private var slideStart: TimeInterval { resumeTimeout + exitDuration + 0.03 }

    var body: some View {
        ZStack(alignment: .top) {
            GlassDesktop(viewport: CGRect(x: 130, y: 0, width: F.size.width, height: F.size.height))
            VStack(spacing: 0) {
                Color.clear.frame(height: GlassDesktop.menuBarHeight)
                ZStack(alignment: .top) {
                    if t < resumeTimeout + exitDuration {
                        resumeCard.modifier(Presence(arrival: arrival, exit: exit(at: resumeTimeout), rm: rm))
                    }
                    if t < noteTimeout + exitDuration {
                        awayNote
                            .modifier(Presence(arrival: arrival, exit: exit(at: noteTimeout), rm: rm))
                            .offset(y: noteOffset)
                    }
                }
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
            FilmPointer()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: pointer.x, y: pointer.y)
                .opacity(t < 0.1 ? 0 : 1)
            FilmCaption(variant.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(12)
        }
        .clipped()
    }

    // MARK: Cards

    private var hovering: Bool { t >= F.hoverIn && t < F.hoverOut }

    private var resumeCard: some View {
        ResumeCardView(card: BreakSnapshots.resumeContent(.one),
                       timeRim: variant.hasRim ? .still(rimFrame(heldFrom: nil)) : nil, onDismiss: {})
    }

    private var awayNote: some View {
        AwayNoteView(note: Self.note, hovering: hovering,
                     timeRim: variant.hasRim ? .still(rimFrame(heldFrom: (F.hoverIn, F.hoverOut))) : nil,
                     onUndo: {}, onClose: {})
    }

    static let note: AwayNoteContent = {
        if case .awayNote(let note) = AppState.preview(.awayCredited).cards[0].content { return note }
        fatalError("preview has no away note")
    }()

    /// The rim as the live surface would build it: arriving, then held and resumed by the pointer.
    private func rimFrame(heldFrom hold: (TimeInterval, TimeInterval)?) -> TimeRimFrame {
        let date = { (s: TimeInterval) in base.addingTimeInterval(s) }
        var rim = TimeRimTimeline.arriving(CardCountdown(full: full, start: date(F.arrive)), at: date(F.arrive))
        if let (holdIn, holdOut) = hold, t >= holdIn {
            rim = rim.held(at: date(holdIn))
            if t >= holdOut { rim = rim.resumed(at: date(holdOut), reduceMotion: rm) }
        }
        return rim.frame(at: date(max(t, F.arrive)), reduceMotion: rm)
    }

    private var arrival: Double {
        if rm { return Film.progress(t, from: F.arrive, over: Theme.Motion.reduceMotionFade) }
        return LiquidMotion.timingCurve(0.25, 0.1, 0.25, 1, Film.progress(t, from: F.arrive, over: Theme.Motion.popupInDuration))
    }

    /// 0 → 1 over the timeout exit (ease-in).
    private func exit(at start: TimeInterval) -> Double {
        let p = Film.progress(t, from: start, over: exitDuration)
        return rm ? p : p * p
    }

    /// The away note sits under the resume card until that leaves, then slides up (0.25 s ease-out).
    private var noteOffset: CGFloat {
        let below = resumeHeight + Theme.Layout.popupStackGap
        let p = Film.progress(t, from: slideStart, over: rm ? 0 : 0.25)
        let eased = 1 - (1 - p) * (1 - p)
        return below * (1 - eased)
    }

    // MARK: Pointer

    private var pointer: CGPoint {
        let rest = CGPoint(x: 500, y: 300)
        let onNote = CGPoint(x: 300, y: GlassDesktop.menuBarHeight + 8 + resumeHeight + 8 + 26)
        let away = CGPoint(x: 540, y: 230)
        func lerp(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint {
            let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            return CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
        }
        if t < F.hoverIn - 0.9 { return rest }
        if t < F.hoverIn { return lerp(rest, onNote, Film.progress(t, from: F.hoverIn - 0.9, over: 0.9)) }
        if t < F.hoverOut - 0.05 { return onNote }
        return lerp(onNote, away, Film.progress(t, from: F.hoverOut - 0.05, over: 0.7))
    }
}

/// Arrival (from 8 pt above, 6 pt blur) and timeout exit (4 pt drift up), as values of time.
private struct Presence: ViewModifier {
    let arrival: Double
    let exit: Double
    let rm: Bool

    func body(content: Content) -> some View {
        content
            .opacity(arrival * (1 - exit))
            .offset(y: rm ? 0 : -8 * (1 - arrival) - 4 * exit)
            .blur(radius: rm ? 0 : 6 * (1 - arrival))
    }
}
