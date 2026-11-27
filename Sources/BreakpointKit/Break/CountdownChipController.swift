import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.2.

/// Shows the countdown chip while `state.nudge?.phase == .countdownChip`.
///
/// Contract: the chip sits 20 pt right of and 20 pt below the pointer, clamped inside the
/// pointer's display, follows the pointer every frame, ignores mouse events, and is not part of
/// the `TransientPanelStack`'s layout.
///
/// Arrival: when the nudge card was on screen, the card itself becomes the chip
/// (`LiquidMotion.handoff`, 0.8 s): the stack hands this controller the card (`PopupHandoff`),
/// the chip's panel starts exactly where and as the card was, the glass gathers in and glides to
/// the pointer while the badge travels and shrinks as one object, and the chip's words come in as
/// it settles. Otherwise (Reduce Motion, no card) it grows out of its leading end like any pop-up.
/// Exit: swells into the overlay when the break starts; folds into its leading end when cancelled.
@MainActor
public final class CountdownChipController: SurfaceController {
    private let state: AppState
    private let stack: TransientPanelStack?
    private let model = ChipModel()
    private var panel: TransientPanel?
    private var followTimer: Timer?
    private var shownID: UUID?
    /// The chip's own size, without shadow margins.
    private var chipSize = CGSize.zero
    private var morph: Morph?

    /// The handoff in flight: the card it started as, in screen coordinates.
    private struct Morph {
        let start: Date
        let from: MorphShape
        let fromBadge: MorphShape
    }

    public init(state: AppState, stack: TransientPanelStack? = nil) {
        self.state = state
        self.stack = stack
    }

    public func sync() {
        guard let nudge = state.nudge, nudge.phase == .countdownChip else {
            if panel != nil { hide() }
            return
        }
        model.kind = nudge.kind
        model.remaining = nudge.autoStartRemaining ?? 0
        guard shownID != nudge.id || panel == nil else { return }
        show(id: nudge.id, handoff: stack?.takeHandoff(id: nudge.id))
    }

    public func tearDown() {
        followTimer?.invalidate()
        followTimer = nil
        panel?.close()
        panel = nil
        shownID = nil
        morph = nil
        model.morph = nil
        model.card = nil
    }

    private static var margins: NSEdgeInsets {
        let m = Theme.Glass.shadowMargin
        return NSEdgeInsets(top: m.top, left: m.leading, bottom: m.bottom, right: m.trailing)
    }

    private static func panelSize(for content: CGSize) -> CGSize {
        let m = margins
        return CGSize(width: content.width + m.left + m.right, height: content.height + m.top + m.bottom)
    }

