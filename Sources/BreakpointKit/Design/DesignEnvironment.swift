import SwiftUI
import BreakpointRuntime

/// How glass surfaces render.
public enum GlassRendering: Sendable {
    /// `NSVisualEffectView` behind-window blur (the real app).
    case live
    /// An opaque approximation: for snapshots (ImageRenderer cannot render materials) and wherever
    /// a blur is not available.
    case opaque
    /// A blurred copy of a drawn desktop from the enclosing `GlassStage`, so pictures show the
    /// glass over real-looking content (snapshots and films only; never set in the app).
    case simulated
}

/// Accessibility settings that can be forced, for snapshots and previews. `nil` means "follow the
/// system". SwiftUI's own accessibility environment values are read-only, so components read
/// these through `DesignTraits`.
public struct DesignOverrides: Sendable, Equatable {
    public var reduceMotion: Bool?
    public var reduceTransparency: Bool?
    public var increaseContrast: Bool?
    /// Render continuous animations (pulses, aurora, breathing) at a fixed rest frame, so
    /// snapshots are reproducible. Never set in the app.
    public var freezeContinuousAnimations: Bool

    public init(reduceMotion: Bool? = nil, reduceTransparency: Bool? = nil, increaseContrast: Bool? = nil,
                freezeContinuousAnimations: Bool = false) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.freezeContinuousAnimations = freezeContinuousAnimations
    }

    public static let none = DesignOverrides()
}

private struct GlassRenderingKey: EnvironmentKey {
    static let defaultValue: GlassRendering = .live
}

private struct DesignOverridesKey: EnvironmentKey {
    static let defaultValue: DesignOverrides = .none
}

extension EnvironmentValues {
    /// `.live` in the app; `.opaque` in snapshots.
    public var glassRendering: GlassRendering {
        get { self[GlassRenderingKey.self] }
        set { self[GlassRenderingKey.self] = newValue }
    }

    public var designOverrides: DesignOverrides {
        get { self[DesignOverridesKey.self] }
        set { self[DesignOverridesKey.self] = newValue }
    }
}

extension View {
    /// Forces glass rendering (snapshots use `.opaque`).
    public func glassRendering(_ rendering: GlassRendering) -> some View {
        environment(\.glassRendering, rendering)
    }

    /// Forces accessibility settings for this subtree (snapshots and previews).
    public func designOverrides(_ overrides: DesignOverrides) -> some View {
        environment(\.designOverrides, overrides)
    }
}

/// The effective accessibility traits for a component: the system values unless overridden.
/// Use as `private let traits = DesignTraits()` inside any `View`.
public struct DesignTraits: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.designOverrides) private var overrides
    @Environment(\.glassRendering) private var rendering

    public init() {}

    public var reduceMotion: Bool { overrides.reduceMotion ?? systemReduceMotion }
    public var reduceTransparency: Bool { overrides.reduceTransparency ?? systemReduceTransparency }
    public var increaseContrast: Bool { overrides.increaseContrast ?? (systemContrast == .increased) }
    public var glassRendering: GlassRendering { rendering }
    /// Continuous animations (pulse, aurora, breathing) should run: false under Reduce Motion and
    /// in snapshots.
    public var runsContinuousAnimations: Bool { !reduceMotion && !overrides.freezeContinuousAnimations }

    /// Hint text opacity: 50%, or 60% with Increase Contrast (§4.8).
    public var hintOpacity: Double { increaseContrast ? 0.60 : Theme.TextStep.hint.opacity }
    /// Secondary text opacity: 60%, or 75% with Increase Contrast.
    public var secondaryOpacity: Double { increaseContrast ? 0.75 : Theme.TextStep.secondary.opacity }
    /// Outline opacity for secondary buttons: 14%, or 30% with Increase Contrast.
    public var outlineOpacity: Double { increaseContrast ? 0.30 : Theme.TextStep.outline.opacity }

    /// `Theme.Motion.animation` with this component's Reduce Motion setting.
    public func animation(_ moment: Theme.Motion.Moment) -> Animation {
        Theme.Motion.animation(moment, reduceMotion: reduceMotion)
    }
}
