import AppKit
import BreakpointRuntime

/// The active display: the `NSScreen` under the pointer (SPEC §3.0, decision 2).
public enum ActiveDisplay {
    /// The screen containing the pointer, else the main screen, else the first screen.
    @MainActor
    public static func screen() -> NSScreen? {
        screen(containing: NSEvent.mouseLocation)
    }

    /// The screen containing `point` (global coordinates), else the main screen, else the first.
    @MainActor
    public static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The top edge for pop-ups on `screen`: 8 pt below the menu bar or notch,
    /// `min(visibleFrame.maxY, frame.maxY − safeAreaInsets.top) − 8` (SPEC §3.0).
    @MainActor
    public static func popupTopEdge(on screen: NSScreen) -> CGFloat {
        min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top) - Theme.Layout.popupTopGap
    }

    /// A stable identifier for `screen` (survives rearrangement; changes if the display goes away).
    @MainActor
    public static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The screen with `id`, if it is still connected.
    @MainActor
    public static func screen(withID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID($0) == id }
    }

    /// The top safe-area inset (notch or menu bar area) used to place the overlay's agent chip
    /// (SPEC §3.3: 40 pt below the safe-area top).
    @MainActor
    public static func safeAreaTop(of screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top
    }
}
