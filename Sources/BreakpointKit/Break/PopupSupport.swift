import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// Shared plumbing for every pop-up (nudge, countdown chip, resume
// card, away note, toasts, wind-down): presence and motion (SPEC §4.6), hover tracking that works
// in a non-activating panel of an inactive app, and size reporting so a panel follows its card.

// MARK: - Presence and motion

/// Where a pop-up is in its life. The view animates between phases; the controller closes the
/// window once an exit has played (`exitDuration`).
public enum PopupPhase: Equatable, Sendable {
    /// Ordered front but not yet arrived (8 pt above, transparent, 6 pt blur).
    case arriving
    /// At rest.
    case shown
    /// Leaving.
    case leaving(PopupExit)
}

/// How a pop-up leaves (SPEC §4.6).
public enum PopupExit: Equatable, Sendable {
    /// Timed out: the glass folds up into the point it grew from (content first), drifting 4 pt
    /// up, 0.35 s ease-in.
    case timeout
    /// After an action, or withdrawn: settles 4% towards the top edge as it fades, 0.2 s.
    case action
    /// The nudge on Start: scale 1.0 → 1.04 and fade over 0.2 s while the overlay arrives.
    case accepted
    /// The nudge becoming the countdown chip: the chip's panel draws the card from here on, so
    /// this one goes at once (SPEC §3.2).
    case handoff

    /// How long the exit plays (the same under Reduce Motion, where every exit is a ≤ 0.2 s fade).
    public func duration(reduceMotion: Bool) -> TimeInterval {
        if self == .handoff { return 0 }
        if reduceMotion { return Theme.Motion.reduceMotionFade }
        switch self {
        case .timeout: return Theme.Motion.popupOutTimeoutDuration
        case .action: return Theme.Motion.popupOutActionDuration
        case .accepted: return Theme.Motion.nudgeStartExitDuration
        case .handoff: return 0
        }
    }
}

/// Observable state of one live pop-up, owned by its controller.
@MainActor
final class PopupModel: ObservableObject {
    @Published var phase: PopupPhase = .arriving
    /// The pointer is over the card (AppKit tracking area, works while the app is inactive).
    @Published var hovering = false
    /// The pointer has rested on the card for `BreakTiming.hoverRest` (nudge reveal).
    @Published var revealed = false
    private var revealWork: DispatchWorkItem?

    func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        revealWork?.cancel()
        if value {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hovering else { return }
                    self.revealed = true
                }
            }
            revealWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + BreakTiming.hoverRest, execute: work)
        } else {
            revealed = false
        }
    }
}

/// Where a pop-up's glass grows from and folds back to.
enum PopupAnchor {
    /// The middle of the top edge: pop-ups under the menu bar.
    case top
    /// The leading end: the countdown chip, beside the pointer.
    case leading

    var x: Double { self == .top ? 0.5 : 0 }
}

/// Applies a pop-up's phase as motion (SPEC §4.6 "Liquid pop-ups"). The card's glass grows out of
/// a small capsule under its top edge on a soft spring (response 0.5, damping 0.82), spreading
/// along the edge first and then dropping open, and its content comes into focus once the glass
/// is mostly open. A timeout folds it back up into that point; an action settles it as it fades;
/// Start swells it into the overlay. Under Reduce Motion every change is a 0.2 s cross-fade.
struct PopupMotion: ViewModifier {
    let phase: PopupPhase
    var anchor: PopupAnchor = .top
    private let traits = DesignTraits()

    func body(content: Content) -> some View {
        let target = self.target(traits.reduceMotion)
        content
            .modifier(LiquidPopupPose(mode: target.mode, progress: target.progress, anchorX: anchor.x))
            .animation(animation(traits.reduceMotion), value: phase)
    }

    private func target(_ reduceMotion: Bool) -> (mode: LiquidMotion.Mode, progress: Double) {
        if phase == .leaving(.handoff) { return (.handoff, 0) }
        if reduceMotion { return (.crossfade, phase == .shown ? 1 : 0) }
        switch phase {
        case .arriving: return (.grow, 0)
        case .shown: return (.grow, 1)
        case .leaving(.timeout): return (.retract, 0)
        case .leaving(.action): return (.fade, 0)
        case .leaving(.accepted): return (.swell, 0)
        case .leaving(.handoff): return (.handoff, 0)
        }
    }

    private func animation(_ reduceMotion: Bool) -> Animation? {
        switch phase {
        case .arriving, .leaving(.handoff): return nil
        case .shown: return Theme.Motion.animation(.popupIn, reduceMotion: reduceMotion)
        case .leaving(.timeout): return Theme.Motion.animation(.popupOutTimeout, reduceMotion: reduceMotion)
        case .leaving(.action): return Theme.Motion.animation(.popupOutAction, reduceMotion: reduceMotion)
        case .leaving(.accepted): return Theme.Motion.animation(.nudgeStartExit, reduceMotion: reduceMotion)
        }
    }
}

extension View {
    func popupMotion(_ phase: PopupPhase, anchor: PopupAnchor = .top) -> some View {
        modifier(PopupMotion(phase: phase, anchor: anchor))
    }
}

/// One pose of a pop-up (`LiquidMotion.pose`), drawn: the glass at its current shape behind the
/// card's content, the content clipped to it. `progress` animates, so SwiftUI's spring and curves
/// drive it live; the motion film sets it frame by frame. The card's own `GlassCard` or
/// `GlassCapsule` draws no glass inside this (`glassSurfaceHosted`) and reports its radius.
public struct LiquidPopupPose: ViewModifier, Animatable {
    public var mode: LiquidMotion.Mode
    public var progress: Double
    public var anchorX: Double

    public init(mode: LiquidMotion.Mode, progress: Double, anchorX: Double = 0.5) {
        self.mode = mode
        self.progress = progress
        self.anchorX = anchorX
    }

