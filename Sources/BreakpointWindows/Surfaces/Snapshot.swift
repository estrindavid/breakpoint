import BreakpointCore
import CBreakpointWin32
import Foundation

/// Renders a surface's drawing offscreen into a PNG (the Windows counterpart of the macOS
/// `BreakpointSnapshots` tool): the same `draw` function a window runs, over a bitmap instead of
/// a swap chain, at any scale. `Breakpoint.exe --debug-snapshots DIR` writes every surface in
/// every state the shared previews describe.
@MainActor
public enum Snapshot {
    private final class Job {
        let size: SizeF
        let scale: Float
        let controls: Controls
        let draw: (Canvas, Controls) -> Void
        init(size: SizeF, scale: Float, controls: Controls, draw: @escaping (Canvas, Controls) -> Void) {
            self.size = size; self.scale = scale; self.controls = controls; self.draw = draw
        }
    }

    /// Writes `draw` at `size` DIPs × `scale` to `url`. `background` defaults to the pop-up
    /// chrome (opaque, since nothing shows through a bitmap).
    public static func write(_ url: URL, size: SizeF, scale: Float = 2, look: Look = .dark,
                             background: (@MainActor (Canvas) -> Void)? = { @MainActor in Chrome.popupBackground($0) },
                             focused: String? = nil,
                             draw: @escaping (Canvas, Controls) -> Void) throws {
        let controls = Controls(look: look)
        controls.focused = focused
        let job = Job(size: size, scale: scale, controls: controls, draw: { canvas, controls in
            background?(canvas)
            draw(canvas, controls)
        })
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = Unmanaged.passUnretained(job).toOpaque()
        let drawer: BPIconDrawer = { surface, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let job = Unmanaged<Job>.fromOpaque(context).takeUnretainedValue()
                var canvas = Canvas(surface: surface, size: job.size, scale: job.scale)
                canvas.isOffscreen = true
                job.controls.begin()
                job.draw(canvas, job.controls)
            }
        }
        let rendered = withExtendedLifetime(job) {
            bp_render_pixels(Int32(width), Int32(height), scale, drawer, context, &pixels)
        }
        guard rendered == 0 else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let written = Array(PathDisplay.native(url).utf16) + [0]
        let result = written.withUnsafeBufferPointer { path in
            bp_write_png(path.baseAddress, Int32(width), Int32(height), pixels)
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
