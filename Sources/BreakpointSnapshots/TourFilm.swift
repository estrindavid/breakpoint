import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

// The one-minute tour as a film (SPEC §3.12): every step on a drawn desktop, in the place the app
// puts it (coach cards hanging from the menu-bar mark, the nudge and the resume card under the
// menu bar, the break screen over everything, the popover under the mark), then, after a caption,
// the two hints someone who took the tour still meets in later real use (the first call pause and
// the first eye rest that starts by itself). Every frame is a pure
// function of the film's time, drawn with the real views; nothing is captured from a screen. The
// glass is the snapshots' opaque approximation.
//
//   BreakpointSnapshots --tour-film                 raw RGBA frames (1512 × 982, 12 fps) on stdout:
//       … | ffmpeg -f rawvideo -pix_fmt rgba -s 1512x982 -r 12 -i - …
//   BreakpointSnapshots --tour-still SECONDS OUT.png
//   BreakpointSnapshots --tour-strip DIR            one PNG per step, at the moments listed in `strip`

@MainActor
enum TourFilm {
    static let size = OverlayFilm.size
    static let fps = 12.0
    /// The drawn desktop's zoom: its menu bar comes out about as tall as a real one (31 pt).
    static let zoom: CGFloat = 1.2
    static let menuBarHeight: CGFloat = GlassDesktop.menuBarHeight * zoom
    /// The mark's centre in the menu bar, just left of the desktop's clock.
    static let markX: CGFloat = {
        let clock = ("Sun 22 Nov  14:05" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return (size.width - (16 + clock + 24) * zoom).rounded()
    }()
    static func desktop() -> FilmDesktop { FilmDesktop(size: size, zoom: zoom) }

    enum Scene: Equatable {
        case offer, mark, nudge, breakScreen, resume, popover(TourPopoverPart), farewell
        /// The film's own caption between the tour and later use (not part of the app).
        case later
        /// Later, in real use: the first call pause, with its hint.
        case laterCallPause
        /// Later, in real use: the first eye rest that starts by itself, with its hint.
        case laterAutoStart
    }

    struct Beat {
        var scene: Scene
        var start: TimeInterval
        var length: TimeInterval
        var end: TimeInterval { start + length }
    }

    static let beats: [Beat] = {
        var t: TimeInterval = 0.4
        var list: [Beat] = []
        func add(_ scene: Scene, _ length: TimeInterval) {
            list.append(Beat(scene: scene, start: t, length: length))
            t += length
        }
        add(.offer, 3.0)
        add(.mark, 3.6)
        add(.nudge, 3.4)
        add(.breakScreen, 9.0)
        add(.resume, 3.2)
        for part in TourPopoverPart.allCases { add(.popover(part), 1.9) }
        add(.farewell, 3.4)
        add(.later, 1.6)
        add(.laterCallPause, 3.4)
        add(.laterAutoStart, 4.2)
        return list
    }()

    static var length: TimeInterval { (beats.last?.end ?? 0) + 0.6 }

    /// Moments for the pull request's strip of pictures, one per step.
    static var strip: [(String, TimeInterval)] {
        func middle(_ scene: Scene, _ fraction: Double = 0.6) -> TimeInterval {
            let beat = beats.first { $0.scene == scene }!
            return beat.start + beat.length * fraction
        }
        return [("1-offer", middle(.offer)), ("2-mark", middle(.mark)), ("3-nudge", middle(.nudge, 0.5)),
                ("4a-break-working", middle(.breakScreen, 0.3)), ("4b-break-done", middle(.breakScreen, 0.75)),
                ("5-resume", middle(.resume)), ("6a-popover-status", middle(.popover(.status))),
                ("6b-popover-actions", middle(.popover(.actions))), ("6c-popover-totals", middle(.popover(.totals))),
                ("6d-popover-gear", middle(.popover(.gear))), ("7-farewell", middle(.farewell)),
                ("8a-later-call-pause", middle(.laterCallPause)), ("8b-later-autostart", middle(.laterAutoStart, 0.45))]
    }

    // MARK: Entry point

    static func run(_ args: [String]) -> Int32? {
        if args.contains("--tour-film") {
            let desktop = Self.desktop()
            let frames = Int((length * fps).rounded())
            let out = FileHandle.standardOutput
            for index in 0..<frames {
                guard let image = render(at: Double(index) / fps, desktop: desktop), let bytes = Film.rgba(image, opaque: true) else {
                    FileHandle.standardError.write(Data("could not render frame \(index)\n".utf8))
                    return 1
                }
                out.write(bytes)
            }
            return 0
        }
        if let i = args.firstIndex(of: "--tour-still") {
            guard i + 2 < args.count, let t = Double(args[i + 1]) else { return usage() }
            return write(at: t, to: URL(fileURLWithPath: args[i + 2]), desktop: Self.desktop())
        }
        if let i = args.firstIndex(of: "--tour-strip") {
            guard i + 1 < args.count else { return usage() }
            let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let desktop = Self.desktop()
            for (name, t) in strip {
                let url = folder.appendingPathComponent("\(name).png")
                if write(at: t, to: url, desktop: desktop) != 0 { return 1 }
                print(url.path)
            }
            return 0
        }
        return nil
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("usage: --tour-film | --tour-still SECONDS OUT.png | --tour-strip DIR\n".utf8))
        return 2
    }

