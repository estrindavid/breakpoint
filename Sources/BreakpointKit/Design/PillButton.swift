import SwiftUI

/// Capsule buttons (SPEC §3.0, §3.3, §4.4). Every control is a capsule.
///
/// Roles, on dark glass:
/// - `primary`: 10% white fill (pop-up primary; overlay Skip uses it too).
/// - `secondary`: 1 pt outline at 14% white (30% with Increase Contrast).
/// - `tertiary`: text only at 75%.
/// - `mintPrimary`: mint fill, `#04140F` label (overlay primary, wind-down primary).
///
/// On light windows (system appearance light) the same roles use black-based fills and the
/// light-mode mint, so onboarding can use them too.
///
/// Sizes: `.regular` 34 pt / 15 pt semibold; `.small` 28 pt / 13 pt semibold. Under the pointer
/// (`PointerLight.swift`): hover +6% fill, a light that follows the pointer, the rim catching it
/// and a 1 pt lift; pressed scale 0.97 on a spring (none under Reduce Motion); keyboard focus ring
/// 2 pt mint at 60%, growing in.
/// Optional keycap hint (`keycap:`), shown when `showsKeycap` is true. `keycapQuiet` draws it
/// faint without changing the button's size, so a hint can come forward (the nudge, on hover)
/// while the button stays exactly where it is under the pointer. Optional guard ring (`guardProgress:` 0…1): a 14 pt ring inside the leading edge that
/// fills while the button is disabled (overlay Skip guard, §3.3).
public struct PillButton: View {
    public enum Role: Sendable, CaseIterable {
        case primary, secondary, tertiary, mintPrimary
    }

    public enum Size: Sendable, CaseIterable {
        case regular, small

        public var height: CGFloat {
            self == .regular ? Theme.Layout.buttonHeight : Theme.Layout.smallButtonHeight
        }
        public var font: Font { self == .regular ? Theme.Typography.button : Theme.Typography.smallButton }
        public var horizontalPadding: CGFloat { self == .regular ? Theme.Layout.buttonPadding : 12 }
    }

    private let title: String
    private let systemImage: String?
    private let role: Role
    private let size: Size
    private let keycap: String?
    private let showsKeycap: Bool
    private let keycapQuiet: Bool
    private let guardProgress: Double?
    private let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, role: Role = .primary, size: Size = .regular,
                keycap: String? = nil, showsKeycap: Bool = true, keycapQuiet: Bool = false,
                guardProgress: Double? = nil,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.size = size
        self.keycap = keycap
        self.showsKeycap = showsKeycap
        self.keycapQuiet = keycapQuiet
        self.guardProgress = guardProgress
        self.action = action
    }

    /// A resting keycap: present, so nothing moves when it comes forward, but out of the way.
    static let quietKeycapOpacity = 0.4

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let guardProgress {
                    ProgressRing(progress: guardProgress, lineWidth: 2, tint: .white.opacity(0.75),
                                 track: .white.opacity(0.2))
                        .frame(width: Theme.Layout.skipGuardRing, height: Theme.Layout.skipGuardRing)
                }
                if let systemImage {
                    Image(systemName: systemImage).imageScale(.small)
                }
                Text(title).lineLimit(1)
                if let keycap, showsKeycap {
                    Keycap(keycap, compact: true)
                        .opacity(keycapQuiet ? Self.quietKeycapOpacity : 1)
                        .animation(DesignTraits().animation(.subtitleSwap), value: keycapQuiet)
                }
            }
        }
        .buttonStyle(PillButtonStyle(role: role, size: size))
        .modifier(KeyedControlResponse(key: title))
        .accessibilityLabel(title)
    }
}

/// The capsule style behind `PillButton`; usable directly on any `Button` or `Menu` label.
public struct PillButtonStyle: ButtonStyle {
    public var role: PillButton.Role
    public var size: PillButton.Size

    public init(role: PillButton.Role = .primary, size: PillButton.Size = .regular) {
        self.role = role
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, role: role, size: size)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let role: PillButton.Role
    let size: PillButton.Size

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var systemFocused
    @Environment(\.pillButtonFocused) private var forcedFocus
    @Environment(\.controlResponsePreview) private var preview
    @State private var hovering = false
    @State private var location = UnitPoint.center
    private let traits = DesignTraits()

