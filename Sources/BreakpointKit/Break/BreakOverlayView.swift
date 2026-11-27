import SwiftUI
import BreakpointCore

// SPEC §3.3 (shared skeleton) and §3.4 (per kind).

/// A control on the overlay, for the keyboard focus model (Tab and arrows move between them,
/// Space activates, Return triggers the primary).
public enum OverlayControl: Hashable, Sendable, CaseIterable {
    /// Skip, relabelled Done after 80%.
    case skip
    /// "1 more minute".
    case extend
    /// The mint primary: I'm back / Welcome back / Back to work.
    case primary
}

/// Everything about an overlay frame that is not in `ActiveBreakState`: where the entrance or exit
/// is, keyboard focus, the Esc pulse, the safe area, and a sub-second clock for the Skip guard and
/// the breathing ring. The live controller computes it every frame; snapshots and the demo set it.
public struct OverlayPresentation: Equatable, Sendable {
    /// Entrance / exit frame.
    public var frame: OverlayFrame
    public var focused: OverlayControl?
    /// Hint opacity multiplier (1 → 0.5 → 1 on a single Esc).
    public var hintPulse: Double
    /// Top safe-area inset of this display (notch / menu bar).
    public var safeAreaTop: CGFloat
    /// Seconds since the break started, at frame precision (`nil`: use `ActiveBreakState.elapsed`).
    public var liveElapsed: TimeInterval?
    /// The backdrop's own clock in seconds (the aurora's drift), for frame-by-frame films. `nil`
    /// follows the wall clock (the app).
    public var backdropTime: TimeInterval?

    public init(frame: OverlayFrame = .settled, focused: OverlayControl? = nil, hintPulse: Double = 1,
                safeAreaTop: CGFloat = 0, liveElapsed: TimeInterval? = nil, backdropTime: TimeInterval? = nil) {
        self.frame = frame
        self.focused = focused
        self.hintPulse = hintPulse
        self.safeAreaTop = safeAreaTop
        self.liveElapsed = liveElapsed
        self.backdropTime = backdropTime
    }

    /// The controls the break shows, in order (Skip, kind controls, primary rightmost).
    public static func controls(for activeBreak: ActiveBreakState) -> [OverlayControl] {
        var controls: [OverlayControl] = [.skip]
        if activeBreak.canExtend && !activeBreak.needsYou { controls.append(.extend) }
        if hasPrimary(activeBreak) { controls.append(.primary) }
        return controls
    }

    /// A mint primary is shown: Back to work when an agent needs you, I'm back on `walk`.
    public static func hasPrimary(_ activeBreak: ActiveBreakState) -> Bool {
        activeBreak.needsYou || activeBreak.kind == .walk
    }

    /// The primary's label.
    public static func primaryTitle(_ activeBreak: ActiveBreakState) -> String {
        if activeBreak.needsYou { return "Back to work" }
        return activeBreak.welcomeBack ? "Welcome back" : "I'm back"
    }
}

/// The break overlay for one display: backdrop, then the centred column (agent chip, title,
/// instruction, kind line, hairline, guide, controls, hint).
///
/// - `displaySize`: the display's size in points (title size is 3.3% of its width, clamped 34–56).
/// - `showsContent`: false on non-active displays (backdrop + small timer only, unless
///   "Show the full break on every display").
///
/// Layout (SPEC §3.3), by baselines: the text group (title cap height to the instruction's last
/// baseline) is centred at 44% of the display height; the instruction's first baseline is 58 pt
/// below the title's; the kind line sits 16 pt below the instruction; the hairline 44 pt below
/// the instruction's (or kind line's) baseline; a plain timer's centre 66 pt below the hairline,
/// a ring's top 32 pt below it; the controls' centre 96 pt above the bottom; the hint 12 pt below
/// the controls. If the guide would crowd the controls on a short display, the whole group moves
/// up (never above the agent chip).
public struct BreakOverlayView: View {
    private let activeBreak: ActiveBreakState
    private let actions: AppActions
    private let displaySize: CGSize
    private let showsContent: Bool
    private let now: Date
    private let presentation: OverlayPresentation
    private let traits = DesignTraits()

    public init(activeBreak: ActiveBreakState, actions: AppActions, displaySize: CGSize, showsContent: Bool = true,
                now: Date, presentation: OverlayPresentation = OverlayPresentation()) {
        self.activeBreak = activeBreak
        self.actions = actions
        self.displaySize = displaySize
        self.showsContent = showsContent
        self.now = now
        self.presentation = presentation
    }

