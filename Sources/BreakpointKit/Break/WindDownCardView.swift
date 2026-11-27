import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.6.

/// Keyboard and key-window state the wind-down controller shares with its view. The card becomes
/// key only after the user clicks into it; from then on Return wraps up (or copies the note), Esc
/// closes the note, ⌘C copies it, and holding Space holds "15 more minutes".
@MainActor
public final class WindDownKeyboard: ObservableObject {
    @Published public var isKey = false
    @Published public var spaceHeld = false
    nonisolated public init() {}
}

/// 410 pt wide, radius 28, padding 20. Title rounded semibold 17 "It's 23:20."; body 13 pt 85%
/// "You planned to stop at 23:00."; right-aligned 28 pt buttons: 15 more minutes (secondary, hold
/// 3 / 6 / 10 s with a linear 20% mint fill) · Wrap up (mint primary, Return once key). Wrap up
/// grows (spring 0.45 / 0.85) into "Where you left off": monospaced 12 pt lines, Copy note (⌘C) ·
/// Done (Esc). No badge, so the primary is the colour moment.
///
/// `holdProgress` renders a hold in progress (snapshots), 0…1.
public struct WindDownCardView: View {
    private let card: WindDownCardContent
    private let actions: AppActions
    private let onDone: () -> Void
    private let holdProgress: Double?
    @ObservedObject private var keyboard: WindDownKeyboard
    @State private var copied = false
    private let traits = DesignTraits()

    public init(card: WindDownCardContent, actions: AppActions, onDone: @escaping () -> Void, holdProgress: Double? = nil,
                keyboard: WindDownKeyboard = WindDownKeyboard()) {
        self.card = card
        self.actions = actions
        self.onDone = onDone
        self.holdProgress = holdProgress
        self.keyboard = keyboard
    }

    public var body: some View {
        GlassCard(padding: Theme.Layout.windDownPadding) {
            ZStack(alignment: .topLeading) {
                switch card.phase {
                case .asking:
                    asking.transition(.opacity)
                case .note(let lines):
                    note(lines).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Theme.Layout.windDownWidth)
        .animation(traits.reduceMotion ? .easeInOut(duration: Theme.Motion.reduceMotionFade) : Theme.Motion.cardGrow,
                   value: isNote)
    }

    private var isNote: Bool {
        if case .note = card.phase { return true }
        return false
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.windDownTitle(now: card.now))
                .font(Theme.Typography.windDownTitle)
                .foregroundStyle(Theme.Colors.white(.title))
            Text(Copy.windDownBody(stopTime: card.stopTime, on: card.now))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.white(.body))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                HoldCapsule(title: "15 more minutes", hold: card.holdDuration, forcedProgress: holdProgress,
                            keyboardHeld: keyboard.spaceHeld) {
                    actions.windDownExtend()
                }
                PillButton("Wrap up", role: .mintPrimary, size: .small, showsKeycap: false) {
                    actions.windDownWrapUp()
                }
            }
            .padding(.top, Theme.Spacing.m)
        }
    }

    private func note(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Where you left off")
                .font(Theme.Typography.windDownTitle)
                .foregroundStyle(Theme.Colors.white(.title))
            VStack(alignment: .leading, spacing: 4) {
                if lines.isEmpty {
                    Text("No open agent sessions.")
                        .font(Theme.Typography.note)
                        .foregroundStyle(Theme.Colors.white(.secondary))
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(Theme.Typography.note)
                        .foregroundStyle(Theme.Colors.white(.body))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            .padding(.top, Theme.Spacing.s)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                PillButton("Done", role: .secondary, size: .small, keycap: "esc", showsKeycap: keyboard.isKey, action: onDone)
                PillButton(copied ? "Copied" : "Copy note", systemImage: copied ? "checkmark" : nil, role: .mintPrimary,
                           size: .small) {
                    copy()
                }
            }
            .padding(.top, Theme.Spacing.m)
        }
    }

    private func copy() {
        actions.copyWrapUpNote()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }
}

/// "15 more minutes" as a press-and-hold capsule (SPEC §3.6): the 28 pt secondary capsule of
/// `PillButton`, labelled with its hold ("Hold 3 s"); while held a 20% mint fill sweeps left to
/// right at linear speed over the hold; releasing early springs it back over 0.3 s and does
/// nothing. A hold of 0 s acts on click. VoiceOver's activate acts at once (a hold cannot be
/// performed there). Space held while the card is key does the same as the pointer.
struct HoldCapsule: View {
    let title: String
    let hold: TimeInterval
    let forcedProgress: Double?
    let keyboardHeld: Bool
    let action: () -> Void

    @State private var pressing = false
    @State private var fill: Double = 0
    @State private var token = UUID()
    @State private var hovering = false
    private let traits = DesignTraits()

    var body: some View {
        let shape = Capsule(style: .circular)
        HStack(spacing: 6) {
            Text(title)
            if hold > 0 {
                Text(Copy.windDownHold(hold))
                    .font(Theme.Typography.hint)
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
            }
        }
        .font(Theme.Typography.smallButton)
        .foregroundStyle(Theme.Colors.white(.label))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: Theme.Layout.smallButtonHeight)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    shape.fill(Color.white.opacity(hovering ? 0.06 : 0))
                    Rectangle()
                        .fill(Theme.Colors.mint.opacity(0.20))
                        .frame(width: proxy.size.width * (forcedProgress ?? fill))
                }
                .clipShape(shape)
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(traits.outlineOpacity), lineWidth: 1))
        .contentShape(shape)
        .scaleEffect(pressing && !traits.reduceMotion ? 0.97 : 1)
        .animation(Theme.Motion.press, value: pressing)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in begin() }
                .onEnded { _ in end() })
        .onChange(of: keyboardHeld) { _, held in held ? begin() : end() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(hold > 0 ? "Press and hold for \(Int(hold)) seconds" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private func begin() {
        guard !pressing else { return }
        pressing = true
        guard hold > 0 else { return }
        let current = UUID()
        token = current
        // A release always springs the fill back to empty, so every hold is a full hold.
        withAnimation(.linear(duration: hold)) { fill = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold + 0.02) {
            guard token == current, pressing else { return }
            pressing = false
            action()
        }
    }

    private func end() {
        guard pressing else { return }
        pressing = false
        token = UUID()
        if hold <= 0 {
            action()
            return
        }
        withAnimation(traits.reduceMotion ? .easeOut(duration: Theme.Motion.reduceMotionFade)
                      : Theme.Motion.animation(.windDownRelease, reduceMotion: false)) {
            fill = 0
        }
    }
}