    var body: some View {
        let response = self.response
        let reduceMotion = traits.reduceMotion
        // The lift: up 1 pt on hover, back down as it presses in.
        let lift = reduceMotion || role == .tertiary ? 0 : response.hover * (1 - response.press)
        let shape = Capsule(style: .circular)
        configuration.label
            .environment(\.controlIsPressed, response.press > 0.5)
            .font(size.font)
            .foregroundStyle(labelColor)
            .padding(.horizontal, role == .tertiary ? 6 : size.horizontalPadding)
            .frame(height: size.height)
            .frame(minWidth: role == .tertiary ? 0 : size.height)
            // Circular, not continuous: in a real window AppKit draws a continuous capsule's ends
            // with a short straight segment where they meet the frame (visible as flat ends on the
            // outline); a capsule's ends are true half circles. `BreakpointSnapshots
            // --window-probe DIR` measures this in a real window.
            .background {
                ZStack {
                    shape.fill(fill(hover: response.hover))
                    // Light above the fill, below the label: it never washes out the text.
                    PointerLight(response, in: shape, tone: tone, increaseContrast: traits.increaseContrast)
                }
            }
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .background(ContactShadow(shape: shape, lift: lift, dark: dark))
            .overlay(
                shape
                    .strokeBorder(Theme.Colors.accent(for: scheme).opacity(0.6), lineWidth: 2)
                    // The ring grows out from the rim as it fades in (still under Reduce Motion).
                    .padding(reduceMotion ? -3 : -1 - 2 * response.focus)
                    .opacity(response.focus))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(reduceMotion ? 1 : 1 - (1 - Theme.Motion.pressScale) * response.press)
            .offset(y: -Theme.Motion.hoverLift * lift)
            .animation(Theme.Motion.pressAnimation(configuration.isPressed, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
            .animation(reduceMotion ? Theme.Motion.controlFade : Theme.Motion.focusRing, value: isFocused)
            .modifier(PointerTracking(hovering: $hovering, location: $location, reduceMotion: reduceMotion))
    }

    /// The live state, or the one a snapshot or film forces.
    private var response: ControlResponse {
        var response: ControlResponse
        if let preview {
            response = preview
            if !isEnabled { response.hover = 0; response.press = 0 }
            if let forcedFocus { response.focus = forcedFocus ? 1 : 0 }
        } else {
            response = ControlResponse(hover: hovering && isEnabled ? 1 : 0,
                                       press: configuration.isPressed && isEnabled ? 1 : 0,
                                       location: location, focus: isFocused ? 1 : 0)
        }
        // Reduce Motion: the light never travels; it sits at the top edge.
        if traits.reduceMotion { response.location = Theme.Motion.stillLightLocation }
        return response
    }

    private var isFocused: Bool { forcedFocus ?? systemFocused }
    private var dark: Bool { scheme == .dark }
    private var base: Color { dark ? .white : .black }

    private var tone: PointerLightTone {
        switch role {
        case .mintPrimary: return .mint
        case .tertiary: return .quiet
        case .primary, .secondary: return dark ? .glass : .window
        }
    }

    private var labelColor: Color {
        switch role {
        case .mintPrimary: return dark ? Theme.Colors.onMint : .white
        case .primary, .secondary, .tertiary:
            return dark ? Theme.Colors.white(.label) : Color.primary.opacity(0.85)
        }
    }

    /// The fill, with `hover` 0 … 1 adding the +6% (it animates with the light).
    private func fill(hover: Double) -> Color {
        let lift = 0.06 * hover
        switch role {
        case .primary: return base.opacity((dark ? 0.10 : 0.07) + lift)
        case .secondary: return base.opacity(lift)
        case .tertiary: return base.opacity(lift * 0.5)
        case .mintPrimary:
            // Mint stays solid; the light brightens it.
            return dark ? Theme.Colors.mint : Theme.Colors.mintLight
        }
    }

    private var stroke: Color {
        switch role {
        case .secondary: return base.opacity(traits.increaseContrast ? 0.30 : (dark ? 0.14 : 0.16))
        case .primary: return traits.increaseContrast ? base.opacity(0.30) : base.opacity(dark ? 0.06 : 0.04)
        case .tertiary, .mintPrimary: return .clear
        }
    }
}

private struct PillButtonFocusedKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Forces the keyboard focus ring of `PillButton`s in this subtree on (`true`) or off
    /// (`false`); `nil` follows SwiftUI focus. For surfaces that run their own keyboard focus
    /// model, such as the break overlay (which handles Tab and arrow keys itself, SPEC §3.3).
    public var pillButtonFocused: Bool? {
        get { self[PillButtonFocusedKey.self] }
        set { self[PillButtonFocusedKey.self] = newValue }
    }
}
