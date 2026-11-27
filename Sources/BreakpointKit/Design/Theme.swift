import SwiftUI
import BreakpointCore
import BreakpointRuntime

/// Breakpoint's design tokens (SPEC §4). Every colour, size, radius and duration a screen uses
/// comes from here, so screens built in parallel look like one app.
///
/// Surfaces come in two families:
/// - **Pop-ups and the overlay** are always dark (`.environment(\.colorScheme, .dark)`); they use
///   `Theme.Colors.white(_:)` text steps on glass.
/// - **Windows** (Settings, Onboarding) follow the system appearance and use system label colours
///   (`Color.primary`, `.secondary`) and `Theme.Colors.accent(for:)`.
public enum Theme {
    // MARK: - Colour (§4.2)

    public enum Colors {
        /// Accent mint on dark surfaces and in dark mode.
        public static let mint = Color(hex: 0x3DD6B0)
        /// Accent mint in light mode (darker for contrast on white).
        public static let mintLight = Color(hex: 0x12A688)
        /// Text on a mint fill.
        public static let onMint = Color(hex: 0x04140F)
        /// Agent activity only.
        public static let indigo = Color(hex: 0x6C7CFF)
        /// "Needs you" only.
        public static let amber = Color(hex: 0xFFB454)
        /// Text on amber or indigo fills.
        public static let onAccent = Color(hex: 0x0B0F17)
        /// Overlay scrim (60%, 75% with Increase Contrast).
        public static let scrim = Color(hex: 0x070A12)
        /// Pop-up fill under Reduce Transparency.
        public static let solidPopup = Color(hex: 0x151A22)
        /// Overlay fill under Reduce Transparency.
        public static let solidOverlay = Color(hex: 0x0B0F17)
        /// Snapshot-safe approximation of the live pop-up glass (HUD material + 12% black tint
        /// over a typical desktop). Used only when glass rendering is `.opaque`.
        public static let glassApproximation = Color(hex: 0x1E232C)
        /// Settings sidebar tile ramp (mint → teal → indigo), top to bottom.
        public static let sidebarRamp: [Color] = [
            Color(hex: 0x2FC9A4), Color(hex: 0x27B9AE), Color(hex: 0x26A8B8), Color(hex: 0x2E97C4),
            Color(hex: 0x3C88D2), Color(hex: 0x4C7CE0), Color(hex: 0x5B76EE), Color(hex: 0x6C7CFF),
        ]

        /// The accent for a window following the system appearance.
        public static func accent(for scheme: ColorScheme) -> Color { scheme == .dark ? mint : mintLight }

        /// White at one of the neutral steps for dark surfaces.
        public static func white(_ step: TextStep) -> Color { Color.white.opacity(step.opacity) }

        /// The Breakpoint gradient, mint → indigo at 135° (top-leading → bottom-trailing).
        public static let brandGradient = LinearGradient(
            colors: [mint, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)

        /// The badge colour for a tone (single colour moment per pop-up, §3.0).
        public static func fill(for tone: Tone) -> AnyShapeStyle {
            switch tone {
            case .brand: return AnyShapeStyle(brandGradient)
            case .agent: return AnyShapeStyle(indigo)
            case .needsYou: return AnyShapeStyle(amber)
            case .mint: return AnyShapeStyle(mint)
            case .neutral: return AnyShapeStyle(Color.white.opacity(0.14))
            }
        }

        /// The solid colour for a tone (dots, chips).
        public static func solid(for tone: Tone) -> Color {
            switch tone {
            case .brand, .mint: return mint
            case .agent: return indigo
            case .needsYou: return amber
            case .neutral: return Color.white.opacity(0.6)
            }
        }
    }

    /// The colour role of a badge, dot or chip (declared in BreakpointRuntime, where `AppState` uses it).
    public typealias Tone = BreakpointRuntime.Tone