    private func show(id: UUID, handoff: PopupHandoff?) {
        tearDown()
        model.popup = PopupModel()
        let popup = model.popup
        chipSize = NSHostingView(rootView: CountdownChipView(kind: model.kind, remaining: model.remaining).fixedSize()).fittingSize
        var content = chipSize
        if let handoff {
            content = CGSize(width: max(chipSize.width, handoff.frame.width), height: max(chipSize.height, handoff.frame.height))
            let badge = handoff.badge
            morph = Morph(start: Date(),
                          from: MorphShape(x: handoff.frame.minX, y: handoff.frame.maxY, width: handoff.frame.width,
                                           height: handoff.frame.height, radius: handoff.radius),
                          fromBadge: MorphShape(x: badge.minX, y: badge.minY, width: badge.width, height: badge.height,
                                                radius: badge.height / 2))
            model.card = handoff.content
            popup.phase = .shown
        }
        let hosting = NSHostingView(rootView: ChipHost(model: model, popup: popup))
        hosting.sizingOptions = []
        let panel = TransientPanel(contentView: hosting, size: Self.panelSize(for: content))
        panel.cardInsets = Self.margins
        panel.ignoresMouseEvents = true
        // Above the other pop-ups: it is the most immediate thing on screen.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        self.panel = panel
        shownID = id
        follow()
        panel.orderFrontRegardless()
        if handoff == nil {
            DispatchQueue.main.async { [weak popup] in popup?.phase = .shown }
        }
        let timer = Timer(timeInterval: BreakTiming.chipFollowInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func hide() {
        followTimer?.invalidate()
        followTimer = nil
        guard let panel else { return }
        self.panel = nil
        shownID = nil
        if morph != nil {
            // Cancelled mid-glide: no shape to fold, so it simply fades.
            morph = nil
            panel.fadeOut(duration: Theme.Motion.countdownChipExit) { panel.close() }
            return
        }
        // The break started: swell into the overlay. Cancelled: fold into the leading end.
        let exit: PopupExit = state.activeBreak != nil ? .accepted : .timeout
        model.popup.phase = .leaving(exit)
        DispatchQueue.main.asyncAfter(deadline: .now() + exit.duration(reduceMotion: SystemMotion.reduceMotion) + 0.03) {
            panel.close()
        }
    }

    /// The chip's top-left corner on screen: 20 pt right of and below the pointer; flips to the
    /// other side near a display edge so the chip stays whole on the pointer's display.
    private func chipTopLeft() -> CGPoint? {
        let pointer = NSEvent.mouseLocation
        guard let screen = ActiveDisplay.screen(containing: pointer) else { return nil }
        let chip = chipSize
        let offset = Theme.Layout.countdownChipPointerOffset
        let bounds = screen.frame
        var x = pointer.x + offset
        var top = pointer.y - offset
        if x + chip.width > bounds.maxX { x = pointer.x - offset - chip.width }
        if top - chip.height < bounds.minY { top = pointer.y + offset + chip.height }
        x = min(max(x, bounds.minX), bounds.maxX - chip.width)
        top = min(max(top, bounds.minY + chip.height), bounds.maxY)
        return CGPoint(x: x.rounded(), y: top.rounded())
    }

    private func follow() {
        guard let panel, let target = chipTopLeft() else { return }
        let m = Self.margins
        var topLeft = target
        if let morph {
            let to = MorphShape(x: target.x, y: target.y, width: chipSize.width, height: chipSize.height,
                                radius: chipSize.height / 2)
            let toBadge = MorphShape.circle(x: CountdownChipView.badgeInset, y: (chipSize.height - Theme.Layout.countdownChipBadge) / 2,
                                            diameter: Theme.Layout.countdownChipBadge)
            let frame = LiquidMotion.handoff(at: Date().timeIntervalSince(morph.start), from: morph.from, to: to,
                                             fromBadge: morph.fromBadge, toBadge: toBadge)
            if frame.finished {
                self.morph = nil
                model.morph = nil
                model.card = nil
                panel.setFrame(CGRect(origin: panel.frame.origin, size: Self.panelSize(for: chipSize)), display: false)
            } else {
                model.morph = frame
                topLeft = CGPoint(x: frame.shape.x, y: frame.shape.y)
            }
        }
        let size = panel.frame.size
        let frame = CGRect(x: topLeft.x - m.left, y: topLeft.y + m.top - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

@MainActor
private final class ChipModel: ObservableObject {
    @Published var kind: BreakKind = .eyes
    @Published var remaining: TimeInterval = 0
    /// The handoff frame while the nudge card is becoming the chip.
    @Published var morph: LiquidMotion.HandoffFrame?
    /// The nudge card's content during the handoff.
    var card: AnyView?
    var popup = PopupModel()
}

private struct ChipHost: View {
    @ObservedObject var model: ChipModel
    @ObservedObject var popup: PopupModel

    var body: some View {
        let margin = Theme.Glass.shadowMargin
        ZStack(alignment: .topLeading) {
            if let morph = model.morph, let card = model.card {
                NudgeChipMorphView(frame: morph, card: card, kind: model.kind, remaining: model.remaining)
            } else {
                CountdownChipView(kind: model.kind, remaining: model.remaining)
                    .popupMotion(popup.phase, anchor: .leading)
            }
        }
        .padding(.top, margin.top)
        .padding(.leading, margin.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One frame of the nudge card becoming the countdown chip (`LiquidMotion.handoff`), drawn from
/// the glass's own top-left corner: the glass at its current shape, the card's words blurring
/// out, the chip's words coming in, and the kind badge travelling between the two as one object.
public struct NudgeChipMorphView: View {
    private let frame: LiquidMotion.HandoffFrame
    private let card: AnyView
    private let kind: BreakKind
    private let remaining: TimeInterval

    public init(frame: LiquidMotion.HandoffFrame, card: AnyView, kind: BreakKind, remaining: TimeInterval) {
        self.frame = frame
        self.card = card
        self.kind = kind
        self.remaining = remaining
    }

    public var body: some View {
        let width = max(1, frame.shape.width)
        let height = max(1, frame.shape.height)
        let glass = LiquidGlassShape(shape: MorphShape(x: 0, y: 0, width: width, height: height, radius: frame.shape.radius))
        ZStack(alignment: .topLeading) {
            card
                .environment(\.glassSurfaceHosted, true)
                .scaleEffect(frame.cardScale, anchor: .topLeading)
                .blur(radius: frame.cardBlur)
                .opacity(frame.cardOpacity)
            CountdownChipView(kind: kind, remaining: remaining)
                .environment(\.glassSurfaceHosted, true)
                .opacity(frame.chipOpacity)
            KindBadge(kind: kind)
                .scaleEffect(frame.badge.width / Theme.Layout.badge, anchor: .topLeading)
                .offset(x: frame.badge.x, y: frame.badge.y)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(glass)
        .background(GlassPanelBackground(glass))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}
