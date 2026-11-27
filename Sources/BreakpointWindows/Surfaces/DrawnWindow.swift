import BreakpointCore
import BreakpointRuntime
import CBreakpointWin32
import Foundation
import WinSDK

/// A window whose whole content is one drawing function over `Controls`: every surface is a pure
/// `draw(canvas, controls, model)` (so the same function renders snapshots offscreen) plus this.
@MainActor
public final class DrawnWindow {
    public let window: Window
    public let controls: Controls
    /// Draws the content (after `background`). Registers its controls on `controls`.
    public var content: (Canvas, Controls) -> Void = { _, _ in }
    /// The chrome under the content; `nil` draws nothing (the overlay paints its own scrim).
    public var background: (@MainActor (Canvas) -> Void)? = { @MainActor in Chrome.popupBackground($0) }
    /// Content opacity 0…1 (the overlay's fades; pop-ups use DWM's own transitions).
    public var opacity: Float = 1 {
        didSet { if opacity != oldValue { window.setNeedsDisplay() } }
    }

    public init(style: Window.Style, look: Look = .dark) {
        window = Window(style: style)
        controls = Controls(look: look)
        window.draw = { [weak self] canvas in
            guard let self else { return }
            self.controls.begin()
            canvas.withOpacity(self.opacity) {
                self.background?(canvas)
                self.content(canvas, self.controls)
            }
        }
        controls.attach(to: window)
    }

    /// Creates the window (hidden) at `size`, offscreen until placed.
    public func create(size: SizeF, owner: HWND? = nil) {
        window.create(frame: RectF(x: -32000, y: -32000, width: size.width, height: size.height), owner: owner)
    }

    public var isCreated: Bool { window.hwnd != nil }
    public var isVisible: Bool { window.isVisible }
    public func setNeedsDisplay() { window.setNeedsDisplay() }
    public func hide() { window.hide() }

    public func destroy() {
        FrameClock.shared.remove(self)
        window.destroy()
    }

    /// Redraws every frame while `animating` is true (a pulsing dot, a breathing ring); stops
    /// the clock as soon as nothing animates, so an idle app draws nothing.
    public var animating = false {
        didSet {
            guard animating != oldValue else { return }
            if animating { FrameClock.shared.add(self) } else { FrameClock.shared.remove(self) }
        }
    }
}

/// One timer for every animating window, at the display's rate (60 Hz), running only while
/// something animates. Each tick redraws those windows (coalesced with any other change).
@MainActor
public final class FrameClock {
    public static let shared = FrameClock()
    private var windows: [ObjectIdentifier: () -> Void] = [:]
    private var timer: Timer?
    /// Other per-frame work (fades), run before the redraws.
    private var ticks: [ObjectIdentifier: () -> Bool] = [:]

    func add(_ window: DrawnWindow) {
        windows[ObjectIdentifier(window)] = { [weak window] in window?.setNeedsDisplay() }
        start()
    }

    func remove(_ window: DrawnWindow) {
        windows[ObjectIdentifier(window)] = nil
        stopIfIdle()
    }

    /// Runs `tick` every frame until it returns false.
    public func run(_ owner: AnyObject, _ tick: @escaping () -> Bool) {
        ticks[ObjectIdentifier(owner)] = tick
        start()
    }

    public func cancel(_ owner: AnyObject) {
        ticks[ObjectIdentifier(owner)] = nil
        stopIfIdle()
    }

    private func start() {
        guard timer == nil else { return }
        let timer = Timer.after(1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { FrameClock.shared.tick() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopIfIdle() {
        guard windows.isEmpty, ticks.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        for (key, tick) in ticks where !tick() { ticks[key] = nil }
        for redraw in windows.values { redraw() }
        stopIfIdle()
    }
}

/// A value easing from one number to another over a duration (SPEC §4.6 curves), for fades.
public struct Tween {
    public var from: Float
    public var to: Float
    public var start: Date
    public var duration: Double

    public init(from: Float, to: Float, duration: Double, start: Date = Date()) {
        self.from = from; self.to = to; self.duration = duration; self.start = start
    }

    public func value(at date: Date = Date()) -> Float {
        guard duration > 0 else { return to }
        let t = Float(min(1, max(0, date.timeIntervalSince(start) / duration)))
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        return from + (to - from) * eased
    }

    public func isDone(at date: Date = Date()) -> Bool { date.timeIntervalSince(start) >= duration }
}