    /// Neutral text and line steps on dark surfaces (§4.2). 50% is the lowest step allowed for text.
    public enum TextStep: Sendable {
        /// 100%: titles.
        case title
        /// 85%: body.
        case body
        /// 75%: button labels.
        case label
        /// 60%: secondary text, timers.
        case secondary
        /// 50%: hints (60% under Increase Contrast).
        case hint
        /// 25%: hairlines.
        case hairline
        /// 14%: outlines.
        case outline
        /// 10%: fills.
        case fill

        public var opacity: Double {
            switch self {
            case .title: return 1
            case .body: return 0.85
            case .label: return 0.75
            case .secondary: return 0.60
            case .hint: return 0.50
            case .hairline: return 0.25
            case .outline: return 0.14
            case .fill: return 0.10
            }
        }
    }

    // MARK: - Type (§4.3)

    /// The type scale. SF Pro Rounded for titles and every number; SF Pro Text for body.
    /// Every countdown also needs `.monospacedDigit()` and a numeric-text transition
    /// (`RollingNumber` does both).
    public enum Typography {
        /// Overlay title: rounded bold, clamp(34, 3.3% of display width, 56).
        public static func overlayTitle(displayWidth: CGFloat) -> Font {
            .system(size: overlayTitleSize(displayWidth: displayWidth), weight: .bold, design: .rounded)
        }
        public static func overlayTitleSize(displayWidth: CGFloat) -> CGFloat {
            min(max(34, displayWidth * 0.033), 56)
        }
        public static let overlayInstruction = Font.system(size: 19, weight: .regular)
        /// Overlay and ring timers: rounded semibold 38 (always add `.monospacedDigit()`).
        public static let timer = Font.system(size: 38, weight: .semibold, design: .rounded)
        public static let breatheWord = Font.system(size: 22, weight: .medium, design: .rounded)
        public static let nudgeTitle = Font.system(size: 20, weight: .semibold)
        public static let nudgeSubtitle = Font.system(size: 15, weight: .regular)
        /// Pop-up and overlay buttons.
        public static let button = Font.system(size: 15, weight: .semibold)
        /// Small card buttons (resume card, away note, wind-down, popover).
        public static let smallButton = Font.system(size: 13, weight: .semibold)
        public static let agentChip = Font.system(size: 13, weight: .semibold)
        /// Cue chip on `move`.
        public static let cueChip = Font.system(size: 12, weight: .semibold)
        /// State chips in rows (popover agents: "working", "needs you", "idle").
        public static let smallChip = Font.system(size: 11, weight: .semibold)
        public static let popoverNumber = Font.system(size: 38, weight: .bold, design: .rounded)
        /// The popover's three totals ("74 min", "26", "61") and their units.
        public static let totalsNumber = Font.system(size: 30, weight: .bold, design: .rounded)
        public static let totalsUnit = Font.system(size: 15, weight: .semibold, design: .rounded)
        public static let caption = Font.system(size: 13, weight: .regular)
        public static let body = Font.system(size: 13, weight: .regular)
        public static let bodySemibold = Font.system(size: 13, weight: .semibold)
        /// Resume card row 2 and 3, popover "since you moved".
        public static let detail = Font.system(size: 12, weight: .regular)
        public static let windDownTitle = Font.system(size: 17, weight: .semibold, design: .rounded)
        public static let paneTitle = Font.system(size: 17, weight: .semibold)
        public static let sectionTitle = Font.system(size: 13, weight: .bold)
        public static let row = Font.system(size: 13, weight: .regular)
        public static let rowDescription = Font.system(size: 11, weight: .regular)
        /// Hints and footers.
        public static let hint = Font.system(size: 11, weight: .regular)
        /// Coach lines and first-use hints on pop-ups (SPEC §3.12): one voice for both.
        public static let coach = Font.system(size: 13, weight: .regular)
        public static let coachTitle = Font.system(size: 13, weight: .semibold)
        /// Coach lines and the first-break hint on the break screen, read from a step back.
        public static let overlayCoach = Font.system(size: 16, weight: .regular)
        /// Keycap labels.
        public static let keycap = Font.system(size: 11, weight: .medium)
        /// Wind-down "Where you left off" note.
        public static let note = Font.system(size: 12, weight: .regular, design: .monospaced)
        /// Onboarding: the Welcome headline, every other page's title, the Welcome sentence and
        /// the one-sentence lead under each title (windows; system colours).
        public static let onboardingHero = Font.system(size: 28, weight: .bold, design: .rounded)
        public static let onboardingTitle = Font.system(size: 24, weight: .bold, design: .rounded)
        public static let onboardingLead = Font.system(size: 15, weight: .regular)
        public static let onboardingSentence = Font.system(size: 13, weight: .regular)
        /// Small numbers (overall time left on `move`, other displays' timer).
        public static let smallNumber = Font.system(size: 13, weight: .semibold, design: .rounded)
    }

