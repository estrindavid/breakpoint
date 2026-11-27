import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

// Registry types and the renderer. Each part registers its snapshots in its own file
// (DesignSnapshots.swift, GlassSnapshots.swift, BreakSnapshots.swift, MenuBarSnapshots.swift,
// SettingsSnapshots.swift, OnboardingSnapshots.swift, TourSnapshots.swift); main.swift
// concatenates them.

/// Where and how a snapshot is drawn.
struct SnapshotScene: Hashable {
    enum Appearance: String { case light, dark }
    enum Backdrop: String {
        /// Transparent: the view draws its own background (windows, full-screen overlays).
        case none
        /// The window background colour of the appearance (settings panes, onboarding).
        case window
        /// A light grey desktop-like gradient: how dark glass reads on a bright wallpaper.
        case neutral
        /// A dark desktop-like gradient.
        case dark
        /// A busy, high-contrast wallpaper stand-in: worst case for contrast (§4.8).
        case wallpaper
    }

    var appearance: Appearance
    var backdrop: Backdrop

    /// File suffix: "light", "dark", "on-neutral", "on-dark", "on-wallpaper".
    var suffix: String {
        switch backdrop {
        case .none, .window: return appearance.rawValue
        default: return "on-\(backdrop.rawValue)"
        }
    }

    /// System-following surfaces: light and dark windows.
    static let lightAndDark: [SnapshotScene] = [.init(appearance: .light, backdrop: .window),
                                                .init(appearance: .dark, backdrop: .window)]
    /// Dark pop-ups on a neutral and a dark backdrop.
    static let popupBackdrops: [SnapshotScene] = [.init(appearance: .dark, backdrop: .neutral),
                                                  .init(appearance: .dark, backdrop: .dark)]
    /// Dark pop-ups on neutral, dark and busy backdrops.
    static let allBackdrops: [SnapshotScene] = popupBackdrops + [.init(appearance: .dark, backdrop: .wallpaper)]
    /// Full-screen dark surfaces that draw their own background.
    static let darkOnly: [SnapshotScene] = [.init(appearance: .dark, backdrop: .none)]
}

/// Accessibility variants (SPEC §9: each surface also in Reduce Transparency and Increase Contrast).
enum SnapshotVariant: String, CaseIterable {
    case standard
    case reduceTransparency = "reduce-transparency"
    case increaseContrast = "increase-contrast"
    case reduceMotion = "reduce-motion"

    var overrides: DesignOverrides {
        switch self {
        case .standard: return DesignOverrides(reduceMotion: false, reduceTransparency: false, increaseContrast: false, freezeContinuousAnimations: true)
        case .reduceTransparency: return DesignOverrides(reduceMotion: false, reduceTransparency: true, increaseContrast: false, freezeContinuousAnimations: true)
        case .increaseContrast: return DesignOverrides(reduceMotion: false, reduceTransparency: false, increaseContrast: true, freezeContinuousAnimations: true)
        case .reduceMotion: return DesignOverrides(reduceMotion: true, reduceTransparency: false, increaseContrast: false, freezeContinuousAnimations: true)
        }
    }

    static let accessibility: [SnapshotVariant] = [.standard, .reduceTransparency, .increaseContrast]
}

/// How the view is turned into pixels.
enum SnapshotRenderer {
    /// SwiftUI `ImageRenderer`: pure SwiftUI content (pop-ups, overlay, design components).
    /// Cannot draw AppKit-backed controls (toggles, pickers, text fields, scroll views).
    case imageRenderer
    /// An `NSHostingView` in an off-screen window, captured with `cacheDisplay`: draws native
    /// controls (settings panes, onboarding). Materials still render flat.
    case window
}

/// One registered snapshot. `name` may contain "/" to group files ("design/pill-buttons").
struct Snapshot {
    var name: String
    /// Fixed canvas size in points; `nil` uses the view's fitting size.
    var size: CGSize?
    var scenes: [SnapshotScene]
    var variants: [SnapshotVariant]
    var renderer: SnapshotRenderer
    /// Padding around the view on its backdrop (ignored for `.none`).
    var padding: CGFloat
    /// `.window` renderer only: points to scroll the widest scroll view down before capture (as if
    /// scrolled with the wheel; capped at the end of its content). `nil` leaves it at the top.
    var scrollOffset: CGFloat?
    var content: @MainActor () -> AnyView

    init(_ name: String,
         size: CGSize? = nil,
         scenes: [SnapshotScene] = SnapshotScene.popupBackdrops,
         variants: [SnapshotVariant] = [.standard],
         renderer: SnapshotRenderer = .imageRenderer,
         padding: CGFloat = 40,
         scrollOffset: CGFloat? = nil,
         @ViewBuilder content: @escaping @MainActor () -> some View) {
        self.name = name
        self.size = size
        self.scenes = scenes
        self.variants = variants
        self.renderer = renderer
        self.padding = padding
        self.scrollOffset = scrollOffset
        self.content = { AnyView(content()) }
    }
}

/// Backdrop views.
struct SnapshotBackdrop: View {
    let backdrop: SnapshotScene.Backdrop
    let appearance: SnapshotScene.Appearance

