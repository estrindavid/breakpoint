import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

// The pop-up glass over a drawn desktop (SPEC §4.5), for review.
//
//   BreakpointSnapshots design/glass-desktop design/glass-popover
//       stills: the real pop-ups on a GlassStage, so the glass blurs what is "behind" it
//   BreakpointSnapshots --glass-film LABEL
//       raw RGBA frames (1800 × 1120, 30 fps) on stdout, for ffmpeg:
//       … | ffmpeg -f rawvideo -pix_fmt rgba -s 1800x1120 -r 30 -i - …
//       The nudge card and the countdown chip glide across the desktop and back; LABEL is drawn
//       at the left ("Before", "After").
//   BreakpointSnapshots --glass-still LABEL SECONDS OUT.png
//       one frame of the same film
//
// Every frame is a pure function of time: nothing is captured from a screen. What the drawn
// desktop cannot show: the live material blurs the real windows behind the panel, and on
// macOS 26 the system Liquid Glass also bends and tints what is behind; neither renders off screen.

enum GlassSnapshots {
    @MainActor static var all: [Snapshot] {
        [
            Snapshot("design/glass-desktop", size: GlassDesktop.size, scenes: SnapshotScene.darkOnly,
                     variants: SnapshotVariant.accessibility) {
                GlassStage { GlassDesktop() } content: { GlassDesktopPopups(phase: nil) }
            },
            Snapshot("design/glass-popover", size: CGSize(width: 520, height: 500), scenes: SnapshotScene.darkOnly,
                     variants: SnapshotVariant.accessibility) {
                GlassStage { GlassDesktop(viewport: CGRect(x: 330, y: 0, width: 520, height: 500)) } content: {
                    PopoverChrome(arrow: false) { PopoverView(state: AppState.preview(.agentWorking), actions: .noop) }
                        .frame(width: 320)
                        .padding(.top, 24)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            },
        ]
    }
}

// MARK: - The pop-ups on the desktop

/// The nudge, the countdown chip and a toast where they sit on a 900 × 560 desktop. `phase`
/// (0…1, nil = rest) moves the nudge and the chip for the film.
struct GlassDesktopPopups: View {
    let phase: Double?

    var body: some View {
        let nudge = AppState.preview(.breakDue(.move)).nudge!
        // The nudge sweeps from over the dark editor to over the bright document and back.
        let swing = phase.map { -cos($0 * 2 * .pi) } ?? 0      // -1 … 1 … -1
        ZStack(alignment: .topLeading) {
            // Placed with padding, not offset: glass finds what is behind it from its layout frame.
            NudgeCardView(nudge: nudge, actions: .noop)
                .padding(.leading, 245 + swing * 180).padding(.top, 36)
            CountdownChipView(kind: .eyes, remaining: 5)
                .padding(.leading, 280 - swing * 60).padding(.top, 246)
            ToastShell(text: "Counted your 6 min away as a break", badge: .move, actionTitle: "Undo")
                .padding(.leading, 470).padding(.top, 412)
        }
        .frame(width: GlassDesktop.size.width, height: GlassDesktop.size.height, alignment: .topLeading)
    }
}

// MARK: - A drawn desktop

/// A busy, colourful desktop: wallpaper, a dark code editor, a light document with a photo and a
/// menu bar. All of it drawn in code; the glass snapshots and every film draw over it.
struct GlassDesktop: View {
    static let size = CGSize(width: 900, height: 560)
    static let menuBarHeight: CGFloat = 26
    /// The whole desktop: the wallpaper and the menu bar fill it, the windows keep their places.
    var canvas = GlassDesktop.size
    /// The part of the desktop to show (moved with padding, not offset, so glass finds it).
    var viewport = CGRect(origin: .zero, size: GlassDesktop.size)

    var body: some View {
        desktop
            .padding(.leading, -viewport.minX)
            .padding(.top, -viewport.minY)
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .clipped()
    }

