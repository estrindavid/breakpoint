import AppKit
import SwiftUI
import BreakpointCore

/// A non-activating pop-up panel (SPEC §3.0): `.nonactivatingPanel`, level `.statusBar`,
/// `[.canJoinAllSpaces, .fullScreenAuxiliary]`, transparent, `sharingType = .none`, never key unless
/// `allowsKey` (only the wind-down card, after the user clicks into it).
///
/// The window is the card plus `cardInsets` of transparent room for the glass shadows. Built with
/// `init(rootView:)`, it follows its card's size: it grows at once and shrinks after the card's own
/// animation (`BreakTiming.panelShrinkDelay`), top edge fixed, through the stack's layout.
public final class TransientPanel: NSPanel {
    public var allowsKey = false
    /// Transparent room around the visible card (shadows).
    public var cardInsets = NSEdgeInsets()
    /// The size the panel wants (card + insets). The stack lays panels out with it.
    public private(set) var preferredSize: CGSize
    /// Set by the stack: the preferred size changed.
    var onPreferredSizeChange: ((TransientPanel) -> Void)?
    /// The pointer entered or left the card (works while Breakpoint is inactive).
    public var onHoverChange: ((Bool) -> Void)? {
        didSet { hosting?.onHoverChangeErased = onHoverChange }
    }
    /// Key events while this panel is key (wind-down card): return true to consume.
    public var keyHandler: ((NSEvent) -> Bool)?
    /// Set when the user clicks into a panel that `allowsKey`.
    public var onBecameKey: (() -> Void)?

    private var hosting: HoverReporting?
    private var shrinkWork: DispatchWorkItem?

    public init(contentView: NSView, size: CGSize) {
        preferredSize = size
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        // Buttons keep working while one of the app's alerts runs modally (an alert left open
        // behind other windows would otherwise make every pop-up deaf for as long as it stays).
        worksWhenModal = true
        animationBehavior = .none
        isMovable = false
        self.contentView = contentView
    }

    /// A panel hosting `rootView` (the card itself) with `Theme.Glass.shadowMargin` around it.
    public convenience init<V: View>(rootView: V) {
        let margin = Theme.Glass.shadowMargin
        let insets = NSEdgeInsets(top: margin.top, left: margin.leading, bottom: margin.bottom, right: margin.trailing)
        let sizeBox = SizeBox()
        let root = PopupRoot(insets: margin, onSize: { sizeBox.report?($0) }) { rootView }
        let hosting = PopupHostingView(rootView: root)
        hosting.cardInsets = insets
        // Measure once up front so the first frame is right.
        let measure = NSHostingView(rootView: rootView.fixedSize().padding(margin))
        let initial = measure.fittingSize
        self.init(contentView: hosting, size: initial)
        hosting.frame = CGRect(origin: .zero, size: initial)
        hosting.autoresizingMask = [.width, .height]
        cardInsets = insets
        self.hosting = hosting
        sizeBox.report = { [weak self] size in self?.contentDidResize(to: size) }
    }

    public override var canBecomeKey: Bool { allowsKey }
    public override var canBecomeMain: Bool { false }

    public override func becomeKey() {
        super.becomeKey()
        onBecameKey?()
    }

    public override func sendEvent(_ event: NSEvent) {
        if (event.type == .keyDown || event.type == .keyUp), let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }

    private func contentDidResize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let rounded = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard rounded != preferredSize else {
            shrinkWork?.cancel()
            return
        }
        shrinkWork?.cancel()
        let grows = rounded.height >= preferredSize.height && rounded.width >= preferredSize.width
        let apply = { [weak self] in
            guard let self else { return }
            self.preferredSize = rounded
            self.onPreferredSizeChange?(self)
            self.hosting?.refreshHoverErased()
        }
        if grows {
            apply()
        } else {
            let work = DispatchWorkItem { MainActor.assumeIsolated { apply() } }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + BreakTiming.panelShrinkDelay, execute: work)
        }
    }

    /// Fades the window out (evictions), then orders it out.
    func fadeOut(duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            self.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.orderOut(nil)
                completion?()
            }
        })
    }
}

