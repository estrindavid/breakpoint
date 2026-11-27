import Foundation
import WinSDK

/// One display: its whole area and its work area (without the taskbar), in physical pixels, and
/// its scale (DPI / 96).
public struct Monitor: Equatable {
    public let handle: UInt
    public let frame: RECT
    public let workArea: RECT
    public let scale: Float
    public let isPrimary: Bool

    public static func == (a: Monitor, b: Monitor) -> Bool { a.handle == b.handle }

    /// The work area in DIPs of this monitor (origin in physical pixels / scale, so it can be
    /// turned back exactly).
    public var workAreaDIPs: RectF {
        RectF(x: Float(workArea.left) / scale, y: Float(workArea.top) / scale,
              width: Float(workArea.right - workArea.left) / scale, height: Float(workArea.bottom - workArea.top) / scale)
    }

    public var frameDIPs: RectF {
        RectF(x: Float(frame.left) / scale, y: Float(frame.top) / scale,
              width: Float(frame.right - frame.left) / scale, height: Float(frame.bottom - frame.top) / scale)
    }
}

public enum Monitors {
    /// Every display, primary first.
    public static func all() -> [Monitor] {
        var found: [Monitor] = []
        withUnsafeMutablePointer(to: &found) { pointer in
            _ = EnumDisplayMonitors(nil, nil, { handle, _, _, data in
                guard let handle, let data = UnsafeMutableRawPointer(bitPattern: Int(data)) else { return true }
                let list = data.assumingMemoryBound(to: [Monitor].self)
                if let monitor = Monitors.describe(handle) { list.pointee.append(monitor) }
                return true
            }, LPARAM(Int(bitPattern: pointer)))
        }
        return found.sorted { $0.isPrimary && !$1.isPrimary }
    }

    /// The display under the pointer (where pop-ups appear, SPEC §3.0).
    public static func underPointer() -> Monitor? {
        var cursor = POINT()
        GetCursorPos(&cursor)
        return MonitorFromPoint(cursor, DWORD(MONITOR_DEFAULTTOPRIMARY)).flatMap(describe)
    }

    public static func primary() -> Monitor? {
        MonitorFromPoint(POINT(x: 0, y: 0), DWORD(MONITOR_DEFAULTTOPRIMARY)).flatMap(describe)
    }

    static func describe(_ handle: HMONITOR) -> Monitor? {
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        guard GetMonitorInfoW(handle, &info) else { return nil }
        var dpiX: UINT = 96, dpiY: UINT = 96
        _ = GetDpiForMonitor(handle, MDT_EFFECTIVE_DPI, &dpiX, &dpiY)
        return Monitor(handle: UInt(bitPattern: handle), frame: info.rcMonitor, workArea: info.rcWork,
                       scale: Float(dpiX) / 96, isPrimary: info.dwFlags & DWORD(MONITORINFOF_PRIMARY) != 0)
    }
}

extension Window {
    /// Places the window at `frame`, given in DIPs of `monitor` (its origin is the monitor's own
    /// pixel origin divided by its scale, as `Monitor.workAreaDIPs` gives it).
    public func place(_ frame: RectF, on monitor: Monitor) {
        guard let hwnd else { return }
        let s = monitor.scale
        let x = Int32((frame.x * s).rounded()), y = Int32((frame.y * s).rounded())
        let w = Int32((frame.width * s).rounded()), h = Int32((frame.height * s).rounded())
        SetWindowPos(hwnd, nil, x, y, w, h, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    }
}
