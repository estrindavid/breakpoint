import SwiftUI
import BreakpointCore

// SPEC §3.10 step 3, §4.6.

/// ✓ "Connected" on the Connect step: a mint pill. When the install has just been verified, the ✓
/// hops 4 pt once and the pill flashes mint (0.4 s). Under Reduce Motion the ✓ stays put and the
/// flash is a 0.2 s fade. Reopening the step later shows it at rest.
public struct ConnectedPill: View {
    /// When the install check passed; the hop plays only if that was a moment ago.
    let connectedAt: Date?
    /// Snapshots: draw the movement frozen at this progress (0…1) instead of playing it.
    var frozenProgress: Double?

    public init(connectedAt: Date?, frozenProgress: Double? = nil) {
        self.connectedAt = connectedAt
        self.frozenProgress = frozenProgress
    }

    @State private var hopStart: Date?
    @Environment(\.colorScheme) private var scheme
    private let traits = DesignTraits()

    /// A check older than this is not "just connected": no hop when the step is reopened.
    static let freshness: TimeInterval = 3

    public var body: some View {
        if let frozenProgress {
            pill(progress: frozenProgress)
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: hopStart == nil)) { context in
                pill(progress: hopStart.map { context.date.timeIntervalSince($0) / Theme.Motion.connectedHopDuration } ?? 1)
            }
            .onAppear(perform: startIfFresh)
            .onChange(of: connectedAt) { _, _ in startIfFresh() }
        }
    }

    private func startIfFresh() {
        guard let connectedAt, Date().timeIntervalSince(connectedAt) < Self.freshness,
              traits.runsContinuousAnimations || traits.reduceMotion
        else { return }
        hopStart = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.connectedHopDuration + 0.05) { hopStart = nil }
    }

    private func pill(progress: Double) -> some View {
        let t = min(1, max(0, progress))
        let elapsed = t * Theme.Motion.connectedHopDuration
        let flashLength = traits.reduceMotion ? Theme.Motion.reduceMotionFade : Theme.Motion.connectedFlashDuration
        let flash = max(0, 1 - elapsed / flashLength)
        let accent = Theme.Colors.accent(for: scheme)
        return HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
                .offset(y: traits.reduceMotion ? 0 : CGFloat(MarkMotion.hopOffset(progress: t)))
            Text("Connected")
                .font(Theme.Typography.bodySemibold)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Layout.smallButtonHeight)
        .background(Capsule(style: .circular).fill(accent.opacity(0.12 + 0.22 * flash)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connected")
    }
}
