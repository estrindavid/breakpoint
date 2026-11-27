import SwiftUI
import BreakpointRuntime

/// Settings building blocks (SPEC §3.9). Windows follow the system appearance, so these use
/// system label colours and native controls; only the accent is Breakpoint's.

/// A 13 pt bold section title above an inset grouped section, with 24 pt between sections.
public struct SectionHeader: View {
    private let title: String
    private let detail: String?

    public init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.Typography.sectionTitle)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(Theme.Typography.rowDescription).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// An inset grouped section: optional header, then rows on a rounded card. Put a
/// `SettingsDivider()` between rows.
public struct SettingsSection<Content: View>: View {
    private let title: String?
    private let content: Content
    @Environment(\.colorScheme) private var scheme

    public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionHeader(title) }
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.settingsSection, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035)))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.settingsSection, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07), lineWidth: 1))
        }
    }
}

/// The separator between rows of a `SettingsSection`.
public struct SettingsDivider: View {
    public init() {}
    public var body: some View { Divider().opacity(0.6) }
}

/// A toggle-style row (SPEC §3.9): 24 pt grey circular icon, 13 pt title, 11 pt description
/// saying *what will happen*, optional Options… button, and a trailing control (usually a
/// `Toggle` with `.toggleStyle(.switch)`). Rows are at least 40 pt tall.
public struct SettingRow<Trailing: View>: View {
    private let title: String
    private let description: String?
    private let systemImage: String?
    private let optionsAction: (() -> Void)?
    private let trailing: Trailing

    public init(_ title: String, description: String? = nil, systemImage: String? = nil,
                options: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.optionsAction = options
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: Theme.Layout.settingRowIcon, height: Theme.Layout.settingRowIcon)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typography.row)
                if let description {
                    Text(description)
                        .font(Theme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let optionsAction {
                Button("Options…", action: optionsAction).controlSize(.small)
            }
            trailing
        }
        .padding(.vertical, 8)
        .frame(minHeight: Theme.Layout.settingRowMinHeight)
        .accessibilityElement(children: .contain)
    }
}

extension SettingRow where Trailing == EmptyView {
    public init(_ title: String, description: String? = nil, systemImage: String? = nil) {
        self.init(title, description: description, systemImage: systemImage, options: nil) { EmptyView() }
    }
}

/// A sentence row (SPEC §3.9): the control sits inside the sentence, e.g.
/// "Offer an eye rest after [20 ⌄] min of screen time". Build it from text and controls in order.
public struct SentenceRow<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: 6) {
            content
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.row)
        .padding(.vertical, 8)
        .frame(minHeight: Theme.Layout.settingRowMinHeight)
        .accessibilityElement(children: .contain)
    }
}

/// A sidebar icon tile (SPEC §3.9): 20 pt rounded square, radius 5, white glyph, fill from the
/// mint → teal → indigo ramp by position.
public struct SidebarTile: View {
    private let systemImage: String
    private let index: Int

    public init(systemImage: String, index: Int) {
        self.systemImage = systemImage
        self.index = index
    }

    public var body: some View {
        let ramp = Theme.Colors.sidebarRamp
        RoundedRectangle(cornerRadius: Theme.Radius.sidebarTile, style: .continuous)
            .fill(ramp[min(max(index, 0), ramp.count - 1)].gradient)
            .frame(width: Theme.Layout.sidebarTile, height: Theme.Layout.sidebarTile)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// The shell of a preset card (SPEC §3.9 "show, don't tell"): title, detail line, a content slot
/// for the mini timeline, and selection shown with a checkmark **and** the accent border.
public struct PresetCard<Content: View>: View {
    private let title: String
    private let detail: String
    private let isSelected: Bool
    private let action: () -> Void
    private let content: Content
    @Environment(\.colorScheme) private var scheme

    public init(title: String, detail: String, isSelected: Bool, action: @escaping () -> Void,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                content
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 64)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Theme.Typography.bodySemibold).foregroundStyle(.primary)
                        Text(detail).font(Theme.Typography.rowDescription).foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.9)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary.opacity(0.6)))
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.05) : Color.white))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? accent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PointerResponseStyle(RoundedRectangle(cornerRadius: 12, style: .continuous)))
        .accessibilityLabel("\(title), \(detail.replacingOccurrences(of: "\n", with: ", "))")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accent: Color { Theme.Colors.accent(for: scheme) }
}