/// Lets the panel reach its hosting view without knowing the SwiftUI content type.
@MainActor
private protocol HoverReporting: AnyObject {
    var onHoverChangeErased: ((Bool) -> Void)? { get set }
    func refreshHoverErased()
}

extension PopupHostingView: HoverReporting {
    var onHoverChangeErased: ((Bool) -> Void)? {
        get { onHoverChange }
        set { onHoverChange = newValue }
    }
    func refreshHoverErased() { refreshHover() }
}

@MainActor
private final class SizeBox {
    var report: ((CGSize) -> Void)?
}

/// Positions every pop-up (SPEC §3.0): on the active display at the chosen position, top edge 8 pt
/// below the menu bar or notch, side positions inset 16 pt, stacked downward with 8 pt gaps, at
/// most 2 at once. When a third arrives, the lowest `PopupPriority` is removed (and reported via
/// `onEvicted`). No surface positions itself.
///
/// Contract:
/// - `present` shows `panel` for `id` (or replaces the panel already shown for `id`) and lays
///   out the stack. Entrance animation per SPEC §4.6 is the caller's view's job; the stack only
///   orders the window front.
/// - `dismiss` removes and orders out the panel for `id` (the caller animates the content first).
/// - `relayout` re-reads the active display and position (after screen or settings changes).
/// - Panel frames account for `Theme.Glass.shadowMargin` so the visible card edge sits on the grid.
///
/// Order, top to bottom: highest priority first, then oldest first (so the most urgent card is
/// nearest the menu bar and the nudge is always lowest). The display is chosen when the stack
/// goes from empty to non-empty (the display under the pointer then) and kept while anything is
/// showing, so cards never jump between displays; it is re-chosen if that display goes away.
@MainActor
public final class TransientPanelStack {
    public var position: () -> PopupPosition
    /// Called when a panel is removed because a higher-priority one arrived.
    public var onEvicted: ((UUID) -> Void)?

    private struct Entry {
        let id: UUID
        let panel: NSPanel
        let priority: PopupPriority
        let order: Int
    }

    private var entries: [Entry] = []
    /// Panels that hang from an anchor outside the stack (the tour's coach card under the
    /// menu-bar mark, SPEC §3.12): never counted toward the limit, never evicted.
    private var hanging: [UUID: (panel: TransientPanel, anchor: CGRect)] = [:]
    private var handoffs: [UUID: PopupHandoff] = [:]
    /// Panels playing their exit: they keep their place until `dismiss`, but no longer count
    /// toward the limit and are never chosen for eviction (a card that is already going must not
    /// push out the one arriving, e.g. the "Timers restored" toast that replaces an away note).
    private var leaving: Set<UUID> = []
    private var nextOrder = 0
    private var anchorDisplay: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?

