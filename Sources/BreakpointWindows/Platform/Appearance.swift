import CBreakpointWin32
import Foundation
import WinSDK

/// The system's look for each kind of window (SPEC §4.5 on Windows): Windows 11's own materials
/// stand in for macOS's glass.
///
/// - Pop-ups and the popover: the transient-window backdrop (Acrylic, a live blur of what is
///   behind) with system rounded corners and the system's thin border; always dark (SPEC §4.2).
/// - Settings and Onboarding: Mica, following the system's light or dark mode.
/// - With "Transparency effects" off (Settings → Personalization → Colours), or on Windows 10,
///   DWM draws no backdrop and the windows fill themselves opaque: `prefersOpaque` says so.
public enum Appearance {
    // DWMWINDOWATTRIBUTE values (dwmapi.h), as numbers so older SDK headers do not matter.
    private static let useImmersiveDarkMode: DWORD = 20
    private static let windowCornerPreference: DWORD = 33
    private static let borderColour: DWORD = 34
    private static let systemBackdropType: DWORD = 38
    // DWM_SYSTEMBACKDROP_TYPE
    private static let backdropMica: Int32 = 2
    private static let backdropTransient: Int32 = 3
    // DWM_WINDOW_CORNER_PREFERENCE
    private static let cornerRound: Int32 = 2
    private static let cornerRoundSmall: Int32 = 3

    static func prepare(_ hwnd: HWND, style: Window.Style) {
        switch style {
        case .popup, .flyout:
            setDark(hwnd, true)
            set(hwnd, windowCornerPreference, cornerRound)
            if !prefersOpaque { set(hwnd, systemBackdropType, backdropTransient) }
            extendFrame(hwnd)
        case .overlay:
            setDark(hwnd, true)
        case .document:
            setDark(hwnd, isDarkMode)
            if !prefersOpaque { set(hwnd, systemBackdropType, backdropMica) }
            extendFrame(hwnd)
        }
    }

    /// Re-applies light or dark to a document window after the system mode changes.
    static func refresh(_ hwnd: HWND) { setDark(hwnd, isDarkMode) }

    /// Apps are set to dark mode (Settings → Personalization → Colours → Choose your app mode).
    public static var isDarkMode: Bool { registryDWORD("AppsUseLightTheme") == 0 }

    /// Transparency effects are off, or the system cannot draw backdrops (before Windows 11 22H2).
    public static var prefersOpaque: Bool {
        registryDWORD("EnableTransparency") == 0 || !supportsBackdrops
    }

    /// High contrast is on (SPEC §4.8 Increase Contrast).
    public static var highContrast: Bool {
        var info = HIGHCONTRASTW()
        info.cbSize = UINT(MemoryLayout<HIGHCONTRASTW>.size)
        guard SystemParametersInfoW(UINT(SPI_GETHIGHCONTRAST), info.cbSize, &info, 0) else { return false }
        return info.dwFlags & DWORD(HCF_HIGHCONTRASTON) != 0
    }

    /// "Animation effects" are off (Settings → Accessibility → Visual effects): Reduce Motion.
    public static var reduceMotion: Bool {
        var enabled: WindowsBool = true
        guard SystemParametersInfoW(UINT(SPI_GETCLIENTAREAANIMATION), 0, &enabled, 0) else { return false }
        return !enabled.boolValue
    }

    /// Windows 11 22H2 (build 22621) or later: the system backdrop attribute exists.
    static let supportsBackdrops: Bool = {
        var info = OSVERSIONINFOEXW()
        info.dwOSVersionInfoSize = DWORD(MemoryLayout<OSVERSIONINFOEXW>.size)
        // RtlGetVersion is not shimmed by the app's compatibility manifest the way GetVersionEx is.
        typealias RtlGetVersion = @convention(c) (UnsafeMutablePointer<OSVERSIONINFOEXW>) -> Int32
        guard let ntdll = GetModuleHandleW("ntdll.dll".wide), let address = GetProcAddress(ntdll, "RtlGetVersion") else {
            return false
        }
        let call = unsafeBitCast(address, to: RtlGetVersion.self)
        _ = call(&info)
        return info.dwBuildNumber >= 22621
    }()

    private static func setDark(_ hwnd: HWND, _ dark: Bool) {
        set(hwnd, useImmersiveDarkMode, dark ? 1 : 0)
    }

    private static func set(_ hwnd: HWND, _ attribute: DWORD, _ value: Int32) {
        var value = value
        _ = DwmSetWindowAttribute(hwnd, attribute, &value, DWORD(MemoryLayout<Int32>.size))
    }

    /// The backdrop shows through the whole client area (our content is drawn on top of it).
    private static func extendFrame(_ hwnd: HWND) {
        var margins = MARGINS(cxLeftWidth: -1, cxRightWidth: -1, cyTopHeight: -1, cyBottomHeight: -1)
        _ = DwmExtendFrameIntoClientArea(hwnd, &margins)
    }

    private static func registryDWORD(_ name: String) -> DWORD? {
        var value: DWORD = 0
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = RegGetValueW(HKEY_CURRENT_USER, "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".wide,
                                  name.wide, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
        return status == ERROR_SUCCESS ? value : nil
    }
}

extension String {
    /// The string as a NUL-terminated UTF-16 buffer, for Win32 calls.
    public var wide: [WCHAR] { Array(utf16) + [0] }
}

