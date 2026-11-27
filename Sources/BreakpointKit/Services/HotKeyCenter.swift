import AppKit
import Carbon.HIToolbox
import BreakpointCore
import BreakpointRuntime

/// A registered global hotkey; pass it back to `unregister`.
public struct HotKeyToken: Hashable, Sendable {
    public let id: UInt32
    public init(id: UInt32) { self.id = id }
}

/// Global hotkeys via Carbon `RegisterEventHotKey` (no permission prompt) (SPEC §3.1, §3.5, §7.2).
///
/// Contract:
/// - `register` installs the app's hot-key event handler on first use and returns a token, or
///   `nil` if the combination is taken by another app. `handler` runs on the main thread.
/// - Several surfaces may register the same combination (the nudge's ⌃⌥⌘. and the resume card's
///   dismiss): the system hotkey is registered once, and a press runs only the handler with the
///   highest `priority` (the latest registered among equals). Unregistering hands the key back to
///   the next one; the system hotkey goes when the last one does.
/// - `unregister` removes one registration; `unregisterAll` removes every hotkey (on quit).
/// - Surfaces register only while visible (the nudge registers ⌃⌥⌘B / ⌃⌥⌘. while it shows).
@MainActor
public final class HotKeyCenter {
    private struct Registration {
        let combo: HotKeyCombo
        let priority: Int
        let handler: () -> Void
    }

    /// Four-character signature for Breakpoint's hotkeys ("BkPt").
    private static let signature: OSType = 0x426B_5074
    /// Every registration by token id (ids grow, so a larger id is a later registration).
    private var registrations: [UInt32: Registration] = [:]
    /// The system hotkey behind each combination, with the Carbon id its presses carry.
    private var systemKeys: [HotKeyCombo: (ref: EventHotKeyRef, carbonID: UInt32)] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    public init() {}

    public func register(_ combo: HotKeyCombo, priority: Int = 0, handler: @escaping () -> Void) -> HotKeyToken? {
        guard installHandlerIfNeeded() else { return nil }
        let id = nextID
        nextID &+= 1
        if systemKeys[combo] == nil {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(),
                                             OptionBits(0), &ref)
            guard status == noErr, let ref else { return nil }
            systemKeys[combo] = (ref, id)
        }
        registrations[id] = Registration(combo: combo, priority: priority, handler: handler)
        return HotKeyToken(id: id)
    }

    public func unregister(_ token: HotKeyToken) {
        guard let registration = registrations.removeValue(forKey: token.id) else { return }
        let combo = registration.combo
        if !registrations.values.contains(where: { $0.combo == combo }), let key = systemKeys.removeValue(forKey: combo) {
            UnregisterEventHotKey(key.ref)
        }
    }

    public func unregisterAll() {
        for key in systemKeys.values { UnregisterEventHotKey(key.ref) }
        systemKeys.removeAll()
        registrations.removeAll()
    }

    /// Number of registrations currently held (diagnostics and the demo).
    public var registeredCount: Int { registrations.count }

    fileprivate func fire(_ carbonID: UInt32) {
        guard let combo = systemKeys.first(where: { $0.value.carbonID == carbonID })?.key else { return }
        let winner = registrations
            .filter { $0.value.combo == combo }
            .max { ($0.value.priority, $0.key) < ($1.value.priority, $1.key) }
        winner?.value.handler()
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, context, &handlerRef)
        return status == noErr
    }
}

/// Carbon calls this on the main thread (the application event target dispatches there).
private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
    if Thread.isMainThread {
        MainActor.assumeIsolated { center.fire(id) }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { center.fire(id) } }
    }
    return noErr
}
