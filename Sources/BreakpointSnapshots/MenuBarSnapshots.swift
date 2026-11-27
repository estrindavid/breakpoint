import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

// Status item, popover and app icon snapshots.

enum MenuBarSnapshots {
    @MainActor static var all: [Snapshot] {
        var list: [Snapshot] = [
            Snapshot("menubar/status-item-states", scenes: [SnapshotScene(appearance: .light, backdrop: .window)],
                     variants: [.standard, .increaseContrast, .reduceTransparency], renderer: .window, padding: 24) {
                StatusItemSheet()
            },
            Snapshot("menubar/status-item-enlarged", scenes: [SnapshotScene(appearance: .light, backdrop: .window)],
                     renderer: .window, padding: 24) {
                StatusItemEnlargedSheet()
            },
        ]

        let popovers: [(String, @MainActor () -> AppState)] = [
            ("first-run", { AppState.preview(.firstRun) }),
            ("idle", { AppState.preview(.idle) }),
            ("agent-working", { AppState.preview(.agentWorking) }),
            ("several-agents", { AppState.preview(.severalAgents) }),
            ("many-agents", { PopoverStates.manyAgents() }),
            ("break-due", { AppState.preview(.breakDue(.move)) }),
            ("on-break", { AppState.preview(.onBreak(.move, progress: 0.4)) }),
            ("paused-call", { AppState.preview(.pausedForCall) }),
            ("paused-manual", { AppState.preview(.pausedManual) }),
            ("paused-until-tomorrow", { PopoverStates.pausedUntilTomorrow() }),
            ("decision-line", { AppState.preview(.awayCredited) }),
            ("after-short-walk", { PopoverStates.afterShortWalk() }),
            ("wind-down", { PopoverStates.windDownPastStop() }),
            ("wrapped-up", { PopoverStates.wrappedUp() }),
            ("wrapped-up-debugger-line", { PopoverStates.wrappedUpDebuggerLine() }),
            ("why-not-now-holding", { PopoverStates.whyNotNow(.holding(.typing)) }),
            ("why-not-now-waiting-for-pause", { PopoverStates.whyNotNow(.waiting(.init(
                due: .move, next: .typingPause, typing: true, agent: .init(name: "Claude", state: .working)))) }),
            ("why-not-now-presenting", { PopoverStates.whyNotNow(.waiting(.init(
                due: .move, next: .agentRun, typing: false, agent: .init(name: "Claude", state: .working),
                quiet: .displayKeptAwake))) }),
            ("why-not-now-microphone", { PopoverStates.whyNotNow(.holding(.microphone)) }),
            ("why-not-now-spacing", { PopoverStates.whyNotNow(.spacingNudges(until: AppState.previewNow.addingTimeInterval(3 * 60 + 20))) }),
            // The third no in a row: the stretch waits its whole cadence (SPEC §2.4).
            ("why-not-now-spacing-stretches", { PopoverStates.whyNotNow(.spacingKind(.move, until: AppState.previewNow.addingTimeInterval(50 * 60))) }),
        ]
        for (name, make) in popovers {
            let variants: [SnapshotVariant] = ["idle", "agent-working", "decision-line"].contains(name)
                ? SnapshotVariant.accessibility : [.standard]
            list.append(Snapshot("menubar/popover-\(name)", scenes: SnapshotScene.popupBackdrops, variants: variants,
                                 renderer: .imageRenderer, padding: 32) {
                PopoverChrome { PopoverView(state: make(), actions: .noop) }
            })
        }
        // The all-time totals at each stage of use (SPEC §3.8), with an agent working.
        let stages: [(String, PreviewData.TotalsStage)] = [("first-break", .firstBreak), ("first-day", .firstDay),
                                                            ("week", .weekIn), ("month", .monthIn), ("large", .large)]
        for (name, stage) in stages {
            list.append(Snapshot("menubar/popover-totals-\(name)", scenes: SnapshotScene.popupBackdrops,
                                 variants: [.standard, .increaseContrast], renderer: .imageRenderer, padding: 32) {
                PopoverChrome { PopoverView(state: PopoverStates.totals(stage), actions: .noop) }
            })
        }
        list.append(Snapshot("menubar/popover-keyboard-focus", scenes: SnapshotScene.popupBackdrops, renderer: .imageRenderer,
                             padding: 32) {
            PopoverChrome { PopoverView(state: AppState.preview(.agentWorking), actions: .noop, previewFocusIndex: 1) }
        })

        list.append(Snapshot("menubar/mark-movements", scenes: [SnapshotScene(appearance: .light, backdrop: .window)],
                             variants: [.standard, .increaseContrast], renderer: .window, padding: 24) {
            MarkMovementSheet()
        })
        list.append(Snapshot("menubar/mark-movements-enlarged", scenes: [SnapshotScene(appearance: .light, backdrop: .window)],
                             renderer: .window, padding: 24) {
            MarkMovementEnlargedSheet()
        })

        list.append(Snapshot("menubar/app-icon", scenes: SnapshotScene.lightAndDark, renderer: .imageRenderer, padding: 24) {
            AppIconSheet()
        })
        list.append(Snapshot("menubar/app-icon-small-pixels", scenes: SnapshotScene.lightAndDark, renderer: .imageRenderer,
                             padding: 24) {
            AppIconPixelSheet()
        })
        return list
    }
}

