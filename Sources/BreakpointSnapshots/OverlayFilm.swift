import AppKit
import CoreImage
import SwiftUI
import BreakpointCore
import BreakpointKit

// The break overlay as a film: every frame is drawn from a time value by the same pure functions
// the live overlay uses (`OverlayFrame.entrance` / `.exit`), over the drawn desktop. Never a
// screen recording.
//
//   BreakpointSnapshots --overlay-film NAME                  raw RGBA frames on stdout (30 fps)
//   BreakpointSnapshots --overlay-film NAME --at T --png F   one frame as a PNG
//   BreakpointSnapshots --overlay-film list                  the films, their sizes and lengths
//
// Pipe into ffmpeg, e.g.
//   BreakpointSnapshots --overlay-film break-eyes | ffmpeg -f rawvideo -pix_fmt rgba -s 1512x982 \
//     -r 30 -i - -c:v libx264 -pix_fmt yuv420p out.mp4
//
// The desktop under the overlay is a sharp picture plus a blurred copy faded in by
// `OverlayFrame.backdrop`, which is what the live behind-window blur does (the system blur's
// radius is fixed; its opacity animates). The blur here is a Gaussian of about the same strength.

@MainActor
enum OverlayFilm {
    static let fps = 30.0
    static let size = CGSize(width: 1512, height: 982)

    struct Reel {
        var name: String
        var kind: BreakKind
        var reduceMotion = false
        /// Settled overlay only, with the backdrop's clock running this many times faster.
        var timeLapse: Double?
        /// With `timeLapse`: the break's elapsed seconds at the film's first frame.
        var settledFrom: TimeInterval = 6
        var length: TimeInterval
        var summary: String
    }

    /// Film timeline: the desktop alone, then the entrance, the break, the exit, the desktop again.
    static let entranceAt: TimeInterval = 0.6
    static let exitAt: TimeInterval = 5.0

    static func films() -> [Reel] {
        let exitLength = OverlayFrame.exitDuration(reduceMotion: false)
        let full = exitAt + exitLength + 0.7
        return [
            Reel(name: "break-eyes", kind: .eyes, length: full,
                 summary: "desktop, entrance, 4.4 s of an eye rest, exit, desktop"),
            Reel(name: "break-move", kind: .move, length: full,
                 summary: "desktop, entrance, 4.4 s of a stretch, exit, desktop"),
            Reel(name: "break-eyes-reduce-motion", kind: .eyes, reduceMotion: true,
                 length: exitAt + OverlayFrame.exitDuration(reduceMotion: true) + 0.7,
                 summary: "the same with Reduce Motion"),
            Reel(name: "drift-eyes", kind: .eyes, timeLapse: 12, length: 5,
                 summary: "the settled backdrop's 60 s drift at 12x"),
            Reel(name: "pace-move", kind: .move, timeLapse: 1, settledFrom: 21, length: 15,
                 summary: "a stretch at real speed: the pace ring through a step change"),
        ]
    }

    static func run(_ args: [String]) -> Int32 {
        guard let name = args.first else { return Film.usage(usage) }
        if name == "list" {
            for film in films() {
                print("\(film.name)  \(Int(size.width))x\(Int(size.height))  \(String(format: "%.2f", film.length)) s  \(film.summary)")
            }
            return 0
        }
        guard let film = films().first(where: { $0.name == name }) else { return Film.usage(usage) }
        let scene = FilmDesktop(size: size)
        if let i = args.firstIndex(of: "--at"), i + 1 < args.count, let t = Double(args[i + 1]) {
            guard let j = args.firstIndex(of: "--png"), j + 1 < args.count else { return Film.usage(usage) }
            return Film.writeStill(render(film, at: t, desktop: scene), to: args[j + 1])
        }
        return Film.stream(Int((film.length * fps).rounded()), of: film.name, opaque: true) {
            render(film, at: Double($0) / fps, desktop: scene)
        }
    }

    private static let usage = "usage: --overlay-film NAME|list [--at SECONDS --png FILE]"

    // MARK: Frames

    static func render(_ film: Reel, at t: TimeInterval, desktop: FilmDesktop) -> CGImage? {
        let renderer = ImageRenderer(content: view(film, at: t, desktop: desktop))
        renderer.scale = 1
        return renderer.cgImage
    }

    static func view(_ film: Reel, at t: TimeInterval, desktop: FilmDesktop) -> some View {
        var frame: OverlayFrame?
        var elapsed: TimeInterval
        var backdropTime: TimeInterval
        if let lapse = film.timeLapse {
            frame = .settled
            elapsed = film.settledFrom + t
            backdropTime = t * lapse
        } else {
            let sinceIn = t - entranceAt
            let sinceExit = t - exitAt
            if sinceIn < 0 {
                frame = nil
            } else if sinceExit < 0 {
                frame = OverlayFrame.entrance(at: sinceIn, reduceMotion: film.reduceMotion)
            } else if sinceExit < OverlayFrame.exitDuration(reduceMotion: film.reduceMotion) {
                frame = OverlayFrame.exit(at: sinceExit, reduceMotion: film.reduceMotion)
            }
            elapsed = max(0, min(t, exitAt) - entranceAt)
            backdropTime = elapsed
        }
        let active = BreakSnapshots.activeBreak(film.kind, elapsed: elapsed)
        let overrides = DesignOverrides(reduceMotion: film.reduceMotion, reduceTransparency: false, increaseContrast: false,
                                        freezeContinuousAnimations: true)
        return ZStack {
            Image(decorative: desktop.sharp, scale: 1)
            if let frame {
                Image(decorative: desktop.blurred, scale: 1).opacity(frame.backdrop)
                BreakOverlayView(activeBreak: active, actions: .noop, displaySize: size, now: AppState.previewNow,
                                 presentation: OverlayPresentation(frame: frame, liveElapsed: elapsed,
                                                                   backdropTime: backdropTime))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
        .glassRendering(.opaque)
        .designOverrides(overrides)
    }
}

// MARK: - The desktop

/// The drawn desktop (`GlassDesktop`, scaled up to fill the display), sharp and blurred.
@MainActor
struct FilmDesktop {
    let sharp: CGImage
    let blurred: CGImage

    init(size: CGSize) {
        self.init(size: size, zoom: size.width / GlassDesktop.size.width)
    }

    /// The desktop drawn `zoom` times its own size (the tour film keeps the menu bar near a real
    /// one's height, so pop-ups at their real size sit under it as they would).
    init(size: CGSize, zoom: CGFloat) {
        let canvas = CGSize(width: size.width / zoom, height: size.height / zoom)
        let renderer = ImageRenderer(content: GlassDesktop(canvas: canvas, viewport: CGRect(origin: .zero, size: canvas)))
        renderer.scale = zoom
        let sharp = renderer.cgImage!
        self.sharp = sharp
        self.blurred = FilmDesktop.blur(sharp, radius: 34) ?? sharp
    }

    static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
            .createCGImage(blurred, from: input.extent)
    }
}
