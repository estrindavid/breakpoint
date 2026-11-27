import BreakpointRuntime
import Foundation

/// The design system on Windows (SPEC §4): the same palette, steps, sizes and durations as the
/// macOS `Theme` (Sources/BreakpointKit/Design/Theme.swift), so both apps look like one product.
/// Type maps SF Pro to Segoe UI Variable (Text for body sizes, Display for titles and numbers).
public enum Theme {
    public enum Palette {
        public static let mint = Colour(hex: 0x3DD6B0)
        /// Mint for light surfaces (Settings and Onboarding in light mode).
        public static let mintLight = Colour(hex: 0x12A688)
        public static let onMint = Colour(hex: 0x04140F)
        public static let indigo = Colour(hex: 0x6C7CFF)
        public static let amber = Colour(hex: 0xFFB454)
        public static let onAccent = Colour(hex: 0x0B0F17)
        public static let scrim = Colour(hex: 0x070A12)
        public static let solidPopup = Colour(hex: 0x151A22)
        public static let solidOverlay = Colour(hex: 0x0B0F17)
        public static let glassApproximation = Colour(hex: 0x1E232C)
        /// Settings' sidebar tiles, mint → indigo.
        public static let sidebarRamp: [Colour] = [
            Colour(hex: 0x2FC9A4), Colour(hex: 0x27B9AE), Colour(hex: 0x26A8B8), Colour(hex: 0x2E97C4),
            Colour(hex: 0x3C88D2), Colour(hex: 0x4C7CE0), Colour(hex: 0x5B76EE), Colour(hex: 0x6C7CFF),
        ]

        public static func white(_ step: TextStep) -> Colour { Colour.white.opacity(step.opacity) }
        public static func accent(dark: Bool) -> Colour { dark ? mint : mintLight }

        public static func solid(for tone: Tone) -> Colour {
            switch tone {
            case .brand, .mint: return mint
            case .agent: return indigo
            case .needsYou: return amber
            case .neutral: return Colour.white.opacity(0.6)
            }
        }
    }

    /// The colour roles, shared with the coordinator and the macOS app (`BreakpointRuntime.Tone`).
    public typealias Tone = BreakpointRuntime.Tone

    public enum TextStep: Sendable {
        case title, body, label, secondary, hint, hairline, outline, fill

        public var opacity: Float {
            switch self {
            case .title: return 1
            case .body: return 0.85
            case .label: return 0.75
            case .secondary: return 0.60
            case .hint: return Appearance.highContrast ? 0.60 : 0.50
            case .hairline: return 0.25
            case .outline: return 0.14
            case .fill: return 0.10
            }
        }
    }

    public enum Typography {
        public static func overlayTitle(displayWidth: Float) -> TextStyle {
            TextStyle(size: min(max(34, displayWidth * 0.033), 56), weight: 700, align: .center)
        }
        public static let overlayInstruction = TextStyle(size: 19, weight: 400, align: .center, wrap: true)
        public static let timer = TextStyle(size: 38, weight: 600, monospacedDigits: true, align: .center)
        public static let breatheWord = TextStyle(size: 22, weight: 500, align: .center)
        public static let nudgeTitle = TextStyle(size: 20, weight: 600)
        public static let nudgeSubtitle = TextStyle(size: 15, weight: 400)
        public static let button = TextStyle(size: 15, weight: 600, align: .center)
        public static let smallButton = TextStyle(size: 13, weight: 600, align: .center)
        public static let agentChip = TextStyle(size: 13, weight: 600)
        public static let cueChip = TextStyle(size: 12, weight: 600, align: .center)
        public static let smallChip = TextStyle(size: 11, weight: 600, align: .center)
        public static let popoverNumber = TextStyle(size: 38, weight: 700, monospacedDigits: true)
        public static let totalsNumber = TextStyle(size: 30, weight: 700, monospacedDigits: true)
        public static let totalsUnit = TextStyle(size: 15, weight: 600)
        public static let caption = TextStyle(size: 13)
        public static let captionWrapped = TextStyle(size: 13, wrap: true)
        public static let body = TextStyle(size: 13)
        public static let bodyWrapped = TextStyle(size: 13, wrap: true)
        public static let bodySemibold = TextStyle(size: 13, weight: 600)
        public static let detail = TextStyle(size: 12)
        public static let detailWrapped = TextStyle(size: 12, wrap: true)
        public static let windDownTitle = TextStyle(size: 17, weight: 600)
        public static let paneTitle = TextStyle(size: 17, weight: 600)
        public static let sectionTitle = TextStyle(size: 13, weight: 700)
        public static let row = TextStyle(size: 13)
        public static let rowDescription = TextStyle(size: 11, wrap: true)
        public static let hint = TextStyle(size: 11, wrap: true)
        public static let coach = TextStyle(size: 13, wrap: true)
        public static let coachTitle = TextStyle(size: 13, weight: 600)
        public static let overlayCoach = TextStyle(size: 16, align: .center, wrap: true)
        public static let keycap = TextStyle(size: 11, weight: 500, align: .center)
        public static let note = TextStyle(size: 12, wrap: true, family: "Cascadia Mono")
        public static let onboardingHero = TextStyle(size: 28, weight: 700, align: .center, wrap: true)
        public static let onboardingTitle = TextStyle(size: 24, weight: 700, wrap: true)
        public static let onboardingLead = TextStyle(size: 15, wrap: true)
        public static let onboardingSentence = TextStyle(size: 13, wrap: true)
        public static let smallNumber = TextStyle(size: 13, weight: 600, monospacedDigits: true)
    }

