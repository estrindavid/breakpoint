import SwiftUI
import BreakpointCore

// SPEC §3.9 "show, don't tell": each preset card
// carries a mini timeline of a two-hour session with ticks where breaks would fall.

/// Where breaks would fall in `span` minutes of steady work at a cadence, following the engine's
/// rules: a due stretch wins over a due eye rest, a stretch resets both timers, an eye rest resets
/// screen time only.
struct BreakSchedule: Equatable {
    enum Mark: Equatable {
        case eyes(minute: Int)
        case move(minute: Int)

        var minute: Int {
            switch self {
            case .eyes(let m), .move(let m): return m
            }
        }
    }

    var marks: [Mark]

    init(cadence: Cadence, span: Int = 120) {
        var marks: [Mark] = []
        var screen = 0
        var still = 0
        for minute in 1...span {
            screen += 1
            still += 1
            if still >= cadence.moveEveryMinutes {
                marks.append(.move(minute: minute))
                screen = 0
                still = 0
            } else if screen >= cadence.eyesEveryMinutes {
                marks.append(.eyes(minute: minute))
                screen = 0
            }
        }
        self.marks = marks
    }

    var eyesCount: Int { marks.filter { if case .eyes = $0 { return true } else { return false } }.count }
    var moveCount: Int { marks.count - eyesCount }

    /// "4 eye rests and 2 stretches in 2 hours".
    var summary: String {
        let eyes = eyesCount == 1 ? "1 eye rest" : "\(eyesCount) eye rests"
        let moves = moveCount == 1 ? "1 stretch" : "\(moveCount) stretches"
        return "\(eyes) and \(moves) in 2 hours"
    }
}

/// The mini timeline: a two-hour track, short ticks for eye rests, tall capsules with a dot for
/// stretches (shape, not only colour), hour labels underneath.
public struct PresetTimeline: View {
    let cadence: Cadence
    var isSelected = false
    @Environment(\.colorScheme) private var scheme

    public init(cadence: Cadence, isSelected: Bool = false) {
        self.cadence = cadence
        self.isSelected = isSelected
    }

    public var body: some View {
        let schedule = BreakSchedule(cadence: cadence)
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                let mid = geo.size.height / 2
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: width, height: 4)
                        .offset(y: mid - 2)
                    ForEach(Array(schedule.marks.enumerated()), id: \.offset) { _, mark in
                        let x = width * CGFloat(mark.minute) / 120
                        switch mark {
                        case .eyes:
                            Capsule()
                                .fill(Color.primary.opacity(0.45))
                                .frame(width: 2, height: 10)
                                .offset(x: x - 1, y: mid - 5)
                        case .move:
                            Circle()
                                .fill(accent)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                                .offset(x: x - 4.5, y: mid - 4.5)
                        }
                    }
                }
            }
            .frame(height: 16)
            HStack {
                Text("0")
                Spacer()
                Text("1 h")
                Spacer()
                Text("2 h")
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(schedule.summary)
    }

    private var accent: Color { Theme.Colors.accent(for: scheme) }
}

/// "▏ eye rest  ● stretch" legend under the cards.
struct PresetTimelineLegend: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(Color.primary.opacity(0.45)).frame(width: 2, height: 10)
                Text("Eye rest")
            }
            HStack(spacing: 5) {
                Circle().fill(Theme.Colors.accent(for: scheme)).frame(width: 8, height: 8)
                Text("Stretch")
            }
            Text("Two hours of steady work")
                .foregroundStyle(.tertiary)
        }
        .font(Theme.Typography.rowDescription)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// The three preset cards (Settings → Breaks and onboarding's Pick your pace).
struct PresetCardRow: View {
    @ObservedObject var state: AppState
    let actions: AppActions

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CadencePreset.cards) { preset in
                let cadence = preset.cadence ?? state.settings.cadence
                PresetCard(title: preset.title,
                           detail: "Eye rest every \(cadence.eyesEveryMinutes) min\nStretch every \(cadence.moveEveryMinutes) min",
                           isSelected: state.settings.preset == preset,
                           action: { actions.updateSettings { $0.applyPreset(preset) } }) {
                    PresetTimeline(cadence: cadence, isSelected: state.settings.preset == preset)
                        .padding(.top, 6)
                }
                .accessibilityHint("Eye rest every \(cadence.eyesEveryMinutes) minutes, stretch every \(cadence.moveEveryMinutes) minutes")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