// MARK: - States beyond the shared scenarios

@MainActor
enum PopoverStates {
    static func totals(_ stage: PreviewData.TotalsStage) -> AppState {
        let state = AppState.preview(.agentWorking)
        state.totals = PreviewData(now: state.now).totals(stage)
        return state
    }

    static func pausedUntilTomorrow() -> AppState {
        let state = AppState.preview(.idle)
        let until = BreakpointDay.nextBoundary(after: state.now)
        state.status.pause = PauseState(reasons: [.manual(until: until)])
        state.status.pauseSentence = Copy.pauseSentence(.manual(until: until), now: state.now)
        state.status.pausedUntil = until
        state.menuBar = MenuBarState(mark: .paused, text: "Paused", tooltip: state.status.pauseSentence ?? "Paused")
        return state
    }

    static func windDownPastStop() -> AppState {
        let state = AppState.preview(.windDown(wrapUp: false))
        state.status.nextBreakIn = 11 * 60
        return state
    }

    static func wrappedUp() -> AppState {
        let state = AppState.preview(.windDown(wrapUp: true))
        let until = BreakpointDay.nextBoundary(after: state.now)
        state.status.pause = PauseState(reasons: [.windDownWrappedUp(until: until)])
        state.status.pauseSentence = Copy.pauseSentence(.windDownWrappedUp(until: until), now: state.now)
        state.status.pausedUntil = until
        return state
    }

    /// A due stretch with no nudge, and the popover's "Why not now?" line for `reason`.
    static func whyNotNow(_ reason: WaitReason) -> AppState {
        let state = AppState.preview(.breakDue(.move))
        state.status.whyNotNow = reason
        return state
    }

    /// The wrapped-up popover on the night its detail line is the one in debugger voice.
    static func wrappedUpDebuggerLine() -> AppState {
        let base = AppState.previewNow
        let night = (0..<Copy.wrappedUpDetails.count).map { base.addingTimeInterval(Double($0) * 86_400) }
            .first { Copy.debuggerVoice.contains(Copy.wrappedUpDetail(now: $0)) } ?? base
        let state = wrappedUp()
        state.now = night
        let until = BreakpointDay.nextBoundary(after: night)
        state.status.pause = PauseState(reasons: [.windDownWrappedUp(until: until)])
        state.status.pausedUntil = until
        return state
    }

    /// 14½ min still, then Take a break ▸ Walk (5 min) ended with I'm back after 90 s away from the
    /// keys, then two minutes back at work. The timers come from the real rules (`BreakSessionRules`,
    /// `ActivityClock`), so the "since you moved" line reads what the app would show.
    static func afterShortWalk() -> AppState {
        let state = AppState.preview(.idle)
        let cadence = BreakpointCore.Settings.defaults.cadence
        let end = state.now.addingTimeInterval(-120)
        let walk = BreakSessionRules.makeSession(kind: .walk, opportunity: nil, settings: .defaults, expectedRun: nil,
                                                 agentName: nil, copyRotation: 0, now: end.addingTimeInterval(-90))
        let outcome = BreakSessionRules.outcome(for: .finish(.imBack), session: walk, now: end)
        // Ninety seconds without input is not away (threshold 3 min), so the walk accrued as presence.
        var timers = TimerState(screenTime: 10 * 60, stillTime: 14.5 * 60).adding(90)
        timers = ActivityClock.afterBreak(timers, kind: .walk, outcome: outcome)
        timers = timers.adding(120)
        let eyesIn = cadence.eyesEvery - timers.screenTime, moveIn = cadence.moveEvery - timers.stillTime
        state.status.timers = timers
        state.status.nextBreakKind = moveIn <= eyesIn ? .move : .eyes
        state.status.nextBreakIn = min(eyesIn, moveIn)
        return state
    }