    private var desktop: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            EditorWindow()
                .frame(width: 470, height: 440)
                .offset(x: 28, y: 52)
            DocumentWindow()
                .frame(width: 420, height: 410)
                .offset(x: 450, y: 118)
            MenuBarStrip(width: canvas.width)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1C2B6E), Color(hex: 0x6A3FA2), Color(hex: 0xF0883A)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                let blobs: [(CGFloat, CGFloat, CGFloat, UInt32)] = [
                    (0.82, 0.12, 260, 0xFF5E7E), (0.12, 0.85, 300, 0x2EC4B6), (0.55, 0.55, 220, 0xFFD166),
                    (0.95, 0.85, 240, 0x3A86FF),
                ]
                for (x, y, r, hex) in blobs {
                    let rect = CGRect(x: x * size.width - r / 2, y: y * size.height - r / 2, width: r, height: r)
                    context.fill(Path(ellipseIn: rect),
                                 with: .radialGradient(Gradient(colors: [Color(hex: hex, opacity: 0.85), Color(hex: hex, opacity: 0)]),
                                                       center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0, endRadius: r / 2))
                }
            }
        }
    }
}

private struct MenuBarStrip: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "applelogo").font(.system(size: 13, weight: .semibold))
            Text("Code").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "Selection", "View", "Go", "Window"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Text("Sun 22 Nov  14:05").font(.system(size: 13))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 16)
        .frame(width: width, height: GlassDesktop.menuBarHeight)
        .background(Color.black.opacity(0.18))
    }
}

private struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(hex: 0xFF5F57))
            Circle().fill(Color(hex: 0xFEBC2E))
            Circle().fill(Color(hex: 0x28C840))
        }
        .frame(width: 52, height: 12)
    }
}

private struct EditorWindow: View {
    private static let lines: [[(String, UInt32)]] = [
        [("import", 0xFF7AB2), (" SwiftUI", 0xDFDFE0)],
        [],
        [("// Glass that reads as thickness, lit from above.", 0x7F8C98)],
        [("struct", 0xFF7AB2), (" Panel", 0x5DD8FF), (": ", 0xDFDFE0), ("View", 0x5DD8FF), (" {", 0xDFDFE0)],
        [("    let", 0xFF7AB2), (" title: ", 0xDFDFE0), ("String", 0x5DD8FF)],
        [("    var", 0xFF7AB2), (" radius: ", 0xDFDFE0), ("CGFloat", 0x5DD8FF), (" = ", 0xDFDFE0), ("28", 0xD9C97C)],
        [],
        [("    var", 0xFF7AB2), (" body: ", 0xDFDFE0), ("some", 0xFF7AB2), (" View", 0x5DD8FF), (" {", 0xDFDFE0)],
        [("        Text", 0x67B7A4), ("(title)", 0xDFDFE0)],
        [("            .font", 0x67B7A4), ("(.", 0xDFDFE0), ("title2", 0x67B7A4), (")", 0xDFDFE0)],
        [("            .padding", 0x67B7A4), ("(", 0xDFDFE0), ("14", 0xD9C97C), (")", 0xDFDFE0)],
        [("            .background", 0x67B7A4), ("(", 0xDFDFE0), ("\"glass\"", 0xFC6A5D), (")", 0xDFDFE0)],
        [("    }", 0xDFDFE0)],
        [("}", 0xDFDFE0)],
        [],
        [("func", 0xFF7AB2), (" render", 0x67B7A4), ("(", 0xDFDFE0), ("_", 0xDFDFE0), (" frames: ", 0xDFDFE0), ("Int", 0x5DD8FF), (") {", 0xDFDFE0)],
        [("    for", 0xFF7AB2), (" i ", 0xDFDFE0), ("in", 0xFF7AB2), (" 0..<frames {", 0xDFDFE0)],
        [("        let", 0xFF7AB2), (" t = ", 0xDFDFE0), ("Double", 0x5DD8FF), ("(i) / ", 0xDFDFE0), ("30", 0xD9C97C)],
        [("        draw", 0x67B7A4), ("(at: t, label: ", 0xDFDFE0), ("\"after\"", 0xFC6A5D), (")", 0xDFDFE0)],
        [("    }", 0xDFDFE0)],
        [("}", 0xDFDFE0)],
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TrafficLights()
                Spacer()
                Text("Panel.swift").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Color.clear.frame(width: 52, height: 12)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color(hex: 0x2A2B33))
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(Array(Self.lines.indices), id: \.self) { i in
                        Text("\(i + 1)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.white.opacity(0.3))
                    }
                }
                .frame(width: 34, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, tokens in
                        tokens.reduce(Text("")) { $0 + Text($1.0).foregroundColor(Color(hex: $1.1)) }
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .padding(.leading, 14)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(hex: 0x1E1F26))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
}

