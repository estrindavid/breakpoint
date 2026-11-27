import SwiftUI
import BreakpointCore
import BreakpointKit

// Snapshots of the design system, on neutral and dark backdrops, for review.

enum DesignSnapshots {
    @MainActor static var all: [Snapshot] {
        [
            Snapshot("design/brand-mark", scenes: SnapshotScene.lightAndDark) { BrandMarkSheet() },
            Snapshot("design/menu-bar-marks", scenes: SnapshotScene.lightAndDark) { MenuBarMarkSheet() },
            Snapshot("design/colors", scenes: SnapshotScene.popupBackdrops) { ColorSheet() },
            Snapshot("design/type-scale", scenes: SnapshotScene.popupBackdrops) { TypeSheet() },
            Snapshot("design/glass-card", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
                GlassSample()
            },
            Snapshot("design/buttons", scenes: SnapshotScene.popupBackdrops, variants: SnapshotVariant.accessibility) {
                ButtonSheet()
            },
            Snapshot("design/buttons-window", scenes: SnapshotScene.lightAndDark) { WindowButtonSheet() },
            Snapshot("design/buttons-pointer", scenes: SnapshotScene.popupBackdrops,
                     variants: [.standard, .increaseContrast, .reduceMotion]) {
                PointerSheet()
            },
            Snapshot("design/buttons-pointer-window", scenes: SnapshotScene.lightAndDark) { PointerSheet(onWindow: true) },
            Snapshot("design/badges", scenes: SnapshotScene.popupBackdrops) { BadgeSheet() },
            Snapshot("design/chips", scenes: SnapshotScene.popupBackdrops, variants: [.standard, .increaseContrast]) {
                ChipSheet()
            },
            Snapshot("design/rings", scenes: SnapshotScene.popupBackdrops) { RingSheet() },
            Snapshot("design/keycaps", scenes: SnapshotScene.popupBackdrops, variants: [.standard, .increaseContrast]) {
                KeycapSheet()
            },
            Snapshot("design/toasts", scenes: SnapshotScene.allBackdrops, variants: SnapshotVariant.accessibility) {
                ToastSheet()
            },
            Snapshot("design/settings-rows", scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                SettingsRowSheet()
            },
            Snapshot("design/preset-cards", scenes: SnapshotScene.lightAndDark, renderer: .window, padding: 24) {
                PresetCardSheet()
            },
        ]
    }
}

// MARK: - Sheets

private struct SheetLabel: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.5) : Color.black.opacity(0.45))
    }
}

/// On popup backdrops the sheet text sits on a light or dark desktop; draw labels on a small plate.
private struct Plate<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GlassCard(radius: 20, padding: 20) { content }
    }
}

private struct BrandMarkSheet: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetLabel("Brand mark")
            HStack(alignment: .center, spacing: 28) {
                BrandMark(.brand).foregroundStyle(Theme.Colors.brandGradient).frame(height: 96)
                BrandMark(.brand).foregroundStyle(Theme.Colors.accent(for: scheme)).frame(height: 48)
                BrandMark(.brand).foregroundStyle(.primary).frame(height: 24)
                BrandMark(.brand).foregroundStyle(.primary).frame(height: 13)
            }
            SheetLabel("Menu-bar states at 64 pt (idle · due · on a break · paused)")
            HStack(spacing: 28) {
                ForEach(MenuBarMark.allCases, id: \.self) { mark in
                    BrandMark(mark.variant).foregroundStyle(.primary).frame(height: 40)
                }
            }
            SheetLabel("Badges (working · needs you)")
            HStack(spacing: 28) {
                BrandMark(.idle, badge: .working).foregroundStyle(.primary).frame(height: 40)
                BrandMark(.idle, badge: .needsYou).foregroundStyle(.primary).frame(height: 40)
                BrandMark(.paused, badge: .needsYou).foregroundStyle(.primary).frame(height: 40)
                BrandMark(.onBreak, badge: .working).foregroundStyle(.primary).frame(height: 40)
            }
        }
    }
}

private struct MenuBarMarkSheet: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetLabel("Status item template images, 18 pt (actual size)")
            HStack(spacing: 14) {
                ForEach(MenuBarMark.allCases, id: \.self) { mark in
                    ForEach([BrandMark.Badge.none, .working, .needsYou], id: \.self) { badge in
                        Image(nsImage: BrandMark.templateImage(mark.variant, badge: badge))
                            .renderingMode(.template)
                            .foregroundStyle(scheme == .dark ? Color.white : Color.black.opacity(0.85))
                    }
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14)
                }
                HStack(spacing: 4) {
                    Image(nsImage: BrandMark.templateImage(.paused)).renderingMode(.template)
                    Text("Paused").font(.system(size: 13))
                }
                .foregroundStyle(scheme == .dark ? Color.white : Color.black.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(scheme == .dark ? Color(hex: 0x2B2B30) : Color(hex: 0xF2F2F4))
        }
    }
}

