import CBreakpointWin32
import Foundation
import WinSDK

/// One top-level Win32 window whose content is drawn with `Canvas` (Direct2D in a
/// DirectComposition visual). Subclasses or owners set `draw` and the input handlers.
///
/// Every window is per-monitor DPI aware (the process manifest says PerMonitorV2): `scale` follows
/// the monitor it is on, and all layout is in DIPs.
@MainActor
open class Window {
    public enum Style {
        /// A pop-up that never takes focus (nudge, cards, chip, coach): no taskbar button, topmost.
        case popup
        /// A pop-up that takes keyboard focus while shown (the popover).
        case flyout
        /// The full-screen break overlay: topmost, no taskbar button, focused.
        case overlay
        /// An ordinary window with a title bar (Settings, Onboarding).
        case document(title: String, resizable: Bool)
    }

    public private(set) var hwnd: HWND?
    public let style: Style
    public private(set) var scale: Float = 1
    /// Client size in DIPs.
    public private(set) var size = SizeF(width: 0, height: 0)
    var surface: OpaquePointer?

    public var draw: ((Canvas) -> Void)?
    public var onMouseDown: ((PointF) -> Void)?
    public var onMouseUp: ((PointF) -> Void)?
    public var onMouseMove: ((PointF) -> Void)?
    public var onMouseLeave: (() -> Void)?
    public var onScroll: ((Float) -> Void)?
    public var onKeyDown: ((UInt32) -> Bool)?
    public var onChar: ((Character) -> Void)?
    public var onClose: (() -> Bool)?
    public var onActivate: ((Bool) -> Void)?
    public var onResize: (() -> Void)?
    public var onDPIChange: (() -> Void)?
    /// A Win32 message not handled above (e.g. tray callbacks). Return a result to consume it.
    public var onMessage: ((UINT, WPARAM, LPARAM) -> LRESULT?)?

    private var tracking = false
    private var needsDisplayScheduled = false

    public init(style: Style) {
        self.style = style
    }

    // MARK: Lifetime