    static func manyAgents() -> AppState {
        let state = AppState.preview(.severalAgents)
        let p = PreviewData(now: state.now)
        var gemini = p.codexWorking
        gemini.key = SessionKey(source: .gemini, sessionID: "g1")
        gemini.cwd = "/Users/dev/code/a-project-with-a-rather-long-folder-name"
        var copilot = p.cursorIdle
        copilot.key = SessionKey(source: .copilot, sessionID: "p1")
        copilot.cwd = "/Users/dev/code/notes"
        state.sessions += [gemini, copilot]
        return state
    }
}

// MARK: - Popover chrome (approximates NSPopover's frame: radius, rim and arrow)

/// The popover's frame and arrow (the real window draws them in the app). The glass snapshots
/// leave the arrow out.
struct PopoverChrome<Content: View>: View {
    var arrow = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if arrow {
                PopoverArrow()
                    .fill(Theme.Colors.glassApproximation)
                    .frame(width: 26, height: 11)
                    .offset(y: 1)
            }
            content
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    }
}

private struct PopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.midX - 4, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX + 4, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Status item sheets

private struct SheetCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

@MainActor
private enum StatusSamples {
    static let marks: [(String, MenuBarState)] = [
        ("idle", MenuBarState(mark: .idle, tooltip: "Eye rest in 6 min")),
        ("break due", MenuBarState(mark: .due, tooltip: "Stretch due")),
        ("on a break", MenuBarState(mark: .onBreak, tooltip: "On a break")),
        ("paused", MenuBarState(mark: .paused, tooltip: "Paused: microphone is on")),
    ]
    static let badges: [(String, BrandMark.Badge)] = [("no agent", .none), ("agent working", .working),
                                                         ("needs you", .needsYou)]
    static let texts: [MenuBarState] = [
        MenuBarState(mark: .idle, text: "6m", tooltip: "Eye rest in 6 min"),
        MenuBarState(mark: .due, badge: .working, text: "due", tooltip: "Stretch due"),
        MenuBarState(mark: .idle, badge: .working, text: "Claude 3m", tooltip: "Eye rest in 14 min"),
        MenuBarState(mark: .paused, text: "Paused", tooltip: "Paused: microphone is on"),
    ]
}