    private static func write(at t: TimeInterval, to url: URL, desktop: FilmDesktop) -> Int32 {
        guard let image = render(at: t, desktop: desktop) else { return 1 }
        do {
            try SnapshotRenderingEngine.writePNG(image, to: url)
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    static func render(at t: TimeInterval, desktop: FilmDesktop) -> CGImage? {
        let renderer = ImageRenderer(content: frame(at: t, desktop: desktop))
        renderer.scale = 1
        return renderer.cgImage
    }

    // MARK: A frame

    static func frame(at t: TimeInterval, desktop: FilmDesktop) -> some View {
        let beat = beats.last { $0.start <= t && t < $0.end }
        let local = beat.map { t - $0.start } ?? 0
        let opacity = beat.map { fade(local, length: $0.length) } ?? 0
        return ZStack(alignment: .topLeading) {
            Image(decorative: desktop.sharp, scale: 1)
            menuBar(beat?.scene)
            if let beat {
                scene(beat, at: local, desktop: desktop)
                    // Faded as one picture, as the app fades its cards: glass, rim and shadow never
                    // show through each other mid-fade.
                    .compositingGroup()
                    .opacity(beat.scene == .breakScreen ? 1 : opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
        .glassRendering(.opaque)
        .designOverrides(DesignOverrides(reduceMotion: false, reduceTransparency: false, increaseContrast: false,
                                         freezeContinuousAnimations: true))
    }

    /// In over 0.35 s, out over the last 0.25 s.
    private static func fade(_ local: TimeInterval, length: TimeInterval) -> Double {
        min(1, max(0, local / 0.35), max(0, (length - local) / 0.25))
    }

    /// The menu bar over the desktop's own: the Breakpoint mark showing the sample's state, lit
    /// while the popover hangs from it.
    private static func menuBar(_ scene: Scene?) -> some View {
        var variant: BrandMark.Variant = .idle
        var badge: BrandMark.Badge = .none
        var lit = false
        switch scene {
        case .mark?, .nudge?: variant = .due; badge = .working
        case .popover?: lit = true
        case .laterCallPause?: variant = .paused
        case .laterAutoStart?: variant = .due
        default: break
        }
        return ZStack {
            if lit {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.2))
                    .frame(width: 34, height: 22)
            }
            BrandMark(variant, badge: badge)
                .foregroundStyle(Color.white.opacity(0.95))
                .frame(height: 15)
        }
        .position(x: markX, y: menuBarHeight / 2)
        .frame(width: size.width, height: menuBarHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private static func scene(_ beat: Beat, at local: TimeInterval, desktop: FilmDesktop) -> some View {
        switch beat.scene {
        case .offer:
            hanging(TourCoachCard(tour: .at(.offer), pointerX: pointerX(width: CoachCaption.width), actions: .noop))
        case .mark:
            hanging(TourCoachCard(tour: .at(.mark), pointerX: pointerX(width: CoachCaption.width), actions: .noop))
        case .nudge:
            // Start is pressed in the last 0.35 s: the card swells and fades as the break begins.
            let pressed = max(0, (local - (beat.length - 0.35)) / 0.35)
            underMenuBar(TourScenes.nudge())
                .scaleEffect(1 + 0.04 * pressed, anchor: .top)
                .opacity(1 - pressed)
        case .breakScreen:
            breakScreen(at: local, length: beat.length, desktop: desktop)
        case .resume:
            underMenuBar(TourScenes.resume())
        case .popover(let part):
            popover(part)
        case .farewell:
            hanging(TourCoachCard(tour: .at(.farewell), pointerX: pointerX(width: CoachCaption.width), actions: .noop))
        case .later:
            FilmTitleCard(text: "Later, in real use")
                .frame(width: size.width, height: size.height)
        case .laterCallPause:
            underMenuBar(ToastView(toast: ToastContent(text: Copy.callPauseToast(.camera), action: .resumeFromCall,
                                                       hint: HintCopy.callPause), onAction: {}))
        case .laterAutoStart:
            underMenuBar(NudgeCardView(nudge: autoStartNudge(at: local), actions: .noop))
        }
    }

    /// The first eye rest that starts by itself, counting down through the beat, with its hint.
    private static func autoStartNudge(at local: TimeInterval) -> NudgeState {
        let remaining = max(1, Timing.autoStartCountdown - local * 1.6)
        var nudge = AppState.preview(.autoStart(remaining: remaining)).nudge!
        nudge.hint = HintCopy.autoStart
        return nudge
    }

    /// Where a card `width` wide hangs from the mark: centred under it, kept 16 pt inside the screen.
    private static func cardX(width: CGFloat) -> CGFloat { min(markX - width / 2, size.width - 16 - width) }
    private static func pointerX(width: CGFloat) -> CGFloat { markX - cardX(width: width) }

    private static func hanging(_ card: some View) -> some View {
        card
            .fixedSize()
            .offset(x: cardX(width: CoachCaption.width), y: menuBarHeight + 4)
    }

    /// Top centre, 8 pt under the menu bar (SPEC §3.0).
    private static func underMenuBar(_ content: some View) -> some View {
        content
            .fixedSize()
            .frame(width: size.width, alignment: .top)
            .offset(y: menuBarHeight + Theme.Layout.popupTopGap)
    }

    private static func popover(_ part: TourPopoverPart) -> some View {
        let width = Theme.Layout.popoverWidth
        return TourPopoverChrome { PopoverView(state: TourScenes.popoverState(part: part), actions: .noop) }
            .fixedSize()
            .offset(x: markX - width / 2, y: menuBarHeight - 2)
    }

    /// The sample break: the entrance, 15 s of eye rest shown in the beat's time (the agent finishes
    /// partway), then the exit.
    private static func breakScreen(at local: TimeInterval, length: TimeInterval, desktop: FilmDesktop) -> some View {
        let entrance = max(Theme.Motion.overlayEntranceTotal, BackdropTimeline.entranceTotal)
        let exit = OverlayFrame.exitDuration(reduceMotion: false)
        let exitAt = length - exit
        let frame: OverlayFrame = local < entrance ? .entrance(at: local, reduceMotion: false)
            : local < exitAt ? .settled : .exit(at: local - exitAt, reduceMotion: false)
        // The whole 15 s break in the beat's settled time.
        let progress = min(1, max(0, (local - 0.2) / max(1, exitAt - 0.2)))
        let elapsed = progress * Timing.tourBreakLength
        return ZStack {
            Image(decorative: desktop.blurred, scale: 1).opacity(frame.backdrop)
            TourScenes.breakScreen(elapsed: elapsed, presentation: OverlayPresentation(frame: frame, liveElapsed: elapsed,
                                                                                       backdropTime: 0))
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The film's own title card (not part of the app): white words on a dark capsule, centred.
private struct FilmTitleCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background(Capsule(style: .circular).fill(Color.black.opacity(0.62)))
    }
}