    /// Creates the window (hidden) at `frame` (DIPs on the primary monitor's scale until shown).
    public func create(frame: RectF, owner: HWND? = nil) {
        guard hwnd == nil else { return }
        WindowClass.register()
        var exStyle: DWORD = DWORD(WS_EX_NOREDIRECTIONBITMAP)
        var windowStyle: DWORD
        var title = "Breakpoint"
        switch style {
        case .popup:
            exStyle |= DWORD(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE)
            windowStyle = DWORD(WS_POPUP)
        case .flyout:
            exStyle |= DWORD(WS_EX_TOOLWINDOW | WS_EX_TOPMOST)
            windowStyle = DWORD(WS_POPUP)
        case .overlay:
            exStyle |= DWORD(WS_EX_TOOLWINDOW | WS_EX_TOPMOST)
            windowStyle = DWORD(WS_POPUP)
        case .document(let name, let resizable):
            title = name
            windowStyle = DWORD(WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX) | DWORD(WS_CLIPCHILDREN)
            if resizable { windowStyle |= DWORD(WS_THICKFRAME | WS_MAXIMIZEBOX) }
        }
        let systemScale = Float(GetDpiForSystem()) / 96
        let pixels = frame.scaled(systemScale).integral
        let created = title.withCString(encodedAs: UTF16.self) { name in
            WindowClass.name.withCString(encodedAs: UTF16.self) { className in
                CreateWindowExW(exStyle, className, name, windowStyle, Int32(pixels.x), Int32(pixels.y),
                                Int32(pixels.width), Int32(pixels.height), owner, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let created else { return }
        hwnd = created
        WindowClass.windows[UInt(bitPattern: created)] = self
        scale = Float(GetDpiForWindow(created)) / 96
        Appearance.prepare(created, style: style)
        updateSize()
        surface = bp_surface_create(UnsafeMutableRawPointer(created), Int32(pixelWidth), Int32(pixelHeight), scale)
    }

    public func destroy() {
        guard let hwnd else { return }
        if let surface { bp_surface_destroy(surface) }
        surface = nil
        WindowClass.windows[UInt(bitPattern: hwnd)] = nil
        self.hwnd = nil
        DestroyWindow(hwnd)
    }

    public var isVisible: Bool { hwnd.map { IsWindowVisible($0) } ?? false }

    public func show(activate: Bool? = nil) {
        guard let hwnd else { return }
        let takesFocus = activate ?? {
            switch style {
            case .popup: return false
            default: return true
            }
        }()
        ShowWindow(hwnd, takesFocus ? SW_SHOW : SW_SHOWNOACTIVATE)
        if case .popup = style {
            SetWindowPos(hwnd, HWNDInsert.topmost, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
        }
        if takesFocus { SetForegroundWindow(hwnd) }
        redraw()
    }

    public func hide() {
        guard let hwnd else { return }
        ShowWindow(hwnd, SW_HIDE)
    }

    /// Moves and resizes to `frame` in DIPs of the monitor it lands on.
    public func setFrame(_ frame: RectF, monitorScale: Float? = nil) {
        guard let hwnd else { return }
        let s = monitorScale ?? scale
        let pixels = frame.scaled(s).integral
        SetWindowPos(hwnd, nil, Int32(pixels.x), Int32(pixels.y), Int32(pixels.width), Int32(pixels.height),
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        updateSize()
        resizeSurface()
        redraw()
    }

    /// Sets the client area size (document windows), keeping the position.
    public func setContentSize(_ content: SizeF) {
        guard let hwnd else { return }
        var rect = RECT(left: 0, top: 0, right: LONG(content.width * scale), bottom: LONG(content.height * scale))
        let windowStyle = DWORD(truncatingIfNeeded: GetWindowLongPtrW(hwnd, GWL_STYLE))
        let exStyle = DWORD(truncatingIfNeeded: GetWindowLongPtrW(hwnd, GWL_EXSTYLE))
        AdjustWindowRectExForDpi(&rect, windowStyle, false, exStyle, GetDpiForWindow(hwnd))
        SetWindowPos(hwnd, nil, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                     UINT(SWP_NOZORDER | SWP_NOMOVE | SWP_NOACTIVATE))
    }

    /// The window's frame in screen pixels.
    public var pixelFrame: RECT {
        var rect = RECT()
        if let hwnd { GetWindowRect(hwnd, &rect) }
        return rect
    }

    var pixelWidth: Int { Int((size.width * scale).rounded()) }
    var pixelHeight: Int { Int((size.height * scale).rounded()) }

    // MARK: Drawing

    /// Draws now.
    public func redraw() {
        guard let surface, let hwnd, IsWindowVisible(hwnd) || true else { return }
        let pointer = surface
        guard bp_surface_begin(pointer) == 0 else { return }
        let canvas = Canvas(surface: pointer, size: size, scale: scale)
        draw?(canvas)
        let result = bp_surface_end(pointer)
        if result != 0, bp_graphics_device_lost() != 0 { recreateSurface() }
    }

    /// Draws once on the next turn of the loop (coalesces several changes into one frame).
    public func setNeedsDisplay() {
        guard !needsDisplayScheduled else { return }
        needsDisplayScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.needsDisplayScheduled = false
                self.redraw()
            }
        }
    }

    private func recreateSurface() {
        guard let hwnd else { return }
        if let surface { bp_surface_destroy(surface) }
        _ = bp_graphics_start()
        surface = bp_surface_create(UnsafeMutableRawPointer(hwnd), Int32(pixelWidth), Int32(pixelHeight), scale)
        redraw()
    }

    private func updateSize() {
        guard let hwnd else { return }
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        size = SizeF(width: Float(rect.right - rect.left) / scale, height: Float(rect.bottom - rect.top) / scale)
    }

    private func resizeSurface() {
        guard let surface else { return }
        bp_surface_resize(surface, Int32(pixelWidth), Int32(pixelHeight), scale)
    }

    // MARK: Messages

    func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        if let result = onMessage?(message, wParam, lParam) { return result }
        switch Int32(message) {
        case WM_PAINT:
            var paint = PAINTSTRUCT()
            BeginPaint(hwnd, &paint)
            EndPaint(hwnd, &paint)
            redraw()
            return 0
        case WM_ERASEBKGND:
            return 1
        case WM_SIZE:
            updateSize()
            resizeSurface()
            onResize?()
            redraw()
            return 0
        case WM_DPICHANGED:
            scale = Float(UInt16(truncatingIfNeeded: wParam)) / 96
            if let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee, let hwnd {
                SetWindowPos(hwnd, nil, suggested.left, suggested.top, suggested.right - suggested.left,
                             suggested.bottom - suggested.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            updateSize()
            resizeSurface()
            onDPIChange?()
            redraw()
            return 0
        case WM_MOUSEACTIVATE:
            if case .popup = style { return LRESULT(MA_NOACTIVATE) }
            return nil
        case WM_LBUTTONDOWN:
            if let hwnd { SetCapture(hwnd) }
            onMouseDown?(point(lParam))
            return 0
        case WM_LBUTTONUP:
            ReleaseCapture()
            onMouseUp?(point(lParam))
            return 0
        case WM_MOUSEMOVE:
            if !tracking, let hwnd {
                var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE),
                                            hwndTrack: hwnd, dwHoverTime: 0)
                TrackMouseEvent(&track)
                tracking = true
            }
            onMouseMove?(point(lParam))
            return 0
        case WM_MOUSELEAVE:
            tracking = false
            onMouseLeave?()
            return 0
        case WM_MOUSEWHEEL:
            let delta = Int16(truncatingIfNeeded: (UInt(bitPattern: Int(wParam)) >> 16) & 0xFFFF)
            onScroll?(Float(delta) / Float(WHEEL_DELTA))
            return 0
        case WM_KEYDOWN, WM_SYSKEYDOWN:
            if onKeyDown?(UInt32(wParam)) == true { return 0 }
            return nil
        case WM_CHAR:
            if let scalar = Unicode.Scalar(UInt32(wParam)), scalar.value >= 32 { onChar?(Character(scalar)) }
            return 0
        case WM_ACTIVATE:
            onActivate?(LOWORD(wParam) != WA_INACTIVE)
            return nil
        case WM_CLOSE:
            if let onClose, !onClose() { return 0 }
            hide()
            return 0
        case WM_SETCURSOR:
            if LOWORD(WPARAM(lParam)) == HTCLIENT {
                SetCursor(LoadCursorW(nil, Window.cursor))
                return 1
            }
            return nil
        default:
            return nil
        }
    }

    /// The arrow, or the hand over something clickable (set by `HitRegions`).
    nonisolated(unsafe) static var cursor: UnsafePointer<WCHAR>? = IDC.arrow

    private func point(_ lParam: LPARAM) -> PointF {
        let x = Int16(truncatingIfNeeded: lParam & 0xFFFF)
        let y = Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)
        return PointF(x: Float(x) / scale, y: Float(y) / scale)
    }
}

func LOWORD(_ value: WPARAM) -> Int32 { Int32(truncatingIfNeeded: value & 0xFFFF) }

/// The one window class every Breakpoint window uses.
@MainActor
enum WindowClass {
    static let name = "BreakpointWindow"
    static var windows: [UInt: Window] = [:]
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.style = UINT(CS_HREDRAW | CS_VREDRAW)
        windowClass.lpfnWndProc = { hwnd, message, wParam, lParam in
            MainActor.assumeIsolated {
                if let hwnd, let window = WindowClass.windows[UInt(bitPattern: hwnd)],
                   let result = window.handle(message, wParam, lParam) {
                    return result
                }
                return DefWindowProcW(hwnd, message, wParam, lParam)
            }
        }
        windowClass.hInstance = GetModuleHandleW(nil)
        windowClass.hCursor = LoadCursorW(nil, IDC.arrow)
        windowClass.hIcon = AppIcon.large
        windowClass.hIconSm = AppIcon.small
        name.withCString(encodedAs: UTF16.self) { className in
            windowClass.lpszClassName = className
            RegisterClassExW(&windowClass)
        }
    }
}

/// Cursor resource IDs (`MAKEINTRESOURCE` values, which Swift does not import).
enum IDC {
    static let arrow = UnsafePointer<WCHAR>(bitPattern: 32512)
    static let hand = UnsafePointer<WCHAR>(bitPattern: 32649)
    static let ibeam = UnsafePointer<WCHAR>(bitPattern: 32513)
}

/// `SetWindowPos` insert-after values (`(HWND)-1` and friends, which Swift does not import).
enum HWNDInsert {
    static let topmost = HWND(bitPattern: -1)
    static let notopmost = HWND(bitPattern: -2)
    static let top = HWND(bitPattern: 0)
    static let bottom = HWND(bitPattern: 1)
}
