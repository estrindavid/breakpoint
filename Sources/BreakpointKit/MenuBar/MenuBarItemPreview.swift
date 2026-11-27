import AppKit
import SwiftUI
import BreakpointCore
import BreakpointRuntime

// A faithful drawing of the status item, built from
// the exact template image the real `NSStatusItem` shows, for snapshots, the General pane's live
// preview and onboarding.

/// How the menu bar behind the item looks.
public enum MenuBarBackdrop: String, CaseIterable, Sendable {
    /// Light menu bar (light mode or a light wallpaper).
    case light
    /// Dark menu bar.
    case dark
    /// A light menu bar tinted by a colourful wallpaper.
    case tinted
}

/// The status item as macOS draws it: the template mark (and badge) plus optional text, in the
/// menu bar's label colour.
public struct MenuBarItemView: View {
    private let menuBar: MenuBarState
    private let badgeOpacity: Double
    private let foreground: Color
    private let pose: MarkPose

    /// `pose`: one moment of a mark movement (§3.7), for snapshots of the movements.
    public init(menuBar: MenuBarState, badgeOpacity: Double = 1, foreground: Color = .primary, pose: MarkPose = .rest) {
        self.menuBar = menuBar
        self.badgeOpacity = badgeOpacity
        self.foreground = foreground
        self.pose = pose
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: BrandMark.templateImage(menuBar.mark.variant, badge: menuBar.badge, badgeOpacity: badgeOpacity,
                                                   pose: pose))
                .renderingMode(.template)
            if let text = menuBar.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: NSFont.menuBarFont(ofSize: 0).pointSize))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .foregroundStyle(foreground)
        .frame(height: 22)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StatusItemController.accessibilityLabel(menuBar))
    }
}

/// A strip of menu bar with the item on it, in a given appearance (snapshots and settings).
public struct MenuBarStripPreview: View {
    private let items: [MenuBarState]
    private let poses: [MarkPose]
    private let backdrop: MenuBarBackdrop
    private let highlighted: Bool
    private let traits = DesignTraits()

    /// `poses`: one per item, for strips of a mark movement's key frames (default: all at rest).
    public init(_ items: [MenuBarState], poses: [MarkPose] = [], backdrop: MenuBarBackdrop, highlighted: Bool = false) {
        self.items = items
        self.poses = poses
        self.backdrop = backdrop
        self.highlighted = highlighted
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                MenuBarItemView(menuBar: item, foreground: foreground, pose: poses.indices.contains(index) ? poses[index] : .rest)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(foreground.opacity(highlighted ? 0.16 : 0)))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(bar)
    }

    private var foreground: Color {
        let dark = backdrop == .dark
        if traits.increaseContrast { return dark ? .white : .black }
        return dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
    }

    @ViewBuilder private var bar: some View {
        switch backdrop {
        case .light:
            Rectangle().fill(traits.reduceTransparency ? Color(hex: 0xEDEDED) : Color(hex: 0xF4F4F6).opacity(0.92))
        case .dark:
            Rectangle().fill(traits.reduceTransparency ? Color(hex: 0x262626) : Color(hex: 0x1F2024).opacity(0.92))
        case .tinted:
            if traits.reduceTransparency {
                Rectangle().fill(Color(hex: 0xEDEDED))
            } else {
                LinearGradient(colors: [Color(hex: 0xF6DCC8), Color(hex: 0xD8E2F6)], startPoint: .leading, endPoint: .trailing)
                    .opacity(0.95)
            }
        }
    }
}