    public var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private func pose(_ size: CGSize, _ radius: CGFloat) -> LiquidMotion.Pose {
        LiquidMotion.pose(mode, progress: progress, width: size.width, height: size.height, radius: radius, anchorX: anchorX)
    }

    public func body(content: Content) -> some View {
        // Content values do not depend on the size.
        let look = pose(.zero, 0)
        content
            .environment(\.glassSurfaceHosted, true)
            .opacity(look.contentOpacity)
            .blur(radius: look.contentBlur)
            .offset(y: look.contentOffsetY)
            .mask {
                GeometryReader { proxy in
                    // Every pop-up's corner is the card radius or a full capsule (min with h/2).
                    let pose = pose(proxy.size, Theme.Radius.card)
                    if pose.isRest || pose.shapeOpacity == 0 && pose.contentOpacity == 0 {
                        // At rest nothing is clipped (the hover × sits on the rim).
                        Rectangle().padding(-Theme.Glass.shadowMargin.leading)
                    } else {
                        LiquidGlassShape(shape: pose.shape).fill(Color.black)
                    }
                }
            }
            .backgroundPreferenceValue(GlassSurfaceRadiusKey.self) { radius in
                GeometryReader { proxy in
                    if let radius {
                        let pose = pose(proxy.size, radius)
                        GlassPanelBackground(LiquidGlassShape(shape: pose.shape))
                            .opacity(pose.shapeOpacity)
                    }
                }
            }
            .scaleEffect(look.scale, anchor: .top)
            .opacity(look.opacity)
    }
}

/// A `MorphShape` as a SwiftUI shape: a continuous rounded rectangle, or a true capsule (circular
/// ends) once the radius reaches half the height, as `GlassCapsule` draws it.
struct LiquidGlassShape: InsettableShape {
    var shape: MorphShape
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let frame = CGRect(x: rect.minX + shape.x, y: rect.minY + shape.y, width: max(0, shape.width), height: max(0, shape.height))
            .insetBy(dx: inset, dy: inset)
        guard frame.width > 0, frame.height > 0 else { return Path() }
        let radius = max(0, min(shape.radius - inset, frame.height / 2, frame.width / 2))
        let style: RoundedCornerStyle = radius >= frame.height / 2 - 0.01 ? .circular : .continuous
        return RoundedRectangle(cornerRadius: radius, style: style).path(in: frame)
    }

    func inset(by amount: CGFloat) -> LiquidGlassShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// The system Reduce Motion setting, for controllers (views use `DesignTraits`).
@MainActor
enum SystemMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

// MARK: - Hover close button placement

/// Puts the design system's 16 pt × at the card's top-leading corner, centred on the rim where
/// the 28 pt corner curve is (like a system notification's close button), visible while
/// `visible` and fading 0.15 s.
struct CornerCloseButton: ViewModifier {
    let visible: Bool
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if let action {
                HoverCloseButton(action: action)
                    .offset(x: -4, y: -4)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .animation(Theme.Motion.closeButtonFade, value: visible)
            }
        }
    }
}

extension View {
    func cornerCloseButton(visible: Bool, action: (() -> Void)?) -> some View {
        modifier(CornerCloseButton(visible: visible, action: action))
    }
}

// MARK: - Hosting

/// Size of the card plus its shadow margins, reported up to the panel.
struct PopupSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The root of every pop-up panel: the card at its ideal size, top-anchored inside the shadow
/// margins, reporting its size so the panel can follow it.
struct PopupRoot<Content: View>: View {
    let insets: EdgeInsets
    let onSize: (CGSize) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        content
            .fixedSize()
            .padding(insets)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PopupSizeKey.self, value: proxy.size)
            })
            .onPreferenceChange(PopupSizeKey.self) { size in
                MainActor.assumeIsolated { onSize(size) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Hosting view for pop-ups: accepts the first click (so buttons work while another app is
/// active), tracks hover over the card itself (not the shadow margins) with an `.activeAlways`
/// tracking area, and lets clicks in the margins fall through to nothing.
final class PopupHostingView<Content: View>: NSHostingView<Content> {
    var cardInsets = NSEdgeInsets()
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var inside = false
    /// Where the pointer rested when the pop-up appeared. A pop-up that appears under a pointer
    /// nobody is moving (parked over a browser's tabs, say) is not being hovered: hover would
    /// pause its timeout for as long as the pointer stays put, and cancel an eye-rest auto-start
    /// at once. Hover counts from the pointer's first movement.
    private var parkedPointer: NSPoint?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The visible card, in this view's coordinates.
    var cardRect: CGRect {
        let r = bounds
        let height = max(0, r.height - cardInsets.top - cardInsets.bottom)
        let y = isFlipped ? cardInsets.top : r.height - cardInsets.top - height
        return CGRect(x: cardInsets.left, y: y, width: max(0, r.width - cardInsets.left - cardInsets.right), height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        refreshHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        parkedPointer = window == nil ? nil : NSEvent.mouseLocation
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        parkedPointer = nil
        setInside(true)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        parkedPointer = nil
        refreshHover()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setInside(false)
    }

    /// Re-reads the pointer position (after a resize the tracking area can miss an exit).
    func refreshHover() {
        guard let window else { return }
        if let parked = parkedPointer {
            guard NSEvent.mouseLocation != parked else { return setInside(false) }
            parkedPointer = nil
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setInside(cardRect.contains(point))
    }

    private func setInside(_ value: Bool) {
        guard value != inside else { return }
        inside = value
        onHoverChange?(value)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates.
        let local = convert(point, from: superview)
        guard cardRect.insetBy(dx: -10, dy: -10).contains(local) else { return nil }
        return super.hitTest(point)
    }
}