private struct ColorSheet: View {
    let swatches: [(String, Color)] = [
        ("mint #3DD6B0", Theme.Colors.mint), ("mint light #12A688", Theme.Colors.mintLight),
        ("indigo #6C7CFF", Theme.Colors.indigo), ("amber #FFB454", Theme.Colors.amber),
        ("solid pop-up #151A22", Theme.Colors.solidPopup), ("scrim #070A12", Theme.Colors.scrim),
    ]
    var body: some View {
        Plate {
            VStack(alignment: .leading, spacing: 14) {
                SheetLabel("Palette")
                HStack(spacing: 12) {
                    ForEach(swatches, id: \.0) { name, color in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
                                .frame(width: 84, height: 44)
                            Text(name).font(.system(size: 10)).foregroundStyle(Theme.Colors.white(.secondary))
                        }
                    }
                }
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Colors.brandGradient)
                        .frame(width: 180, height: 44)
                    Text("Breakpoint gradient, 135°").font(.system(size: 10)).foregroundStyle(Theme.Colors.white(.secondary))
                }
                SheetLabel("Text steps on dark glass")
                HStack(spacing: 14) {
                    ForEach([("100", Theme.TextStep.title), ("85", .body), ("75", .label), ("60", .secondary), ("50", .hint)],
                            id: \.0) { label, step in
                        Text("Aa \(label)%").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Colors.white(step))
                    }
                }
            }
        }
    }
}

private struct TypeSheet: View {
    var body: some View {
        Plate {
            VStack(alignment: .leading, spacing: 10) {
                Text("Find the farthest point").font(Theme.Typography.overlayTitle(displayWidth: 1512))
                    .foregroundStyle(Theme.Colors.white(.title))
                Text("Let your focus go soft until the timer ends.").font(Theme.Typography.overlayInstruction)
                    .foregroundStyle(Theme.Colors.white(.body))
                RollingNumber("0:19", value: 19).foregroundStyle(Theme.Colors.white(.secondary))
                Text("2-min stretch?").font(Theme.Typography.nudgeTitle).foregroundStyle(Theme.Colors.white(.title))
                Text("Claude is working").font(Theme.Typography.nudgeSubtitle).foregroundStyle(Theme.Colors.white(.secondary))
                RollingNumber("6 min", value: 6, font: Theme.Typography.popoverNumber).foregroundStyle(Theme.Colors.white(.title))
                Text("It's 23:20.").font(Theme.Typography.windDownTitle).foregroundStyle(Theme.Colors.white(.title))
                Text("In").font(Theme.Typography.breatheWord).foregroundStyle(Theme.Colors.white(.title))
                Text("General wellness, not medical advice.").font(Theme.Typography.hint)
                    .foregroundStyle(Theme.Colors.white(.hint))
            }
            .frame(width: 560, alignment: .leading)
        }
    }
}

private struct GlassSample: View {
    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: Theme.Layout.badgeToText) {
                KindBadge(kind: .move)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glass card").font(Theme.Typography.nudgeTitle).foregroundStyle(Theme.Colors.white(.title))
                    Text("Radius 28 · padding 14 · lit rim").font(Theme.Typography.nudgeSubtitle)
                        .foregroundStyle(Theme.Colors.white(.secondary))
                    HStack(spacing: Theme.Layout.buttonGap) {
                        PillButton("Primary", role: .primary) {}
                        PillButton("Secondary", role: .secondary) {}
                    }
                    .padding(.top, Theme.Layout.rowGap - 2)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: Theme.Layout.nudgeSize.width)
    }
}

