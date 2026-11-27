import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

// What the films share (`--motion-film`, `--rim-film`, `--controls-film`, `--glass-film`,
// `--overlay-film`): the loop that streams frames to stdout as raw RGBA for ffmpeg, stills written
// as PNG, the drawn pointer and the caption. Every film draws its frames over `GlassDesktop` as a
// pure function of time; nothing is captured from a screen.

enum Film {
    /// Prints `message` on stderr and returns the usage exit status.
    static func usage(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }

    /// Writes `count` frames to stdout as raw RGBA (`opaque`: flattened onto black), rendering
    /// frame `index` with `frame(index)`.
    @MainActor
    static func stream(_ count: Int, of name: String, opaque: Bool = false, frame: (Int) -> CGImage?) -> Int32 {
        let out = FileHandle.standardOutput
        for index in 0..<count {
            guard let image = frame(index), let bytes = rgba(image, opaque: opaque) else {
                FileHandle.standardError.write(Data("frame \(index) failed\n".utf8))
                return 1
            }
            out.write(bytes)
        }
        FileHandle.standardError.write(Data("\(count) frames of \(name)\n".utf8))
        return 0
    }

    /// Writes one frame as a PNG at `path` and prints the path.
    @MainActor
    static func writeStill(_ image: CGImage?, to path: String) -> Int32 {
        guard let image else { return 1 }
        do {
            let url = URL(fileURLWithPath: path)
            try SnapshotRenderingEngine.writePNG(image, to: url)
            print(url.path)
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    /// Tightly packed RGBA bytes of `image`, top row first (ffmpeg's `rgba`). `opaque` draws it
    /// over black and sets every alpha byte to 255.
    static func rgba(_ image: CGImage, opaque: Bool = false) -> Data? {
        let width = image.width, height = image.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        var data = Data(count: width * height * 4)
        let info = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: info.rawValue) else { return false }
            if opaque {
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(rect)
            }
            context.draw(image, in: rect)
            return true
        }
        guard drawn else { return nil }
        if opaque {
            // noneSkipLast leaves the fourth byte undefined: make it opaque.
            data.withUnsafeMutableBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                var i = 3
                while i < bytes.count { bytes[i] = 255; i += 4 }
            }
        }
        return data
    }

    /// 0 → 1 as `t` goes from `start` to `start + duration` (a step at `start` when `duration` is 0).
    static func progress(_ t: TimeInterval, from start: TimeInterval, over duration: TimeInterval) -> Double {
        guard duration > 0 else { return t >= start ? 1 : 0 }
        return min(1, max(0, (t - start) / duration))
    }
}

/// The arrow pointer, drawn in code (not the system's artwork): white with a dark rim, its hot
/// spot at the view's top-left corner.
struct FilmPointer: View {
    var body: some View {
        ArrowShape()
            .fill(Color.white)
            .overlay(ArrowShape().stroke(Color.black, lineWidth: 1.2))
            .frame(width: 16, height: 24)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    private struct ArrowShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: 19))
            p.addLine(to: CGPoint(x: 4.6, y: 14.8))
            p.addLine(to: CGPoint(x: 7.8, y: 22))
            p.addLine(to: CGPoint(x: 10.8, y: 20.6))
            p.addLine(to: CGPoint(x: 7.7, y: 13.6))
            p.addLine(to: CGPoint(x: 13.6, y: 13.6))
            p.closeSubpath()
            return p
        }
    }
}

/// A film's label ("Before", "After", …) on a dark capsule.
struct FilmCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}
