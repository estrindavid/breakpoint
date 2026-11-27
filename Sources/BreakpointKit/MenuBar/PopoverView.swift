import SwiftUI
import BreakpointCore

// SPEC §3.8.

/// The popover root: 320 pt wide, dark in both modes. Top to bottom: top bar with the gear menu;
/// status (44 pt still-time ring, caption, big rolling number, one detail line; paused: "until
/// 15:30" or nothing); actions (Take a break ▾ · Pause ▾, or Resume now); the decision line while
/// undoable; agents (≤ 4 rows, then "+N more"); all-time totals; a footer naming the connected tools.
public struct PopoverView: View {
    @ObservedObject private var state: AppState
    private let actions: AppActions
    @ObservedObject private var commands: PopoverCommands
    private let traits = DesignTraits()

    public init(state: AppState, actions: AppActions) {
        self.init(state: state, actions: actions, commands: PopoverCommands(state: state, actions: actions))
    }

    /// Snapshots: the popover with the keyboard focus ring on its `n`-th control (0 = primary).
    public init(state: AppState, actions: AppActions, previewFocusIndex: Int) {
        let commands = PopoverCommands(state: state, actions: actions)
        let items = commands.items()
        commands.focus = items.indices.contains(previewFocusIndex) ? items[previewFocusIndex] : nil
        self.init(state: state, actions: actions, commands: commands)
    }

    init(state: AppState, actions: AppActions, commands: PopoverCommands) {
        self.state = state
        self.actions = actions
        self.commands = commands
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            statusBlock
                .tourSpotlight(.status, tour: popoverTour)
                .padding(.top, Theme.Spacing.xs)
            actionRow
                .tourSpotlight(.actions, tour: popoverTour)
                .padding(.top, Theme.Spacing.m)
            if let decision = state.undoableDecision {
                decisionLine(decision)
                    .padding(.top, Theme.Spacing.s)
                    .transition(.opacity)
            }
            agentsSection
                .tourSpotlight(nil, tour: popoverTour)
                .padding(.top, Theme.Spacing.l)
            totalsSection
                .tourSpotlight(.totals, tour: popoverTour)
                .padding(.top, Theme.Spacing.m)
            footer
                .tourSpotlight(nil, tour: popoverTour)
                .padding(.top, Theme.Spacing.m)
            if let tour = popoverTour {
                TourPopoverStrip(tour: tour, actions: actions)
                    .padding(.top, Theme.Spacing.m)
                    .transition(.opacity)
            } else if let hint = state.popoverHint {
                // The first time the popover opens (SPEC §3.12).
                HintLine(hint)
                    .padding(.horizontal, 4)
                    .padding(.top, Theme.Spacing.s)
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.m)
        .frame(width: Theme.Layout.popoverWidth, alignment: .leading)
        .background(PopoverBackground())
        .coordinateSpace(name: PopoverAnchorKey.space)
        .onPreferenceChange(PopoverAnchorKey.self) { frames in
            MainActor.assumeIsolated { commands.anchorFrames = frames }
        }
        .environment(\.colorScheme, .dark)
        .animation(traits.animation(.popupOutAction), value: state.undoableDecision?.id)
        .animation(traits.animation(.subtitleSwap), value: popoverTour)
    }