private struct ButtonSheet: View {
    var body: some View {
        Plate {
            VStack(alignment: .leading, spacing: 14) {
                SheetLabel("Pop-up buttons, 34 pt")
                HStack(spacing: Theme.Layout.buttonGap) {
                    PillButton("Start", role: .primary, keycap: "⌃⌥⌘B", showsKeycap: false) {}
                    PillButton("Not now", role: .secondary) {}
                    PillButton("Undo", role: .tertiary) {}
                }
                SheetLabel("With keycaps (nudge on hover)")
                HStack(spacing: Theme.Layout.buttonGap) {
                    PillButton("Start", role: .primary, keycap: "⌃⌥⌘B") {}
                    PillButton("Not now", role: .secondary, keycap: "⌃⌥⌘.") {}
                }
                SheetLabel("Small card buttons, 28 pt")
                HStack(spacing: 8) {
                    PillButton("Resume", role: .primary, size: .small) {}
                    PillButton("15 more minutes", role: .secondary, size: .small) {}
                    PillButton("Wrap up", role: .mintPrimary, size: .small) {}
                    PillButton("Undo", role: .tertiary, size: .small) {}
                }
                SheetLabel("Overlay controls: guard ring, Done, mint primary")
                HStack(spacing: Theme.Layout.overlayControlGap) {
                    PillButton("Skip", role: .primary, guardProgress: 0.45) {}.disabled(true)
                    PillButton("Done", role: .primary) {}
                    PillButton("1 more minute", role: .primary) {}
                    PillButton("I'm back", role: .mintPrimary) {}
                }
            }
        }
    }
}

/// Every role at rest, under the pointer (the light sits where the pointer is), pressed and with
/// keyboard focus (SPEC §3.0 "Buttons"). States are forced with `controlResponsePreview`.
private struct PointerSheet: View {
    var onWindow = false

    private static let states: [(String, ControlResponse)] = [
        ("Rest", .rest),
        ("Hover", ControlResponse(hover: 1, location: UnitPoint(x: 0.28, y: 0.3))),
        ("Hover, pointer right", ControlResponse(hover: 1, location: UnitPoint(x: 0.8, y: 0.55))),
        ("Pressed", ControlResponse(hover: 1, press: 1, location: UnitPoint(x: 0.45, y: 0.5))),
        ("Keyboard focus", ControlResponse(focus: 1)),
    ]

    var body: some View {
        if onWindow {
            grid
        } else {
            Plate { grid }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            GridRow {
                ForEach(Self.states, id: \.0) { state in SheetLabel(state.0) }
            }
            row { PillButton("Start", role: .primary, size: onWindow ? .small : .regular, keycap: "⌃⌥⌘B") {} }
            row { PillButton("Not now", role: .secondary, size: onWindow ? .small : .regular) {} }
            row { PillButton(onWindow ? "Continue" : "I'm back", role: .mintPrimary, size: onWindow ? .small : .regular) {} }
            row { PillButton("Undo", role: .tertiary, size: onWindow ? .small : .regular) {} }
        }
    }

    private func row(@ViewBuilder _ button: @escaping () -> some View) -> some View {
        GridRow {
            ForEach(Self.states, id: \.0) { state in
                button().controlResponsePreview(state.1)
            }
        }
    }
}

private struct WindowButtonSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetLabel("Pill buttons on windows (onboarding)")
            HStack(spacing: 8) {
                PillButton("Back", role: .secondary, size: .small) {}
                PillButton("Skip for now", role: .tertiary, size: .small) {}
                PillButton("Continue", role: .mintPrimary, size: .small) {}
                PillButton("Install", role: .primary, size: .small) {}
            }
        }
    }
}

private struct BadgeSheet: View {
    var body: some View {
        Plate {
            VStack(alignment: .leading, spacing: 14) {
                SheetLabel("Kind badges 44 pt")
                HStack(spacing: 14) {
                    ForEach(BreakKind.allCases) { KindBadge(kind: $0) }
                    KindBadge(kind: .eyes, ringProgress: 0.35)
                }
                SheetLabel("Away note 32 · resume card 28 (agent, needs you) · countdown chip 22")
                HStack(spacing: 14) {
                    KindBadge(kind: .move, diameter: 32)
                    KindBadge(symbol: "sparkle", tone: .agent, diameter: 28)
                    KindBadge(symbol: "hand.raised.fill", tone: .needsYou, diameter: 28)
                    KindBadge(kind: .eyes, diameter: 22)
                }
                SheetLabel("Status dots")
                HStack(spacing: 14) {
                    StatusDot(tone: .agent)
                    StatusDot(tone: .mint)
                    StatusDot(tone: .needsYou)
                    StatusDot(tone: .needsYou, style: .hollow)
                    StatusDot(tone: .neutral)
                }
            }
        }
    }
}

