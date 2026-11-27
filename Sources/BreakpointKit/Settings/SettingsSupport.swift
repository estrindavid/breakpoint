import AppKit
import SwiftUI
import BreakpointCore

// Small building blocks shared by the settings
// panes and onboarding, assembled from the design system (`SettingsSection`, `SettingRow`,
// `SentenceRow`, `PresetCard`). Everything writes through `AppActions.updateSettings`, so changes
// apply immediately and there is no Save button.

/// A binding to one settings value that writes through `AppActions.updateSettings`.
@MainActor
func settingBinding<Value>(_ state: AppState, _ actions: AppActions,
                           _ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
    Binding(get: { state.settings[keyPath: keyPath] },
            set: { newValue in actions.updateSettings { $0[keyPath: keyPath] = newValue } })
}

/// The vertical rhythm of every pane: sections 24 pt apart, full width.
struct PaneStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.sectionGap) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A toggle row: grey icon, title, one-line description of what will happen, switch.
struct ToggleRow: View {
    let title: String
    let description: String
    let systemImage: String
    @Binding var isOn: Bool
    var options: (() -> Void)?
    var optionsDisabled = false

    var body: some View {
        SettingRow(title, description: description, systemImage: systemImage, options: nil) {
            HStack(spacing: 10) {
                if let options {
                    Button("Options…", action: options)
                        .controlSize(.small)
                        .disabled(optionsDisabled)
                }
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(description)
    }
}

/// A quiet line under a section (11 pt, secondary), aligned with the section's text.
struct SectionFootnote: View {
    let text: String
    var systemImage: String?

    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Typography.rowDescription)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, -16)
    }
}

/// A pop-up of whole minutes inside a sentence ("after [20 ⌄] min"). VoiceOver reads the whole
/// sentence as the control's label.
struct MinutePicker: View {
    let label: String
    let values: [Int]
    @Binding var value: Int

    var body: some View {
        Picker(label, selection: $value) {
            ForEach(Self.withCurrent(values, value), id: \.self) { minutes in
                Text("\(minutes)").monospacedDigit().tag(minutes)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel(label)
    }

    /// The choices, plus the current value if it is not one of them (e.g. a hand-edited file).
    static func withCurrent(_ values: [Int], _ current: Int) -> [Int] {
        values.contains(current) ? values : (values + [current]).sorted()
    }
}

/// Native bordered buttons sized for rows.
struct RowButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Group {
            if prominent {
                Button(action: action) { label }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { label }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var label: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

/// A round ▶ button that previews something (sounds, the routine).
struct PlayButton: View {
    let label: String
    var isPlaying = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Window with the key equivalents a menu-less app needs

/// Breakpoint has no main menu (it is a menu-bar app), so its windows handle the standard key
/// equivalents themselves: ⌘W closes, ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z edit text, and `keyHandler` gets the rest.
final class BreakpointWindow: NSWindow {
    /// Extra key handling (pane shortcuts, onboarding Return / Esc); return true when used.
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command || modifiers == [.command, .shift] {
            let editing: Selector?
            switch (event.charactersIgnoringModifiers?.lowercased(), modifiers.contains(.shift)) {
            case ("w", false): performClose(nil); return true
            case ("x", false): editing = #selector(NSText.cut(_:))
            case ("c", false): editing = #selector(NSText.copy(_:))
            case ("v", false): editing = #selector(NSText.paste(_:))
            case ("a", false): editing = #selector(NSText.selectAll(_:))
            case ("z", false): editing = Selector(("undo:"))
            case ("z", true): editing = Selector(("redo:"))
            default: editing = nil
            }
            if let editing, NSApp.sendAction(editing, to: nil, from: self) { return true }
        }
        if let keyHandler, keyHandler(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let keyHandler, keyHandler(event) { return }
        super.keyDown(with: event)
    }

    /// True while a text field is being edited (keys belong to it).
    var isEditingText: Bool { firstResponder is NSTextView }
}

/// Persists small window facts (frame, selected pane) in user defaults, except in development
/// runs with a temporary home, which must leave no trace outside it.
@MainActor
enum WindowMemory {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[BreakpointPaths.homeOverrideVariable] == nil
    }

    static func string(_ key: String) -> String? {
        isEnabled ? UserDefaults.standard.string(forKey: key) : nil
    }

    static func set(_ value: String, for key: String) {
        guard isEnabled else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}
