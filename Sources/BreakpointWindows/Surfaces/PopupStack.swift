import BreakpointCore
import BreakpointRuntime
import Foundation
import WinSDK

/// Positions every pop-up (SPEC §3.0), as `TransientPanelStack` does on macOS: on the display
/// under the pointer at the chosen position (top left, centre or right), the top edge 8 DIPs
/// below the top of the work area, side positions inset 16, stacked downward with 8 DIPs between,
/// at most 2 at once. When a third arrives, the lowest priority goes (`onEvicted`). The display is
/// chosen when the stack goes from empty to non-empty and kept while anything shows.
///
/// Order, top to bottom: highest priority first, then oldest first.
@MainActor
public final class PopupStack {
    struct Entry {
        let id: UUID
        let window: Window
        var size: SizeF
        let priority: PopupPriority
        let shownAt: Date
    }

    private let position: () -> PopupPosition
    private var entries: [Entry] = []
    private var monitor: Monitor?
    /// A pop-up was removed because a higher-priority one arrived.
    public var onEvicted: ((UUID) -> Void)?

    public init(position: @escaping () -> PopupPosition) {
        self.position = position
        SystemEvents.shared.on(UInt32(WM_DISPLAYCHANGE)) { [weak self] _, _ in
            self?.relayout(rechoose: true)
            return nil
        }
    }

    public var ids: [UUID] { ordered.map(\.id) }

    private var ordered: [Entry] {
        entries.sorted { a, b in a.priority != b.priority ? a.priority > b.priority : a.shownAt < b.shownAt }
    }

    /// Shows `window` for `id` (replacing the window already shown for it) at `size`.
    public func present(_ window: Window, id: UUID, size: SizeF, priority: PopupPriority) {
        if entries.isEmpty || monitor == nil { monitor = Monitors.underPointer() }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].size = size
        } else {
            entries.append(Entry(id: id, window: window, size: size, priority: priority, shownAt: Date()))
            // Over the limit: the lowest priority goes (the newest of equals), even the newcomer.
            while entries.count > Theme.Size.popupMaxStack, let lowest = ordered.last {
                remove(lowest.id)
                onEvicted?(lowest.id)
            }
        }
        layout()
        if entries.contains(where: { $0.id == id }) { window.show(activate: false) }
    }

    /// The pop-up for `id` changed size.
    public func resize(_ id: UUID, to size: SizeF) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].size != size else { return }
        entries[index].size = size
        layout()
    }

    public func dismiss(_ id: UUID) {
        remove(id)
        layout()
    }

    public func dismissAll() {
        for entry in entries { entry.window.hide() }
        entries.removeAll()
        monitor = nil
    }

    public func relayout(rechoose: Bool = false) {
        if rechoose || monitor == nil || !Monitors.all().contains(where: { $0 == monitor! }) { monitor = Monitors.underPointer() }
        layout()
    }

    /// Where pop-ups go now (or would go): the kept display, or the one under the pointer.
    public var currentMonitor: Monitor? { monitor ?? Monitors.underPointer() }

    /// The frame (DIPs of `currentMonitor`) of the pop-up for `id`.
    public func frame(of id: UUID) -> RectF? { frames()[id] }

    private func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].window.hide()
        entries.remove(at: index)
        if entries.isEmpty { monitor = nil }
    }

    private func frames() -> [UUID: RectF] {
        guard let monitor = monitor ?? Monitors.underPointer() else { return [:] }
        let area = monitor.workAreaDIPs
        var y = area.y + Theme.Size.popupTopGap
        var result: [UUID: RectF] = [:]
        for entry in ordered {
            let x: Float
            switch position() {
            case .topLeft: x = area.x + Theme.Size.popupSideInset
            case .topCentre: x = area.midX - entry.size.width / 2
            case .topRight: x = area.maxX - Theme.Size.popupSideInset - entry.size.width
            }
            result[entry.id] = RectF(x: x, y: y, width: entry.size.width, height: entry.size.height)
            y += entry.size.height + Theme.Size.popupStackGap
        }
        return result
    }

    private func layout() {
        guard let monitor else { return }
        for (id, frame) in frames() {
            entries.first { $0.id == id }?.window.place(frame, on: monitor)
        }
    }
}