private struct DocumentWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { TrafficLights(); Spacer() }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color(hex: 0xE9E9EC))
            VStack(alignment: .leading, spacing: 10) {
                Text("Field notes").font(.system(size: 22, weight: .bold)).foregroundStyle(Color(hex: 0x1D1D1F))
                Photo().frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("The ridge path climbs through pines to a lookout over the lake. Morning light comes in low from the east and the water turns copper before nine.")
                    .font(.system(size: 13)).foregroundStyle(Color(hex: 0x3A3A3C)).lineSpacing(3)
                Text("Bring a jacket: the wind picks up after the second bend.")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0x0A6CFF))
            }
            .padding(18)
            Spacer(minLength: 0)
        }
        .background(Color(hex: 0xFBFBFA))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
    }
}

private struct Photo: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [Color(hex: 0xFF9A5A), Color(hex: 0xFFD8A8), Color(hex: 0x7FB8E8)]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.fill(Path(ellipseIn: CGRect(x: size.width * 0.62, y: size.height * 0.18, width: 46, height: 46)),
                         with: .color(Color(hex: 0xFFF3C4)))
            var far = Path()
            far.move(to: CGPoint(x: 0, y: size.height * 0.75))
            far.addLine(to: CGPoint(x: size.width * 0.25, y: size.height * 0.38))
            far.addLine(to: CGPoint(x: size.width * 0.5, y: size.height * 0.68))
            far.addLine(to: CGPoint(x: size.width * 0.78, y: size.height * 0.32))
            far.addLine(to: CGPoint(x: size.width, y: size.height * 0.6))
            far.addLine(to: CGPoint(x: size.width, y: size.height))
            far.addLine(to: CGPoint(x: 0, y: size.height))
            context.fill(far, with: .color(Color(hex: 0x3D5A80)))
            var near = Path()
            near.move(to: CGPoint(x: 0, y: size.height * 0.9))
            near.addLine(to: CGPoint(x: size.width * 0.4, y: size.height * 0.62))
            near.addLine(to: CGPoint(x: size.width * 0.7, y: size.height * 0.85))
            near.addLine(to: CGPoint(x: size.width, y: size.height * 0.7))
            near.addLine(to: CGPoint(x: size.width, y: size.height))
            near.addLine(to: CGPoint(x: 0, y: size.height))
            context.fill(near, with: .color(Color(hex: 0x1F3B2C)))
        }
    }
}

// MARK: - Film

enum GlassFilm {
    static let size = GlassDesktop.size
    static let scale: CGFloat = 2
    static let fps: Double = 30
    static let length: TimeInterval = 6
    /// The label sits over the editor's gutter, inside the top 300 pt (for a cropped close-up).
    static let labelTop: CGFloat = 252

    @MainActor
    static func run(_ args: [String]) -> Int32? {
        if let i = args.firstIndex(of: "--glass-film") {
            guard i + 1 < args.count else { return Film.usage("--glass-film LABEL") }
            let label = args[i + 1]
            return Film.stream(Int((length * fps).rounded()), of: label) { frame(label: label, at: Double($0) / fps) }
        }
        if let i = args.firstIndex(of: "--glass-still") {
            guard i + 3 < args.count, let t = Double(args[i + 2]) else { return Film.usage("--glass-still LABEL SECONDS OUT.png") }
            return Film.writeStill(frame(label: args[i + 1], at: t), to: args[i + 3])
        }
        return nil
    }

    @MainActor
    static func frame(label: String, at t: TimeInterval) -> CGImage? {
        let phase = (t / length).truncatingRemainder(dividingBy: 1)
        let view = GlassStage { GlassDesktop() } content: { GlassDesktopPopups(phase: phase) }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            FilmCaption(label)
                .padding(.leading, 14)
                .padding(.top, labelTop)
        }
        .clipped()
        .environment(\.colorScheme, .dark)
        .designOverrides(SnapshotVariant.standard.overrides)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }
}