    public enum Spacing {
        public static let xxs: Float = 4
        public static let xs: Float = 8
        public static let s: Float = 12
        public static let m: Float = 16
        public static let l: Float = 24
        public static let xl: Float = 32
        public static let xxl: Float = 48
    }

    public enum Radius {
        /// Pop-ups. Windows 11 rounds top-level windows itself (8 DIPs); content inside uses these.
        public static let card: Float = 8
        public static let insetCard: Float = 8
        public static let button: Float = 6
        public static let chip: Float = 12
        public static let settingsSection: Float = 8
        public static let sidebarTile: Float = 5
        public static let sourceTile: Float = 6
        public static let keycap: Float = 4
        public static let coach: Float = 8
    }

    public enum Size {
        public static let popupTopGap: Float = 8
        public static let popupSideInset: Float = 16
        public static let popupStackGap: Float = 8
        public static let popupMaxStack = 2
        public static let nudgeSize = SizeF(width: 410, height: 122)
        public static let cardPadding: Float = 14
        public static let badge: Float = 44
        public static let badgeSymbol: Float = 20
        public static let badgeToText: Float = 12
        public static let rowGap: Float = 12
        public static let buttonHeight: Float = 34
        public static let smallButtonHeight: Float = 28
        public static let buttonPadding: Float = 14
        public static let buttonGap: Float = 9
        public static let closeButton: Float = 16
        public static let countdownChipHeight: Float = 32
        public static let countdownChipBadge: Float = 22
        public static let resumeCardWidth: Float = 360
        public static let sourceBadge: Float = 28
        public static let windDownWidth: Float = 410
        public static let windDownPadding: Float = 20
        public static let overlayColumnMaxWidth: Float = 640
        public static let overlayOpticalCentre: Float = 0.44
        public static let overlayChipTop: Float = 40
        public static let agentChipHeight: Float = 28
        public static let agentChipDot: Float = 8
        public static let titleToInstructionBaseline: Float = 58
        public static let instructionToHairline: Float = 44
        public static let hairlineWidth: Float = 160
        public static let hairlineToTimerCentre: Float = 66
        public static let controlsCentreFromBottom: Float = 96
        public static let overlayControlGap: Float = 12
        public static let moveRing: Float = 140
        public static let moveRingStroke: Float = 4
        public static let stepDot: Float = 6
        public static let stepDotGap: Float = 8
        public static let walkRing: Float = 160
        public static let walkRingStroke: Float = 3
        public static let breatheRing: Float = 220
        public static let breatheRingStroke: Float = 3
        public static let breatheMinScale: Float = 0.72
        public static let popoverWidth: Float = 340
        public static let settingsSize = SizeF(width: 760, height: 560)
        public static let onboardingSize = SizeF(width: 620, height: 520)
    }

    /// Durations (SPEC §4.6), in seconds.
    public enum Duration {
        public static let fast: Double = 0.15
        public static let standard: Double = 0.24
        public static let slow: Double = 0.4
        public static let overlayFade: Double = 0.6
    }
}