    public init(position: @escaping () -> PopupPosition) {
        self.position = position
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    /// The ids currently shown, top to bottom.
    public var visibleIDs: [UUID] { sorted.map(\.id) }

    public func present(_ panel: NSPanel, id: UUID, priority: PopupPriority) {
        if entries.isEmpty { anchorDisplay = ActiveDisplay.screen().flatMap(ActiveDisplay.displayID) }
        leaving.remove(id)
        if let index = entries.firstIndex(where: { $0.id == id }) {
            let old = entries[index]
            if old.panel !== panel { old.panel.orderOut(nil) }
            entries[index] = Entry(id: id, panel: panel, priority: priority, order: old.order)
        } else {
            entries.append(Entry(id: id, panel: panel, priority: priority, order: nextOrder))
            nextOrder += 1
        }
        if let transient = panel as? TransientPanel {
            transient.onPreferredSizeChange = { [weak self] _ in self?.relayout(animated: true) }
        }
        var evicted: [UUID] = []
        while entries.filter({ !leaving.contains($0.id) }).count > Theme.Layout.popupMaxStack {
            // Lowest priority goes; among equals, the oldest.
            guard let victim = entries.filter({ !leaving.contains($0.id) })
                .min(by: { ($0.priority, $0.order) < ($1.priority, $1.order) }) else { break }
            entries.removeAll { $0.id == victim.id }
            if let transient = victim.panel as? TransientPanel, transient.isVisible {
                transient.fadeOut(duration: BreakTiming.evictionFade)
            } else {
                victim.panel.orderOut(nil)
            }
            evicted.append(victim.id)
        }
        relayout(animated: true, placingAtOnce: id)
        if entries.contains(where: { $0.id == id }) {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        for victim in evicted { onEvicted?(victim) }
    }

    /// The panel for `id` has started its exit; `dismiss` follows when the exit is over.
    public func markLeaving(id: UUID) {
        if entries.contains(where: { $0.id == id }) { leaving.insert(id) }
    }

    // MARK: Hanging from an anchor (the tour's coach card under the menu-bar mark)

    /// Where a card `cardWidth` wide hangs from `anchor` (screen coordinates): its leading x,
    /// centred under the anchor but kept 16 pt inside the display, and the anchor's centre measured
    /// from the card's leading edge (where its pointer goes).
    public static func hangingPlacement(cardWidth: CGFloat, anchor: CGRect, on screen: NSScreen) -> (cardX: CGFloat, pointerX: CGFloat) {
        let visible = screen.visibleFrame
        let lowest = visible.minX + Theme.Layout.popupSideInset
        let highest = visible.maxX - Theme.Layout.popupSideInset - cardWidth
        let cardX = min(max((anchor.midX - cardWidth / 2).rounded(), lowest), max(lowest, highest))
        return (cardX, anchor.midX - cardX)
    }

    /// Shows `panel` hanging just under `anchor` (its pointer reaches up to it), outside the stack.
    public func presentHanging(_ panel: TransientPanel, id: UUID, below anchor: CGRect) {
        hanging[id] = (panel, anchor)
        panel.onPreferredSizeChange = { [weak self] _ in self?.layoutHanging(id: id) }
        layoutHanging(id: id)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func layoutHanging(id: UUID) {
        guard let (panel, anchor) = hanging[id] else { return }
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main
        guard let screen else { return }
        let insets = panel.cardInsets
        let size = panel.preferredSize
        let cardWidth = size.width - insets.left - insets.right
        let cardHeight = size.height - insets.top - insets.bottom
        let cardX = Self.hangingPlacement(cardWidth: cardWidth, anchor: anchor, on: screen).cardX
        // The pointer's dot sits just under the mark, clear of the menu bar.
        let top = anchor.minY - 4
        let frame = CGRect(x: cardX - insets.left, y: top - cardHeight - insets.bottom, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    public func dismiss(id: UUID) {
        if let hung = hanging.removeValue(forKey: id) {
            hung.panel.orderOut(nil)
            return
        }
        leaving.remove(id)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index).panel.orderOut(nil)
        if entries.isEmpty { anchorDisplay = nil }
        relayout(animated: true)
    }

    // MARK: Handoff (the nudge becoming the countdown chip, SPEC §3.2)

    /// The card for `id` is turning into another surface: keep where it was and what it showed
    /// for the surface that takes over (`takeHandoff`), which draws it from now on.
    public func handOff(_ handoff: PopupHandoff, id: UUID) {
        handoffs = handoffs.filter { $0.value.isFresh }
        handoffs[id] = handoff
    }

    /// The card handed off for `id` in the last moment, once.
    public func takeHandoff(id: UUID) -> PopupHandoff? {
        guard let handoff = handoffs.removeValue(forKey: id), handoff.isFresh else { return nil }
        return handoff
    }

    /// The visible card of the panel shown for `id`, in screen coordinates.
    public func cardFrame(id: UUID) -> CGRect? {
        guard let entry = entries.first(where: { $0.id == id }), entry.panel.isVisible else { return nil }
        guard let transient = entry.panel as? TransientPanel else { return entry.panel.frame }
        let insets = transient.cardInsets
        let frame = transient.frame
        return CGRect(x: frame.minX + insets.left, y: frame.minY + insets.bottom,
                      width: frame.width - insets.left - insets.right, height: frame.height - insets.top - insets.bottom)
    }

    public func dismissAll() {
        hanging.values.forEach { $0.panel.orderOut(nil) }
        hanging.removeAll()
        entries.forEach { $0.panel.orderOut(nil) }
        entries.removeAll()
        leaving.removeAll()
        handoffs.removeAll()
        anchorDisplay = nil
    }

    public func relayout() { relayout(animated: false) }

    // MARK: Layout

    private var sorted: [Entry] {
        entries.sorted { ($0.priority, -$0.order) > ($1.priority, -$1.order) }
    }

    private var anchorScreen: NSScreen? {
        if let anchorDisplay, let screen = NSScreen.screens.first(where: { ActiveDisplay.displayID($0) == anchorDisplay }) {
            return screen
        }
        let screen = ActiveDisplay.screen()
        anchorDisplay = screen.flatMap(ActiveDisplay.displayID)
        return screen
    }

    /// The frame for each panel, top to bottom. Exposed for tests of the layout rules.
    func frames(on screen: NSScreen) -> [(UUID, CGRect)] {
        var top = ActiveDisplay.popupTopEdge(on: screen)
        var result: [(UUID, CGRect)] = []
        for entry in sorted {
            let insets = (entry.panel as? TransientPanel)?.cardInsets ?? NSEdgeInsets()
            let size = (entry.panel as? TransientPanel)?.preferredSize ?? entry.panel.frame.size
            let cardWidth = size.width - insets.left - insets.right
            let cardHeight = size.height - insets.top - insets.bottom
            let cardX: CGFloat
            switch position() {
            case .topLeft: cardX = screen.visibleFrame.minX + Theme.Layout.popupSideInset
            case .topCentre: cardX = (screen.frame.midX - cardWidth / 2).rounded()
            case .topRight: cardX = screen.visibleFrame.maxX - Theme.Layout.popupSideInset - cardWidth
            }
            let cardMinY = top - cardHeight
            let frame = CGRect(x: cardX - insets.left, y: cardMinY - insets.bottom, width: size.width, height: size.height)
            result.append((entry.id, frame))
            top = cardMinY - Theme.Layout.popupStackGap
        }
        return result
    }

    private func relayout(animated: Bool, placingAtOnce newID: UUID? = nil) {
        guard let screen = anchorScreen else { return }
        let animate = animated && !SystemMotion.reduceMotion
        let targets = frames(on: screen)
        for (id, frame) in targets {
            guard let entry = entries.first(where: { $0.id == id }) else { continue }
            let panel = entry.panel
            if panel.frame == frame { continue }
            let sizeChanged = panel.frame.size != frame.size
            if !animate || id == newID || !panel.isVisible || sizeChanged {
                // Size changes are instant so the card never clips; its content animates itself.
                panel.setFrame(frame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = BreakTiming.stackSlide
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            }
        }
    }
}

/// A pop-up card handed to another surface that will draw it from now on (SPEC §3.2): where its
/// glass was on screen and what it showed, so the next surface can start as exactly that card.
public struct PopupHandoff {
    /// The visible card, screen coordinates.
    public var frame: CGRect
    public var radius: CGFloat
    /// The shared element (the kind badge) inside the card, from its top-left corner, y down.
    public var badge: CGRect
    /// The card's content; drawn with `glassSurfaceHosted`, so without its own glass.
    public var content: AnyView
    let created = Date()

    public init(frame: CGRect, radius: CGFloat, badge: CGRect, content: AnyView) {
        self.frame = frame
        self.radius = radius
        self.badge = badge
        self.content = content
    }

    /// A handoff is taken in the same reconcile pass; an old one is never used.
    var isFresh: Bool { Date().timeIntervalSince(created) < 0.5 }
}
