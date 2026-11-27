import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.5 toasts.

/// The away-note capsule without a badge, 3 s (hover pauses): "Timers restored"; the call-pause
/// toast "Breaks paused: microphone is on" with Resume (tertiary). × on hover.
public struct ToastView: View {
    private let toast: ToastContent
    private let hovering: Bool
    private let timeRim: TimeRimSource?
    private let onAction: () -> Void
    private let onClose: (() -> Void)?

    public init(toast: ToastContent, hovering: Bool = false, timeRim: TimeRimSource? = nil,
                onAction: @escaping () -> Void, onClose: (() -> Void)? = nil) {
        self.toast = toast
        self.hovering = hovering
        self.timeRim = timeRim
        self.onAction = onAction
        self.onClose = onClose
    }

    public var body: some View {
        if let hint = toast.hint {
            // The first call pause (SPEC §3.12): the capsule's line, then the hint, on one glass
            // card of the capsule's radius so the two read as one surface.
            GlassCard(radius: Theme.Layout.capsuleHeight / 2,
                      padding: EdgeInsets(top: 8, leading: 18, bottom: 12, trailing: 8)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(toast.text)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.white(.body))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if toast.action == .resumeFromCall {
                            PillButton("Resume", role: .tertiary, size: .small, action: onAction)
                        }
                    }
                    HintLine(hint)
                        .padding(.trailing, 10)
                }
            }
            .fixedSize()
            .timeRim(timeRim, cornerRadius: Theme.Layout.capsuleHeight / 2)
            .cornerCloseButton(visible: hovering, action: onClose)
            .accessibilityElement(children: .contain)
        } else {
            ToastShell(text: toast.text, actionTitle: toast.action == .resumeFromCall ? "Resume" : nil, action: onAction)
                .capsuleTimeRim(timeRim)
                .cornerCloseButton(visible: hovering, action: onClose)
        }
    }
}
