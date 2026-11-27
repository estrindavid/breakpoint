import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// The popover shortcut recorder (SPEC §3.9
// General). Listens only to key presses sent to this window (a local monitor, no permission).

struct ShortcutRecorder: View {
    @Binding var combo: HotKeyCombo?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                HStack(spacing: 4) {
                    if recording {
                        Text(hint ?? "Type a shortcut…").foregroundStyle(.secondary)
                    } else if let combo {
                        Text(combo.display).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    } else {
                        Text("Record Shortcut")
                    }
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(recording ? "Recording; type a shortcut, or Escape to cancel"
                                : (combo.map { "Shortcut \($0.display). Change" } ?? "Record shortcut"))
            if combo != nil, !recording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { handle(event) }
            return used ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    /// Returns true when the key press was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        if event.keyCode == 53 { stop(); return true }                  // Esc cancels
        if event.keyCode == 51 || event.keyCode == 117 {                // Delete clears
            combo = nil
            stop()
            return true
        }
        guard let recorded = Self.combo(from: event) else {
            hint = "Add ⌘, ⌃ or ⌥"
            return true
        }
        // The nudge owns these two while it shows; the popover shortcut would fight it.
        let reserved = [HotKeyCombo.nudgeStart, HotKeyCombo.nudgeDismiss]
        if reserved.contains(where: { $0.keyCode == recorded.keyCode && $0.carbonModifiers == recorded.carbonModifiers }) {
            hint = "\(recorded.display) is used by the nudge"
            return true
        }
        combo = recorded
        stop()
        return true
    }

    /// A combination from a key press, if it has ⌘, ⌃ or ⌥.
    static func combo(from event: NSEvent) -> HotKeyCombo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var display = ""
        if flags.contains(.control) { carbon |= HotKeyCombo.controlKey; display += "⌃" }
        if flags.contains(.option) { carbon |= HotKeyCombo.optionKey; display += "⌥" }
        if flags.contains(.shift) { carbon |= HotKeyCombo.shiftKey; display += "⇧" }
        if flags.contains(.command) { carbon |= HotKeyCombo.cmdKey; display += "⌘" }
        display += keyName(event)
        return HotKeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, display: display)
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}