    var body: some View {
        switch backdrop {
        case .none:
            Color.clear
        case .window:
            Color(nsColor: .windowBackgroundColor)
        case .neutral:
            LinearGradient(colors: [Color(hex: 0xEEF0F4), Color(hex: 0xD9DDE5)], startPoint: .top, endPoint: .bottom)
        case .dark:
            LinearGradient(colors: [Color(hex: 0x2A3040), Color(hex: 0x141821)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .wallpaper:
            ZStack {
                LinearGradient(colors: [Color(hex: 0xF6D365), Color(hex: 0xFDA085), Color(hex: 0x5B86E5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Canvas { context, size in
                    // Busy stripes and dots: a worst case for text contrast.
                    var stripe = Path()
                    var x: CGFloat = -size.height
                    while x < size.width {
                        stripe.move(to: CGPoint(x: x, y: size.height))
                        stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 18
                    }
                    context.stroke(stripe, with: .color(.white.opacity(0.55)), lineWidth: 5)
                    for i in 0..<40 {
                        let px = CGFloat((i * 73) % 997) / 997 * size.width
                        let py = CGFloat((i * 131) % 991) / 991 * size.height
                        context.fill(Path(ellipseIn: CGRect(x: px, y: py, width: 26, height: 26)),
                                     with: .color(i.isMultiple(of: 2) ? .black.opacity(0.5) : .white.opacity(0.8)))
                    }
                }
            }
        }
    }
}

@MainActor
enum SnapshotRenderingEngine {
    static let scale: CGFloat = 2

    /// Renders `snapshot` in every scene and variant into `directory`, returning the files written.
    static func render(_ snapshot: Snapshot, into directory: URL) throws -> [URL] {
        var written: [URL] = []
        for variant in snapshot.variants {
            for scene in snapshot.scenes {
                let suffix = variant == .standard ? scene.suffix : "\(scene.suffix)-\(variant.rawValue)"
                let url = directory.appendingPathComponent("\(snapshot.name)-\(suffix)@2x.png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let view = composed(snapshot, scene: scene, variant: variant)
                guard let image = image(of: view, snapshot: snapshot, scene: scene) else {
                    throw SnapshotError.renderFailed(snapshot.name)
                }
                try writePNG(image, to: url)
                written.append(url)
            }
        }
        return written
    }

    private static func composed(_ snapshot: Snapshot, scene: SnapshotScene, variant: SnapshotVariant) -> AnyView {
        let scheme: ColorScheme = scene.appearance == .dark ? .dark : .light
        let content = snapshot.content()
            .padding(scene.backdrop == .none ? 0 : snapshot.padding)
            .frame(width: snapshot.size?.width, height: snapshot.size?.height)
            .background(SnapshotBackdrop(backdrop: scene.backdrop, appearance: scene.appearance))
            .environment(\.colorScheme, scheme)
            .glassRendering(.opaque)
            .designOverrides(variant.overrides)
        return AnyView(content)
    }

    private static func image(of view: AnyView, snapshot: Snapshot, scene: SnapshotScene) -> CGImage? {
        let appearance = NSAppearance(named: scene.appearance == .dark ? .darkAqua : .aqua)!
        var result: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            switch snapshot.renderer {
            case .imageRenderer:
                let renderer = ImageRenderer(content: view)
                renderer.scale = scale
                result = renderer.cgImage
            case .window:
                result = windowImage(of: view, appearance: appearance, size: snapshot.size, scrollOffset: snapshot.scrollOffset)
            }
        }
        return result
    }

    private static func windowImage(of view: AnyView, appearance: NSAppearance, size: CGSize?,
                                    scrollOffset: CGFloat?) -> CGImage? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        let fitting = size ?? hosting.fittingSize
        let frame = CGRect(origin: .zero, size: fitting)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.frame = frame
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (fonts, layout passes) before capturing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        if let scrollOffset {
            scroll(in: hosting, by: scrollOffset)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        return rep.cgImage
    }

    /// Scrolls the widest scroll view that is not a list (a settings pane, not its sidebar) down by
    /// `offset` points from its top, capped at the end of its content.
    private static func scroll(in root: NSView, by offset: CGFloat) {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        func holdsTable(_ view: NSView) -> Bool { view is NSTableView || view.subviews.contains(where: holdsTable) }
        guard let scrollView = scrollViews(in: root).filter({ !holdsTable($0) }).max(by: { $0.frame.width < $1.frame.width }),
              let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let top = -scrollView.contentInsets.top
        let end = max(top, document.frame.height - clip.bounds.height)
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: min(top + offset, end)))
        scrollView.reflectScrolledClipView(clip)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.encodeFailed(url.path) }
        try data.write(to: url, options: .atomic)
    }
}

enum SnapshotError: Error, CustomStringConvertible {
    case renderFailed(String)
    case encodeFailed(String)

    var description: String {
        switch self {
        case .renderFailed(let name): return "could not render \(name)"
        case .encodeFailed(let path): return "could not encode \(path)"
        }
    }
}