    // MARK: - Spacing (§4.4)

    /// New spacing uses only these steps; measured values from the spec live in `Layout`.
    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 48
    }

    // MARK: - Radii (§4.4)

    public enum Radius {
        /// Pop-up cards (nudge, resume card, wind-down).
        public static let card: CGFloat = 28
        /// Countdown chip.
        public static let countdownChip: CGFloat = 16
        /// Popover inset cards.
        public static let insetCard: CGFloat = 14
        /// Settings grouped sections (System Settings style; not specified in SPEC §4.4).
        public static let settingsSection: CGFloat = 10
        /// Settings sidebar icon tiles.
        public static let sidebarTile: CGFloat = 5
        /// Agent source tiles in the popover (20 pt rounded squares).
        public static let sourceTile: CGFloat = 6
        /// Keycaps.
        public static let keycap: CGFloat = 4
        /// The tour's coach cards (SPEC §3.12): smaller than a pop-up card, so they read as notes
        /// on the surfaces they explain.
        public static let coach: CGFloat = 20
    }

    // MARK: - Measured layout values (§3)

    /// Sizes from SPEC §3, used as given.
    public enum Layout {
        // Pop-ups (§3.0, §3.1)
        public static let popupTopGap: CGFloat = 8
        public static let popupSideInset: CGFloat = 16
        public static let popupStackGap: CGFloat = 8
        public static let popupMaxStack = 2
        public static let nudgeSize = CGSize(width: 410, height: 122)
        public static let cardPadding: CGFloat = 14
        public static let badge: CGFloat = 44
        public static let badgeSymbol: CGFloat = 20
        public static let badgeToText: CGFloat = 12
        public static let rowGap: CGFloat = 12
        public static let buttonHeight: CGFloat = 34
        public static let smallButtonHeight: CGFloat = 28
        public static let buttonPadding: CGFloat = 14
        public static let buttonGap: CGFloat = 9
        public static let closeButton: CGFloat = 16
        // Countdown chip (§3.2)
        public static let countdownChipHeight: CGFloat = 32
        public static let countdownChipBadge: CGFloat = 22
        public static let countdownChipPointerOffset: CGFloat = 20
        // Resume card, away note, toast (§3.5)
        public static let resumeCardWidth: CGFloat = 360
        public static let sourceBadge: CGFloat = 28
        public static let capsuleHeight: CGFloat = 44
        public static let capsuleBadge: CGFloat = 32
        public static let capsuleBadgeInset: CGFloat = 6
        // Wind-down (§3.6)
        public static let windDownWidth: CGFloat = 410
        public static let windDownPadding: CGFloat = 20
        // Overlay (§3.3, §3.4)
        public static let overlayColumnMaxWidth: CGFloat = 640
        public static let overlayOpticalCentre: CGFloat = 0.44
        public static let overlayChipTop: CGFloat = 40
        public static let agentChipHeight: CGFloat = 28
        public static let agentChipDot: CGFloat = 8
        /// The coach family's mark (SPEC §3.12): the mint target that ends a coach line's pointer
        /// and leads a first-use hint.
        public static let coachDot: CGFloat = 9
        /// A coach line or hint on the break screen: capsule height and the gap under the chip.
        public static let overlayCoachHeight: CGFloat = 36
        public static let overlayCoachGap: CGFloat = 6
        public static let titleToInstructionBaseline: CGFloat = 58
        public static let kindLineGap: CGFloat = 16
        public static let instructionToHairline: CGFloat = 44
        public static let hairlineWidth: CGFloat = 160
        public static let hairlineToTimerCentre: CGFloat = 66
        public static let hairlineToRingTop: CGFloat = 32
        public static let controlsCentreFromBottom: CGFloat = 96
        public static let overlayControlGap: CGFloat = 12
        public static let hintGap: CGFloat = 12
        public static let skipGuardRing: CGFloat = 14
        public static let cueChipHeight: CGFloat = 24
        public static let smallChipHeight: CGFloat = 20
        public static let moveRing: CGFloat = 140
        public static let moveRingStroke: CGFloat = 4
        public static let stepDot: CGFloat = 6
        public static let stepDotGap: CGFloat = 8
        public static let walkRing: CGFloat = 160
        public static let walkRingStroke: CGFloat = 3
        public static let breatheRing: CGFloat = 220
        public static let breatheRingStroke: CGFloat = 3
        public static let breatheMinScale: CGFloat = 0.72
        /// `move` pacing: a one-phase repetition ("circle") shows an arc of this fraction of the
        /// ring travelling around it once per repetition.
        public static let paceTravelArc: CGFloat = 0.22
        /// The completion mark on `eyes` (which has no ring): 64 pt, the walk ring's 3 pt stroke.
        public static let completionMarkEyes: CGFloat = 64
        /// The check inside a completion mark: this fraction of the ring's diameter wide, its
        /// stroke this multiple of the ring's.
        public static let completionCheckWidth: CGFloat = 0.42
        public static let completionCheckStroke: CGFloat = 1.5
        // Menu bar and popover (§3.7, §3.8)
        public static let menuBarMark: CGFloat = 18
        public static let popoverWidth: CGFloat = 320
        public static let popoverRing: CGFloat = 44
        public static let agentRowHeight: CGFloat = 36
        public static let sourceTile: CGFloat = 20
        public static let popoverMaxAgentRows = 4
        /// The popover's totals: the moving figure's column (the other two share the rest), and
        /// the height of a figure's number line.
        public static let popoverTotalsMovingColumn: CGFloat = 114
        public static let popoverTotalsNumberHeight: CGFloat = 32
        // Settings (§3.9)
        public static let settingsDefaultSize = CGSize(width: 860, height: 770)
        public static let settingsMinimumSize = CGSize(width: 720, height: 560)
        public static let settingsSidebarWidth: CGFloat = 200
        public static let sidebarTile: CGFloat = 20
        public static let sectionGap: CGFloat = 24
        public static let settingRowMinHeight: CGFloat = 40
        public static let settingRowIcon: CGFloat = 24
        // Onboarding (§3.10)
        public static let onboardingSize = CGSize(width: 560, height: 460)
        public static let onboardingDemoScale: CGFloat = 0.6
    }