    private var frame: OverlayFrame { presentation.frame }
    private var elapsed: TimeInterval { presentation.liveElapsed ?? activeBreak.elapsed }
    private var ambient: Bool { activeBreak.ambient && activeBreak.kind == .walk && !activeBreak.needsYou }
    /// The closing moment of a completed break (`CompletionFrame`); `nil` while the break runs.
    private var completion: CompletionFrame? {
        activeBreak.completion.map { CompletionFrame.at(max(0, elapsed - $0.at), reduceMotion: traits.reduceMotion) }
    }
    /// What the break showed fades out during the closing moment.
    private var content: Double { completion?.content ?? 1 }

    public var body: some View {
        ZStack {
            OverlayBackdrop(frame.atmosphere, ambient: ambient, time: presentation.backdropTime)
            if showsContent {
                column
            } else {
                otherDisplay
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .environment(\.colorScheme, .dark)
        .animation(traits.reduceMotion ? .easeInOut(duration: Theme.Motion.reduceMotionFade) : traits.animation(.ambientWake),
                   value: ambient)
    }

    // MARK: Column

    private var titleSize: CGFloat { Theme.Typography.overlayTitleSize(displayWidth: displaySize.width) }

    private var column: some View {
        OverlayColumnLayout(safeAreaTop: presentation.safeAreaTop, titleCapHeight: titleSize * 0.7,
                            guideAnchor: activeBreak.kind == .eyes ? .timerCentre : .top)
        {
            agentChip
                .opacity(frame.chromeOpacity)
                .layoutValue(key: OverlayRoleKey.self, value: .chip)
            title
                .opacity(frame.titleOpacity * textDim)
                .blur(radius: traits.reduceMotion ? 0 : frame.titleBlur)
                .layoutValue(key: OverlayRoleKey.self, value: .title)
            instruction
                .opacity(frame.bodyOpacity * textDim * content)
                .offset(y: frame.bodyRise)
                .layoutValue(key: OverlayRoleKey.self, value: .instruction)
            if let step = activeBreak.step {
                steppedChip(step)
                    .opacity(frame.bodyOpacity * textDim * content)
                    .offset(y: frame.bodyRise)
                    .layoutValue(key: OverlayRoleKey.self, value: .kindLine)
            } else if let detail = activeBreak.detail {
                Chip(detail)
                    .opacity(frame.bodyOpacity * textDim * content)
                    .offset(y: frame.bodyRise)
                    .layoutValue(key: OverlayRoleKey.self, value: .kindLine)
            }
            Hairline()
                .opacity(frame.bodyOpacity * textDim)
                .offset(y: frame.bodyRise)
                .layoutValue(key: OverlayRoleKey.self, value: .hairline)
            guide
                .opacity(frame.bodyOpacity)
                .offset(y: frame.bodyRise)
                .layoutValue(key: OverlayRoleKey.self, value: .guide)
            controls
                .opacity(frame.chromeOpacity * (ambient ? 0 : 1) * content)
                .allowsHitTesting(!ambient && frame.chromeOpacity > 0.5 && completion == nil)
                .layoutValue(key: OverlayRoleKey.self, value: .controls)
            KeyHint(hint)
                .opacity(frame.chromeOpacity * presentation.hintPulse * (ambient ? 0 : 1) * content)
                .layoutValue(key: OverlayRoleKey.self, value: .hint)
            if activeBreak.isRehearsal {
                tourCoach
            } else if let hint = activeBreak.hint, !activeBreak.isPreview {
                // The first real break only (SPEC §3.12): where the tour's chip line goes, the same
                // coach line, saying what the chip is for.
                OverlayCoachLine([.text(hint)], pointing: .up, isHint: true)
                    .opacity(frame.chromeOpacity * (ambient ? 0 : 1))
                    .layoutValue(key: OverlayRoleKey.self, value: .coachChip)
            }
            if activeBreak.kind == .move {
                Text(BreakCopyLibrary.wellnessDisclaimer)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Color.white.opacity(traits.hintOpacity))
                    .opacity(frame.chromeOpacity * textDim)
                    .layoutValue(key: OverlayRoleKey.self, value: .footer)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
    }

    /// The tour's sample break (SPEC §3.12): a coach line under the agent chip and one beside the
    /// controls, and a footer that says this is a rehearsal, with Skip tour.
    @ViewBuilder private var tourCoach: some View {
        OverlayCoachLine(activeBreak.agentChip.tone == .mint ? TourCopy.breakChipDone : TourCopy.breakChipWorking,
                         pointing: .up)
            .animation(traits.animation(.agentChipColor), value: activeBreak.agentChip.tone == .mint)
            .opacity(frame.chromeOpacity)
            .layoutValue(key: OverlayRoleKey.self, value: .coachChip)
        OverlayCoachLine(TourCopy.breakControls, pointing: .leading)
            .opacity(frame.chromeOpacity)
            .layoutValue(key: OverlayRoleKey.self, value: .coachControls)
        HStack(spacing: Theme.Spacing.s) {
            Chip("Rehearsal", tone: .mint, size: .small)
            Text(TourCopy.rehearsalLabel)
                .font(Theme.Typography.coach)
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
            SkipTourButton(font: Theme.Typography.coach) { actions.tour(.skip) }
        }
        .fixedSize()
        .opacity(frame.chromeOpacity)
        .layoutValue(key: OverlayRoleKey.self, value: .coachFooter)
    }

    /// Ambient `walk`: all text except the chip and the timer at 50%.
    private var textDim: Double { ambient ? 0.5 : 1 }

    private var agentChip: some View {
        AgentChip(activeBreak.agentChip.text, tone: activeBreak.agentChip.tone, pulsing: activeBreak.agentChip.isWorking)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// The step key that drives the `move` slide (0 for other kinds).
    private var stepKey: Int { activeBreak.step?.index ?? 0 }

    private var stepTransition: AnyTransition {
        if traits.reduceMotion { return .opacity }
        let slide = Theme.Motion.moveStepSlide
        return .asymmetric(insertion: .offset(x: slide).combined(with: .opacity),
                           removal: .offset(x: -slide).combined(with: .opacity))
    }

    private var title: some View {
        ZStack {
            Text(activeBreak.title)
                .font(Theme.Typography.overlayTitle(displayWidth: displaySize.width))
                .foregroundStyle(Theme.Colors.white(.title))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
                .id(stepKey)
                .transition(stepTransition)
                .opacity(completion?.title ?? 1)
                .accessibilityHidden(completion != nil)
            if let line = activeBreak.completion?.line {
                // The closing line: the time or the routine, never praise and never a count.
                Text(line)
                    .font(Theme.Typography.overlayTitle(displayWidth: displaySize.width))
                    .foregroundStyle(Theme.Colors.white(.title))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .opacity(completion?.line ?? 0)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .animation(traits.animation(.moveStep), value: stepKey)
    }

    private var instruction: some View {
        ZStack {
            Text(activeBreak.instruction)
                .font(Theme.Typography.overlayInstruction)
                .foregroundStyle(Theme.Colors.white(.body))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .id(stepKey)
                .transition(stepTransition)
        }
        .animation(traits.animation(.moveStep), value: stepKey)
    }

    private func steppedChip(_ step: RoutineStepState) -> some View {
        ZStack {
            Chip(step.step.cue)
                .id(step.index)
                .transition(stepTransition)
        }
        .animation(traits.animation(.moveStep), value: step.index)
    }

    /// The kind's guide; during the closing moment it fades under the completion mark, which sits
    /// on the ring (or, on `eyes`, centred on the timer).
    private var guide: some View {
        ZStack(alignment: activeBreak.kind == .eyes ? .center : .top) {
            kindGuide
                .opacity(content)
            if let completion {
                CompletionMark.for(activeBreak, frame: completion)
            }
        }
    }

    @ViewBuilder private var kindGuide: some View {
        switch activeBreak.kind {
        case .eyes: EyesBreakView(activeBreak: activeBreak)
        case .move: MoveBreakView(activeBreak: activeBreak, liveElapsed: presentation.liveElapsed)
        case .walk: WalkBreakView(activeBreak: activeBreak)
        case .breathe: BreatheBreakView(activeBreak: activeBreak, now: now, liveElapsed: presentation.liveElapsed)
        }
    }

    // MARK: Controls and hint

    private var skipEnabled: Bool { elapsed >= activeBreak.skipEnabledAt || activeBreak.isPreview }
    private var guardProgress: Double {
        activeBreak.skipEnabledAt > 0 ? min(1, elapsed / activeBreak.skipEnabledAt) : 1
    }

    private var controls: some View {
        HStack(spacing: Theme.Layout.overlayControlGap) {
            ForEach(OverlayPresentation.controls(for: activeBreak), id: \.self) { control in
                button(control)
                    .environment(\.pillButtonFocused, presentation.focused == control)
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func button(_ control: OverlayControl) -> some View {
        switch control {
        case .skip:
            if activeBreak.doneAvailable {
                // Done is the way out the hint names ("return Done"), so it is the mint primary,
                // unless a mint primary (Back to work, I'm back) is already there.
                PillButton("Done", role: OverlayPresentation.hasPrimary(activeBreak) ? .primary : .mintPrimary) {
                    actions.finishBreak(.done)
                }
            } else {
                PillButton("Skip", role: .primary, guardProgress: skipEnabled ? nil : guardProgress) {
                    actions.skipBreak()
                }
                .disabled(!skipEnabled)
                .accessibilityHint(skipEnabled ? "" : "Available in a moment")
            }
        case .extend:
            PillButton("1 more minute", role: .primary) { actions.extendBreak() }
        case .primary:
            PillButton(OverlayPresentation.primaryTitle(activeBreak), role: .mintPrimary) {
                actions.finishBreak(activeBreak.needsYou ? .backToWork : .imBack)
            }
        }
    }

    private var hint: [KeyHint.Piece] {
        if activeBreak.isPreview { return [.key("esc"), .text("to close the preview")] }
        if activeBreak.needsYou { return [.key("return"), .text("Back to work")] }
        if OverlayPresentation.hasPrimary(activeBreak) {
            return [.key("esc"), .key("esc"), .text("to skip  ·  "), .key("return"),
                    .text(OverlayPresentation.primaryTitle(activeBreak))]
        }
        if activeBreak.doneAvailable { return [.key("return"), .text("Done")] }
        return [.key("esc"), .key("esc"), .text("to skip")]
    }

    // MARK: Other displays

    /// Backdrop plus a 13 pt timer at 60%, centred 40 pt below the safe-area top.
    private var otherDisplay: some View {
        VStack {
            RollingNumber(DurationFormat.clock(activeBreak.kind == .walk ? activeBreak.elapsed : activeBreak.remaining,
                                               rounding: activeBreak.kind == .walk ? .down : .up),
                          value: activeBreak.kind == .walk ? activeBreak.elapsed : activeBreak.remaining,
                          font: Theme.Typography.smallNumber, countsDown: activeBreak.kind != .walk)
                .foregroundStyle(Color.white.opacity(traits.secondaryOpacity))
                .padding(.top, presentation.safeAreaTop + Theme.Layout.overlayChipTop)
                .opacity(frame.chromeOpacity)
            Spacer()
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .accessibilityHidden(true)
    }
}

// MARK: - Column layout

enum OverlayRole: Sendable {
    case chip, title, instruction, kindLine, hairline, guide, controls, hint, footer
    /// The tour's sample break (SPEC §3.12): under the chip, beside the controls, at the bottom.
    case coachChip, coachControls, coachFooter
}

struct OverlayRoleKey: LayoutValueKey {
    static let defaultValue: OverlayRole = .title
}

/// Places the overlay column by baselines (see `BreakOverlayView`).
struct OverlayColumnLayout: Layout {
    enum GuideAnchor { case timerCentre, top }

    var safeAreaTop: CGFloat
    var titleCapHeight: CGFloat
    var guideAnchor: GuideAnchor
    /// Cap height of the 38 pt rounded timer (its optical centre is half of it above the baseline).
    var timerCapHeight: CGFloat = 38 * 0.7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 1512, height: 982))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        typealias L = Theme.Layout
        let width = bounds.width, height = bounds.height
        let cx = bounds.midX
        let columnWidth = min(L.overlayColumnMaxWidth, width - 96)
        let titleWidth = min(width - 96, 1120)
        func view(_ role: OverlayRole) -> LayoutSubview? { subviews.first { $0[OverlayRoleKey.self] == role } }
        func size(_ subview: LayoutSubview, width: CGFloat?) -> ViewDimensions {
            subview.dimensions(in: ProposedViewSize(width: width, height: nil))
        }

        // Chip: top edge 40 pt below the safe-area top.
        var chipBottom = bounds.minY + safeAreaTop + L.overlayChipTop
        if let chip = view(.chip) {
            let d = size(chip, width: nil)
            let top = bounds.minY + safeAreaTop + L.overlayChipTop
            chip.place(at: CGPoint(x: cx, y: top), anchor: .top, proposal: ProposedViewSize(width: d.width, height: d.height))
            chipBottom = top + d.height
        }
        if let coach = view(.coachChip) {
            let d = size(coach, width: nil)
            coach.place(at: CGPoint(x: cx, y: chipBottom + L.overlayCoachGap), anchor: .top,
                        proposal: ProposedViewSize(width: d.width, height: d.height))
            chipBottom += L.overlayCoachGap + d.height
        }

        // Bottom chrome: controls centred 96 pt above the bottom, hint 12 pt below them.
        var controlsTop = bounds.maxY - L.controlsCentreFromBottom
        if let controls = view(.controls) {
            let d = size(controls, width: nil)
            let centre = bounds.maxY - L.controlsCentreFromBottom
            controls.place(at: CGPoint(x: cx, y: centre), anchor: .center, proposal: ProposedViewSize(width: d.width, height: d.height))
            controlsTop = centre - d.height / 2
            if let coach = view(.coachControls) {
                let c = size(coach, width: nil)
                coach.place(at: CGPoint(x: cx + d.width / 2 + 10, y: centre), anchor: .leading,
                            proposal: ProposedViewSize(width: c.width, height: c.height))
            }
            if let hint = view(.hint) {
                let h = size(hint, width: nil)
                hint.place(at: CGPoint(x: cx, y: centre + d.height / 2 + L.hintGap), anchor: .top,
                           proposal: ProposedViewSize(width: h.width, height: h.height))
            }
        }
        if let coach = view(.coachFooter) {
            let d = size(coach, width: nil)
            let bottom = bounds.maxY - 20 - (view(.footer) == nil ? 0 : 24)
            coach.place(at: CGPoint(x: cx, y: bottom), anchor: .bottom, proposal: ProposedViewSize(width: d.width, height: d.height))
        }
        if let footer = view(.footer) {
            let d = size(footer, width: columnWidth)
            let baseline = bounds.maxY - 24
            footer.place(at: CGPoint(x: cx, y: baseline - d[VerticalAlignment.firstTextBaseline]), anchor: .top,
                         proposal: ProposedViewSize(width: columnWidth, height: d.height))
        }

        // The text group, relative to the title's baseline (0).
        guard let title = view(.title), let instruction = view(.instruction) else { return }
        let td = size(title, width: titleWidth)
        let id = size(instruction, width: columnWidth)
        let instructionFirst = L.titleToInstructionBaseline
        let instructionLast = instructionFirst + (id[VerticalAlignment.lastTextBaseline] - id[VerticalAlignment.firstTextBaseline])
        let groupCentre = (-titleCapHeight + instructionLast) / 2

        var cursor: CGFloat = instructionLast
        var kindLineTop: CGFloat?
        var kd: ViewDimensions?
        if let kind = view(.kindLine) {
            let d = size(kind, width: nil)
            kd = d
            kindLineTop = instructionLast + L.kindLineGap
            cursor = instructionLast + L.kindLineGap + d[VerticalAlignment.firstTextBaseline]
        }
        let hairlineY = cursor + L.instructionToHairline
        var guideTop = hairlineY
        var gd: ViewDimensions?
        if let guide = view(.guide) {
            let d = size(guide, width: columnWidth)
            gd = d
            switch guideAnchor {
            case .timerCentre:
                guideTop = hairlineY + L.hairlineToTimerCentre - (d[VerticalAlignment.firstTextBaseline] - timerCapHeight / 2)
            case .top:
                guideTop = hairlineY + L.hairlineToRingTop
            }
        }
        let guideBottom = guideTop + (gd?.height ?? 0)

        // Title baseline so the group's optical centre sits at 44% of the height, then nudged up
        // if the guide would crowd the controls (never above the chip).
        var titleBaseline = bounds.minY + height * L.overlayOpticalCentre - groupCentre
        let overflow = (titleBaseline + guideBottom) - (controlsTop - Theme.Spacing.xl)
        if overflow > 0 {
            let room = max(0, (titleBaseline - titleCapHeight) - (chipBottom + Theme.Spacing.xl))
            titleBaseline -= min(overflow, room)
        }

        title.place(at: CGPoint(x: cx, y: titleBaseline - td[VerticalAlignment.firstTextBaseline]), anchor: .top,
                    proposal: ProposedViewSize(width: titleWidth, height: td.height))
        instruction.place(at: CGPoint(x: cx, y: titleBaseline + instructionFirst - id[VerticalAlignment.firstTextBaseline]),
                          anchor: .top, proposal: ProposedViewSize(width: columnWidth, height: id.height))
        if let kind = view(.kindLine), let kindLineTop, let kd {
            kind.place(at: CGPoint(x: cx, y: titleBaseline + kindLineTop), anchor: .top,
                       proposal: ProposedViewSize(width: kd.width, height: kd.height))
        }
        if let hairline = view(.hairline) {
            hairline.place(at: CGPoint(x: cx, y: titleBaseline + hairlineY), anchor: .center,
                           proposal: ProposedViewSize(width: L.hairlineWidth, height: 1))
        }
        if let guide = view(.guide), let gd {
            guide.place(at: CGPoint(x: cx, y: titleBaseline + guideTop), anchor: .top,
                        proposal: ProposedViewSize(width: columnWidth, height: gd.height))
        }
    }
}