/// Every mark × badge at actual size on light, dark and tinted menu bars, plus the text options.
private struct StatusItemSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(MenuBarBackdrop.allCases, id: \.self) { backdrop in
                VStack(alignment: .leading, spacing: 6) {
                    SheetCaption("\(backdrop.rawValue) menu bar · actual size")
                    HStack(spacing: 0) {
                        ForEach(StatusSamples.badges, id: \.0) { _, badge in
                            MenuBarStripPreview(StatusSamples.marks.map { var m = $0.1; m.badge = badge; return m },
                                                backdrop: backdrop)
                        }
                    }
                    MenuBarStripPreview(StatusSamples.texts, backdrop: backdrop)
                    MenuBarStripPreview([StatusSamples.marks[0].1], backdrop: backdrop, highlighted: true)
                }
            }
            HStack(spacing: 24) {
                ForEach(StatusSamples.marks, id: \.0) { name, _ in
                    Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Text("Badges per row: none · working (dot, breathes) · needs you (ring). Last strip: the item highlighted while its popover is open.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

/// The template images enlarged 4× with nearest-neighbour scaling, to judge pixel crispness.
private struct StatusItemEnlargedSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetCaption("Status item template images · 4× enlarged (2× pixels)")
            ForEach(StatusSamples.badges, id: \.0) { badgeName, badge in
                HStack(spacing: 20) {
                    ForEach(StatusSamples.marks, id: \.0) { name, state in
                        VStack(spacing: 4) {
                            Image(nsImage: BrandMark.templateImage(state.mark.variant, badge: badge))
                                .renderingMode(.template)
                                .interpolation(.none)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 72)
                                .foregroundStyle(Color.black.opacity(0.85))
                                .background(Color(hex: 0xF4F4F6))
                            Text("\(name), \(badgeName)").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Mark movements (§3.7)

/// One movement: the state before, its key frames, and the state after.
@MainActor
private struct MarkMovement {
    let cue: MarkCue
    let title: String
    let before: MenuBarState
    let frameState: MenuBarState
    let after: MenuBarState

    static let all: [MarkMovement] = [
        MarkMovement(cue: .settle, title: "An agent finishes · settle, 0.4 s",
                     before: MenuBarState(mark: .idle, badge: .working), frameState: MenuBarState(mark: .idle, badge: .working),
                     after: MenuBarState(mark: .idle)),
        MarkMovement(cue: .lift, title: "An agent needs you · lift, 0.3 s",
                     before: MenuBarState(mark: .idle, badge: .working), frameState: MenuBarState(mark: .idle, badge: .needsYou),
                     after: MenuBarState(mark: .idle, badge: .needsYou)),
        MarkMovement(cue: .fold, title: "Wrapped up for the night · fold, 0.45 s",
                     before: MenuBarState(mark: .idle), frameState: MenuBarState(mark: .idle),
                     after: MenuBarState(mark: .paused, text: "Paused")),
    ]

    static let frameCount = 7

    /// Before, the key frames, after.
    var strip: (items: [MenuBarState], poses: [MarkPose]) {
        let frames = MarkMotion.keyFrames(cue, count: Self.frameCount)
        return ([before] + Array(repeating: frameState, count: frames.count) + [after], [.rest] + frames + [.rest])
    }
}

/// Each movement as a strip of key frames at actual size on light, dark and tinted menu bars, and
/// what Reduce Motion (or a locked screen) shows instead: the state before, then the state after.
private struct MarkMovementSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(MarkMovement.all.enumerated()), id: \.offset) { _, movement in
                VStack(alignment: .leading, spacing: 6) {
                    SheetCaption(movement.title)
                    ForEach(MenuBarBackdrop.allCases, id: \.self) { backdrop in
                        HStack(spacing: 12) {
                            MenuBarStripPreview(movement.strip.items, poses: movement.strip.poses, backdrop: backdrop)
                            Text(backdrop.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        MenuBarStripPreview([movement.before, movement.after], backdrop: .light)
                        Text("Reduce Motion, locked or asleep: no movement, the new state appears")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Each strip: the state before · \(MarkMovement.frameCount) key frames at even steps · the state after. Played once, never looped.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

/// The key frames' template images enlarged 4× with hard pixels, to judge them at real resolution.
private struct MarkMovementEnlargedSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetCaption("Mark movements · template images 4× enlarged (2× pixels)")
            ForEach(Array(MarkMovement.all.enumerated()), id: \.offset) { _, movement in
                VStack(alignment: .leading, spacing: 4) {
                    Text(movement.title).font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        let strip = movement.strip
                        ForEach(Array(strip.items.enumerated()), id: \.offset) { index, item in
                            Image(nsImage: BrandMark.templateImage(item.mark.variant, badge: item.badge, pose: strip.poses[index]))
                                .renderingMode(.template)
                                .interpolation(.none)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 72)
                                .foregroundStyle(Color.black.opacity(0.85))
                                .background(Color(hex: 0xF4F4F6))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - App icon sheets

private struct AppIconSheet: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            ForEach([16, 32, 64, 128, 256], id: \.self) { size in
                VStack(spacing: 6) {
                    AppIconView().frame(width: CGFloat(size), height: CGFloat(size))
                    Text("\(size) pt").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The 16 and 32 px iconset images (as written for the bundle) at 8× and 4× with hard pixels.
private struct AppIconPixelSheet: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ForEach([16, 32, 64], id: \.self) { pixels in
                VStack(spacing: 6) {
                    if let image = Self.raster(pixels) {
                        Image(decorative: image, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 128, height: 128)
                    }
                    Text("\(pixels) px").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @MainActor static func raster(_ pixels: Int) -> CGImage? {
        let renderer = ImageRenderer(content: AppIconView().frame(width: CGFloat(pixels), height: CGFloat(pixels)))
        renderer.scale = 1
        return renderer.cgImage
    }
}