    // MARK: - Material (§4.5)

    public enum Glass {
        /// Black tint over the HUD material.
        public static let tint: Double = 0.12
        /// Inner rim, white: sides and bottom / top edge.
        public static let rim: Double = 0.10
        public static let rimTop: Double = 0.16
        /// Rim under Reduce Transparency.
        public static let rimSolid: Double = 0.12
        /// Rim under Increase Contrast.
        public static let rimIncreasedContrast: Double = 0.30
        /// Two shadows: (y 9, blur 18, black 14%) and (y 21, blur 48, black 24%).
        public static let shadows: [ShadowSpec] = [
            ShadowSpec(y: 9, blur: 18, opacity: 0.14),
            ShadowSpec(y: 21, blur: 48, opacity: 0.24),
        ]
        /// Room needed around a glass surface so its shadows are not clipped by its window.
        public static let shadowMargin = EdgeInsets(top: 32, leading: 48, bottom: 72, trailing: 48)
        /// macOS 26: black veil over the system Liquid Glass, for white text over bright desktops.
        public static let liquidVeil: Double = 0.18

        // Hand-built lighting (macOS 14 and 15, and every snapshot), `GlassLighting`.
        /// Width of the band inside the rim where the tint clears and gathered light shows.
        public static let edgeBand: CGFloat = 10
        /// The tint at the very rim, as a fraction of `tint` (the centre keeps all of it).
        public static let edgeTintFraction: Double = 0.35
        /// Gathered light inside the rim (added, so it takes the colour of what is behind):
        /// top edge / bottom edge.
        public static let edgeLightTop: Double = 0.10
        public static let edgeLightBottom: Double = 0.04
        /// Still sheen from the top-leading corner.
        public static let sheen: Double = 0.07
        /// Rim, where it catches the light: top-leading / bottom-trailing (sides keep `rim`).
        public static let rimHighlight: Double = 0.45
        public static let rimCounterHighlight: Double = 0.22
        /// The rim's light spread 3 pt inwards (soft), as a fraction of the rim.
        public static let glint: Double = 0.45
        /// 1 pt shade just inside the rim at the bottom: the far side of a thick edge.
        public static let innerShade: Double = 0.16