private struct ChipSheet: View {
    var body: some View {
        Plate {
            VStack(alignment: .leading, spacing: 14) {
                SheetLabel("Cue chip and state chips")
                HStack(spacing: 8) {
                    Chip("3 s squeeze · 3 s release")
                    Chip("working", tone: .agent)
                    Chip("needs you", tone: .needsYou)
                    Chip("idle")
                    Chip("Connected", tone: .mint, showsDot: true)
                }
                SheetLabel("Small state chips (popover agent rows)")
                HStack(spacing: 8) {
                    Chip("working", tone: .agent, size: .small)
                    Chip("needs you", tone: .needsYou, size: .small)
                    Chip("idle", size: .small)
                    Chip("swift running", size: .small)
                }
                SheetLabel("Agent chip (overlay)")
                VStack(alignment: .leading, spacing: 8) {
                    AgentChip("Claude is still working · 1:42", tone: .agent, pulsing: true)
                    AgentChip("Claude is done. No rush.", tone: .mint)
                    AgentChip("Claude needs you", tone: .needsYou)
                    AgentChip("14:05", tone: nil)
                }
                SheetLabel("Hairline 160 pt")
                Hairline()
            }
        }
    }
}

private struct RingSheet: View {
    var body: some View {
        Plate {
            VStack(alignment: .leading, spacing: 14) {
                SheetLabel("Rings: popover 44 · move 140 · walk 160")
                HStack(alignment: .center, spacing: 28) {
                    ProgressRing(progress: 0.84, lineWidth: 4).frame(width: 44, height: 44)
                    ProgressRing(progress: 0.6, lineWidth: Theme.Layout.moveRingStroke) {
                        RollingNumber("0:18", value: 18).foregroundStyle(Theme.Colors.white(.secondary))
                    }
                    .frame(width: Theme.Layout.moveRing, height: Theme.Layout.moveRing)
                    ProgressRing(progress: 0.55, lineWidth: Theme.Layout.walkRingStroke) {
                        RollingNumber("3:18", value: 198, countsDown: false).foregroundStyle(Theme.Colors.white(.secondary))
                    }
                    .frame(width: Theme.Layout.walkRing, height: Theme.Layout.walkRing)
                }
                SheetLabel("Step dots")
                HStack(spacing: Theme.Layout.stepDotGap) {
                    Circle().fill(Theme.Colors.mint).frame(width: 6, height: 6)
                    Circle().fill(Theme.Colors.mint).frame(width: 6, height: 6)
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 6, height: 6)
                }
            }
        }
    }
}

private struct KeycapSheet: View {
    var body: some View {
        Plate {
            VStack(alignment: .leading, spacing: 14) {
                SheetLabel("Keycaps and hint lines (11 pt, 50%)")
                HStack(spacing: 6) {
                    Keycap("esc"); Keycap("return"); Keycap("⌃⌥⌘B"); Keycap("→"); Keycap("⌘C")
                }
                KeyHint([.key("esc"), .key("esc"), .text("to skip  ·  "), .key("return"), .text("I'm back")])
                KeyHint([.key("return"), .text("Back to work")])
            }
        }
    }
}

private struct ToastSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToastShell(text: "Counted your 6 min away as a break", badge: .move, actionTitle: "Undo")
            ToastShell(text: "Breaks paused: microphone is on", actionTitle: "Resume")
            ToastShell(text: "Timers restored")
        }
    }
}

private struct SettingsRowSheet: View {
    @State private var on = true
    @State private var minutes = 20
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.sectionGap) {
            HStack(spacing: 8) {
                ForEach(0..<8, id: \.self) { i in
                    SidebarTile(systemImage: ["timer", "figure.arms.open", "pause.circle", "moon", "point.3.connected.trianglepath.dotted",
                                              "gearshape", "hand.raised", "info.circle"][i], index: i)
                }
            }
            SettingsSection("Breaks") {
                SentenceRow {
                    Text("Offer an eye rest after")
                    Picker("", selection: $minutes) {
                        ForEach([10, 15, 20, 25, 30], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Text("min of screen time")
                }
                SettingsDivider()
                SettingRow("Start eye rests by themselves",
                           description: "A 10-second countdown runs first; typing, clicking or scrolling cancels it.",
                           systemImage: "eye") {
                    Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsDivider()
                SettingRow("Pause during calls", description: "No break is offered while any microphone is in use.",
                           systemImage: "mic", options: {}) {
                    Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
        .frame(width: 560)
    }
}

private struct PresetCardSheet: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(CadencePreset.cards) { preset in
                PresetCard(title: preset.title,
                           detail: "Eye rest every \(preset.cadence!.eyesEveryMinutes) min\nStretch every \(preset.cadence!.moveEveryMinutes) min",
                           isSelected: preset == .balanced, action: {}) {
                    PresetTimeline(cadence: preset.cadence!, isSelected: preset == .balanced)
                        .padding(.top, 6)
                }
                .frame(width: 180)
            }
        }
    }
}
