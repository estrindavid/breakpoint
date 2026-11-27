import SwiftUI
import BreakpointCore

/// The single-line glass capsule used by the away note and toasts (SPEC §3.5): 44 pt high,
/// optional 32 pt kind badge inset 6 pt (concentric with the capsule), 13 pt text, optional
/// tertiary action button (28 pt).
///
/// - Away note: `ToastShell(text: "Counted your 6 min away as a break", badge: .move, actionTitle: "Undo")`.
/// - Toast: `ToastShell(text: "Timers restored")`.
public struct ToastShell: View {
    private let text: String
    private let badge: BreakKind?
    private let actionTitle: String?
    private let action: () -> Void

    public init(text: String, badge: BreakKind? = nil, actionTitle: String? = nil, action: @escaping () -> Void = {}) {
        self.text = text
        self.badge = badge
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        GlassCapsule(leadingInset: badge == nil ? 18 : Theme.Layout.capsuleBadgeInset,
                     trailingInset: actionTitle == nil ? 18 : 8) {
            HStack(spacing: 10) {
                if let badge {
                    KindBadge(kind: badge, diameter: Theme.Layout.capsuleBadge)
                }
                Text(text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.white(.body))
                    .lineLimit(1)
                if let actionTitle {
                    PillButton(actionTitle, role: .tertiary, size: .small, action: action)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}