    /// The tour, while it names the popover's parts (SPEC §3.12).
    private var popoverTour: TourPresentation? {
        state.tour.flatMap { $0.step == .popover ? $0 : nil }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            BrandMark(.brand)
                .foregroundStyle(Theme.Colors.white(.secondary))
                .frame(height: 10)
            Text("Breakpoint")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
            Spacer(minLength: 0)
            PopoverIconButton(systemImage: "gearshape", label: "Breakpoint menu", item: .gear, commands: commands)
                .tourSpotlight(.gear, tour: popoverTour)
        }
        .frame(height: 28)
        .accessibilityElement(children: .contain)
    }

    // MARK: Status

    private var statusBlock: some View {
        let status = PopoverModel.status(state)
        return HStack(alignment: .center, spacing: 14) {
            ProgressRing(progress: status.ringProgress, lineWidth: 4,
                         tint: Theme.Colors.mint, track: Theme.Colors.white(.outline)) {
                Image(systemName: status.ringSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
            }
            .frame(width: Theme.Layout.popoverRing, height: Theme.Layout.popoverRing)
            .opacity(status.ringDimmed ? 0.55 : 1)
            .accessibilityHidden(true) // the caption and detail line say it

            VStack(alignment: .leading, spacing: 0) {
                Text(status.caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let number = status.number {
                    bigValue(status, number: number)
                        .padding(.top, -1)
                }
                Text(status.detail)
                    .font(Theme.Typography.detail)
                    .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, status.number == nil ? 4 : 0)
                if let why = PopoverModel.whyNotNow(state) {
                    whyNotNowLine(why)
                        .padding(.top, Theme.Spacing.xxs)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }

    /// "Waiting for a pause: Claude is idle and you are typing" (§3.8, "Why not now?").
    private func whyNotNowLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "hourglass")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Typography.detail)
        .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
        .accessibilityLabel("Why not now: \(text)")
    }

    private func bigValue(_ status: PopoverModel.Status, number: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let prefix = status.prefix {
                Text(prefix)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
            }
            RollingNumber(number, value: status.rollValue, font: Theme.Typography.popoverNumber)
                .foregroundStyle(Theme.Colors.white(.title))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let unit = status.unit {
                Text(unit)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
            }
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if state.status.isPaused {
                PopoverActionButton(title: "Resume now", systemImage: "play.fill", role: .primary, item: .resume,
                                    showsChevron: false, commands: commands)
                PopoverActionButton(title: "Take a break", systemImage: nil, role: .secondary, item: .takeBreak,
                                    showsChevron: true, commands: commands)
            } else {
                PopoverActionButton(title: "Take a break", systemImage: nil, role: .primary, item: .takeBreak,
                                    showsChevron: true, commands: commands)
                PopoverActionButton(title: "Pause", systemImage: nil, role: .secondary, item: .pause,
                                    showsChevron: true, commands: commands)
            }
        }
    }

    private func decisionLine(_ decision: AutoDecision) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                .accessibilityHidden(true)
            Text(Copy.decisionLine(decision))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.white(.body))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            PopoverFocusRing(item: .undo, commands: commands) {
                PillButton("Undo", role: .tertiary, size: .small) { commands.perform(.undo) }
            }
            .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 36)
        .background(InsetCardBackground())
        .accessibilityElement(children: .contain)
    }

    // MARK: Agents

    private var agentsSection: some View {
        let rows = PopoverModel.agentRows(state)
        let visible = Array(rows.prefix(Theme.Layout.popoverMaxAgentRows))
        return VStack(alignment: .leading, spacing: 6) {
            PopoverSectionTitle("Agents")
            VStack(spacing: 0) {
                if rows.isEmpty {
                    if PopoverModel.showsConnectPrompt(state) {
                        connectPrompt
                    } else {
                        Text("No agent is running. Runs show up here as they start.")
                            .font(Theme.Typography.detail)
                            .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: Theme.Layout.agentRowHeight, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        agentRow(row)
                    }
                    if rows.count > visible.count {
                        RowDivider()
                        Text("+\(rows.count - visible.count) more")
                            .font(Theme.Typography.detail)
                            .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .padding(.leading, 12 + Theme.Layout.sourceTile + 10)
                    }
                }
            }
            .background(InsetCardBackground())
        }
    }

    private func agentRow(_ row: PopoverModel.AgentRow) -> some View {
        HStack(spacing: 10) {
            SourceTile(symbol: row.symbol)
            Text(row.title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.white(.body))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Chip(row.chip, tone: row.tone, size: .small)
                .fixedSize()
            Spacer(minLength: 4)
            Text(row.elapsed)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Layout.agentRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibility)
    }

    private var connectPrompt: some View {
        HStack(alignment: .top, spacing: 10) {
            SourceTile(symbol: "point.3.connected.trianglepath.dotted")
            VStack(alignment: .leading, spacing: 2) {
                Text("No agent connected yet")
                    .font(Theme.Typography.bodySemibold)
                    .foregroundStyle(Theme.Colors.white(.body))
                Text("Breaks wait for your agent to start working. Connect one to begin.")
                    .font(Theme.Typography.detail)
                    .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                    .fixedSize(horizontal: false, vertical: true)
                PopoverFocusRing(item: .connect, commands: commands) {
                    PillButton("Connect your agent…", role: .secondary, size: .small) { commands.perform(.connect) }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    // MARK: Totals

    /// All-time totals (SPEC §3.8): a period label, three figures with a short label each, and,
    /// once the moving time reaches the first example, one small quiet line.
    private var totalsSection: some View {
        let totals = state.totals
        // Fixed columns, so a large count scales down inside its own column instead of pushing.
        let countColumn = (Theme.Layout.popoverWidth - 2 * Theme.Spacing.m - 2 * Theme.Spacing.xxs
                           - Theme.Layout.popoverTotalsMovingColumn) / 2
        return VStack(alignment: .leading, spacing: 0) {
            PopoverSectionTitle(TotalsCopy.period(firstEntry: totals.firstEntry, now: state.now))
            HStack(alignment: .top, spacing: 0) {
                totalsFigure(TotalsCopy.movingParts(totals.movingSeconds), label: TotalsCopy.movingLabel,
                             value: totals.movingSeconds)
                    .frame(width: Theme.Layout.popoverTotalsMovingColumn, alignment: .leading)
                totalsFigure([TotalsCopy.Part(TotalsCopy.count(totals.stretches))],
                             label: TotalsCopy.stretchesLabel(totals.stretches), value: Double(totals.stretches))
                    .frame(width: countColumn, alignment: .leading)
                totalsFigure([TotalsCopy.Part(TotalsCopy.count(totals.eyeRests))],
                             label: TotalsCopy.eyeRestsLabel(totals.eyeRests), value: Double(totals.eyeRests))
                    .frame(width: countColumn, alignment: .leading)
            }
            .padding(.horizontal, Theme.Spacing.xxs)
            .padding(.top, Theme.Spacing.xs)
            if let line = TotalsCopy.exampleLine(totals) {
                exampleLine(line)
                    .padding(.horizontal, Theme.Spacing.xxs)
                    .padding(.top, Theme.Spacing.s)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TotalsCopy.accessibility(totals, now: state.now))
    }

    /// "74 min" over "moving": numbers rounded bold 30, units 15 at 75%, the label 13 at 60%.
    private func totalsFigure(_ parts: [TotalsCopy.Part], label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    RollingNumber(part.value, value: value, font: Theme.Typography.totalsNumber, countsDown: false)
                        .foregroundStyle(Theme.Colors.white(.title))
                        .padding(.leading, index > 0 ? Theme.Spacing.xxs : 0)
                    if let unit = part.unit {
                        Text(unit)
                            .font(Theme.Typography.totalsUnit)
                            .foregroundStyle(Theme.Colors.white(.label))
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.trailing, Theme.Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: Theme.Layout.popoverTotalsNumberHeight, alignment: .leading)
            .frame(height: Theme.Layout.popoverTotalsNumberHeight)
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                .lineLimit(1)
        }
    }

    /// "That's like walking the dog." 12 pt at the hint step; the activity in mint while it is new
    /// (the latest stretch or walk reached it), else at the label step.
    private func exampleLine(_ line: TotalsCopy.ExampleLine) -> some View {
        let quiet = Color.white.opacity(traits.hintOpacity)
        let activity = line.isNew ? Theme.Colors.mint : Theme.Colors.white(.label)
        return (Text(line.prefix).foregroundStyle(quiet)
                + Text(line.activity).foregroundStyle(activity)
                + Text(line.suffix).foregroundStyle(quiet))
            .font(Theme.Typography.detail)
            .lineLimit(1)
            .minimumScaleFactor(11.0 / 12.0)
    }

    // MARK: Footer

    private var footer: some View {
        let footer = PopoverModel.footer(state)
        return HStack(spacing: 6) {
            if let tone = footer.tone {
                StatusDot(tone: tone, style: tone == .mint ? .filled : .hollow, diameter: 6)
            }
            Text(footer.text)
                .font(Theme.Typography.hint)
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pieces

/// The popover's glass (SPEC §3.8, §4.5). On macOS 26 the popover window is itself Liquid Glass:
/// only the pop-up veil goes over it. On macOS 14 and 15: HUD material + 12% black tint with the
/// pop-ups' still lighting (the popover window draws the rim and arrow). Solid under Reduce
/// Transparency; the snapshot approximation when glass renders opaque.
struct PopoverBackground: View {
    private let traits = DesignTraits()

    var body: some View {
        if traits.reduceTransparency {
            Theme.Colors.solidPopup
        } else if traits.usesSystemGlass {
            Color.black.opacity(Theme.Glass.liquidVeil)
        } else {
            ZStack {
                switch traits.glassRendering {
                case .opaque:
                    Theme.Colors.glassApproximation
                case .simulated:
                    SimulatedGlassFill(shape: Rectangle())
                    GlassTint(shape: Rectangle())
                case .live:
                    VisualEffectBackground(material: .hudWindow, blending: .behindWindow)
                    GlassTint(shape: Rectangle())
                }
                if !traits.increaseContrast {
                    GlassLighting(shape: Rectangle())
                }
            }
        }
    }
}

/// Inset card (radius 14) on the popover glass.
struct InsetCardBackground: View {
    private let traits = DesignTraits()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
        shape.fill(Color.white.opacity(0.06))
            .overlay(shape.strokeBorder(Color.white.opacity(traits.increaseContrast ? 0.30 : 0.07), lineWidth: 1))
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 12)
    }
}

private struct PopoverSectionTitle: View {
    let title: String
    private let traits = DesignTraits()
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Draws the 2 pt mint keyboard-focus ring (60%) around a control when the popover's keyboard
/// focus is on it, and anchors menus to it.
struct PopoverFocusRing<Content: View>: View {
    let item: PopoverFocusItem
    @ObservedObject var commands: PopoverCommands
    @ViewBuilder let content: Content
    private let traits = DesignTraits()

    var body: some View {
        content
            .background(MenuAnchor(item: item))
            .overlay(
                Capsule(style: .circular)
                    .strokeBorder(Theme.Colors.mint.opacity(0.6), lineWidth: 2)
                    .padding(focused || traits.reduceMotion ? -3 : -1)
                    .opacity(focused ? 1 : 0)
                    .animation(traits.reduceMotion ? Theme.Motion.controlFade : Theme.Motion.focusRing, value: focused)
                    .allowsHitTesting(false))
    }

    private var focused: Bool { commands.focus == item }
}

/// A 28 pt capsule in the action row, full width share, with an optional ▾.
private struct PopoverActionButton: View {
    let title: String
    let systemImage: String?
    let role: PillButton.Role
    let item: PopoverFocusItem
    let showsChevron: Bool
    @ObservedObject var commands: PopoverCommands

    var body: some View {
        PopoverFocusRing(item: item, commands: commands) {
            Button {
                commands.perform(item)
            } label: {
                HStack(spacing: 5) {
                    if let systemImage {
                        Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                    }
                    Text(title).lineLimit(1)
                    if showsChevron {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .opacity(0.8)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(role: role, size: .small))
            .accessibilityLabel(showsChevron ? "\(title), menu" : title)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A round 26 pt icon button (the gear).
private struct PopoverIconButton: View {
    let systemImage: String
    let label: String
    let item: PopoverFocusItem
    @ObservedObject var commands: PopoverCommands
    @State private var hovering = false
    private let traits = DesignTraits()

    var body: some View {
        Button {
            commands.perform(item)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.white(.label))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.10 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PointerResponseStyle(Circle(), tone: .glass, lifts: false))
        .onHover { inside in
            withAnimation(Theme.Motion.hoverAnimation(inside, reduceMotion: traits.reduceMotion)) { hovering = inside }
        }
        .background(MenuAnchor(item: item))
        .overlay(
            Circle()
                .strokeBorder(Theme.Colors.mint.opacity(0.6), lineWidth: 2)
                .padding(commands.focus == item || traits.reduceMotion ? -2 : 0)
                .opacity(commands.focus == item ? 1 : 0)
                .animation(traits.reduceMotion ? Theme.Motion.controlFade : Theme.Motion.focusRing,
                           value: commands.focus == item)
                .allowsHitTesting(false))
        .accessibilityLabel(label)
    }
}
