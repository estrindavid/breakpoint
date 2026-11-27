import SwiftUI
import BreakpointCore
import BreakpointRuntime

// SPEC §3.9 Wind-down pane.

/// Remind me to stop, "Stop at [23:00] on [Every day ⌄]" with day chips, Ask for longer holds, and
/// a still of the card it shows.
public struct WindDownPane: View {
    @ObservedObject var state: AppState
    let actions: AppActions

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        let enabled = state.settings.windDownEnabled
        PaneStack {
            SettingsSection {
                ToggleRow(title: "Remind me to stop",
                          description: "After your stop time, the next finished agent run shows a wrap-up card.",
                          systemImage: "moon", isOn: settingBinding(state, actions, \.windDownEnabled))
            }

            SettingsSection("When") {
                SentenceRow {
                    Text("Stop at")
                    DatePicker("Stop time", selection: stopTimeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                        .fixedSize()
                    Text("on")
                    Menu {
                        Button("Every day") { setDays(.all) }
                        Button("Weekdays") { setDays(.weekdays) }
                        Button("Sunday to Thursday nights") {
                            setDays([.sunday, .monday, .tuesday, .wednesday, .thursday])
                        }
                    } label: {
                        Text(Self.daysSummary(state.settings.stopDays))
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .accessibilityLabel("Days: \(Self.daysSummary(state.settings.stopDays))")
                }
                SettingsDivider()
                HStack(spacing: 6) {
                    ForEach(Self.weekOrder, id: \.self) { weekday in
                        DayChip(weekday: weekday, isOn: state.settings.stopDays.contains(calendarWeekday: weekday)) {
                            toggle(weekday)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            SettingsSection("The card") {
                ToggleRow(title: "Ask for longer holds",
                          description: "Each extra 15 minutes needs a longer press: 3, 6, then 10 seconds.",
                          systemImage: "hand.tap", isOn: settingBinding(state, actions, \.escalatingHold))
                SettingsDivider()
                WindDownCardPreview(state: state)
                    .padding(.vertical, 12)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            SectionFootnote("Wrap up writes a short “Where you left off” note you can copy, and pauses breaks until morning.")
        }
    }

    // MARK: Time and days

    private var stopTimeBinding: Binding<Date> {
        Binding(get: {
            state.settings.stopTime.date(on: state.now)
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            actions.updateSettings { $0.stopTime = TimeOfDay(hour: parts.hour ?? 23, minute: parts.minute ?? 0) }
        })
    }

    private func setDays(_ days: Weekdays) {
        actions.updateSettings { $0.stopDays = days }
    }

    private func toggle(_ weekday: Int) {
        actions.updateSettings { settings in
            let day = Weekdays(calendarWeekday: weekday)
            if settings.stopDays.contains(day) {
                // Keep at least one day.
                if settings.stopDays.subtracting(day).isEmpty { return }
                settings.stopDays.remove(day)
            } else {
                settings.stopDays.insert(day)
            }
        }
    }

    /// Calendar weekday numbers in the user's week order (Monday first in most locales).
    static var weekOrder: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    /// "Every day", "Weekdays", "Weekends", or the days listed ("Mon, Tue, Thu").
    static func daysSummary(_ days: Weekdays) -> String {
        if days == .all { return "Every day" }
        if days == .weekdays { return "Weekdays" }
        if days == [.saturday, .sunday] { return "Weekends" }
        if days == [.sunday, .monday, .tuesday, .wednesday, .thursday] { return "Sunday to Thursday" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekOrder.filter { days.contains(calendarWeekday: $0) }.map { symbols[$0 - 1] }.joined(separator: ", ")
    }
}

/// A day toggle: filled with a white letter when on, outlined when off (shape, not only colour).
private struct DayChip: View {
    let weekday: Int
    let isOn: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(Calendar.current.veryShortWeekdaySymbols[weekday - 1])
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isOn ? Theme.Colors.onMint : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(isOn ? Theme.Colors.accent(for: scheme) : Color.clear))
                .overlay(Circle().strokeBorder(isOn ? Color.clear : Color.primary.opacity(0.25), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

/// A still of the real wind-down card as it would appear tonight.
private struct WindDownCardPreview: View {
    @ObservedObject var state: AppState

    var body: some View {
        let stop = state.settings.stopTime
        let at = Calendar.current.date(byAdding: .minute, value: 20, to: stop.date(on: state.now)) ?? state.now
        let card = WindDownCardContent(now: at, stopTime: stop, holdDuration: 3)
        HStack {
            Spacer(minLength: 0)
            WindDownCardView(card: card, actions: .noop, onDone: {})
                .fixedSize()
                .scaleEffect(0.8)
                .frame(width: Theme.Layout.windDownWidth * 0.8, height: 112)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2A3040), Color(hex: 0x141821)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
        .environment(\.colorScheme, .dark)
    }
}