        /// Pictures only (`GlassRendering.simulated`): the blur and the veil of
        /// `Colors.glassApproximation` that stand in for the HUD material over a drawn desktop
        /// (the 12% black tint goes on top, as in the app).
        public static let simulatedBlur: CGFloat = 18
        public static let simulatedVeil: Double = 0.70
    }

    public struct ShadowSpec: Sendable {
        public var y: CGFloat
        public var blur: CGFloat
        public var opacity: Double
        /// SwiftUI's `radius` is about half the CSS-style blur.
        public var radius: CGFloat { blur / 2 }
    }

    /// Overlay backdrop (§3.3, §4.8). Its timing is `BackdropTimeline` (Core).
    public enum Backdrop {
        public static let scrimOpacity: Double = 0.60
        public static let scrimOpacityIncreasedContrast: Double = 0.75
        public static let scrimOpacityAmbient: Double = 0.85
        /// The aurora's lights are laid over the scrim in deep tones at this strength…
        public static let auroraDeepStrength: Double = 0.55
        /// …and added as light (plus-lighter) at this strength.
        public static let auroraStrength: Double = 0.12
        /// Reduce Transparency: the still aurora over the solid fill.
        public static let auroraReducedTransparencyOpacity: Double = 0.08
        /// The vignette: scrim colour at this opacity in the display's corners, none in the middle.
        public static let vignetteOpacity: Double = 0.45
        /// The vignette is clear out to this fraction of its radius.
        public static let vignetteClearRadius: Double = 0.35
        /// A soft extra scrim behind the column (scrim colour at this opacity in the middle,
        /// fading out by `hushRadius` of the display's width), so the light around it never costs
        /// the text contrast.
        public static let hushOpacity: Double = 0.22
        public static let hushRadius: Double = 0.42
        /// Fixed fine grain over the backdrop so its gradients never band (normal blend).
        public static let grainOpacity: Double = 0.035
        /// The grain tile, in pixels.
        public static let grainTile: Int = 128
        /// The aurora's colours: mint, teal (mint → indigo), indigo and a deep blue.
        public static let auroraTeal = Color(hex: 0x26A8B8)
        public static let auroraDeep = Color(hex: 0x2B3FB8)
        /// Deep versions of mint, teal, indigo and the deep blue (the aurora's first pass).
        public static let auroraDeepTones: [Color] = [
            Color(hex: 0x0A5A4C), Color(hex: 0x0B4A63), Color(hex: 0x232C82), Color(hex: 0x0E1A5C),
        ]
    }
}

extension Color {
    /// A colour from 0xRRGGBB.
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
