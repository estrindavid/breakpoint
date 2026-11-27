import BreakpointCore

/// SwiftUI declares a `Settings` scene type, which makes `Settings` ambiguous in any file that
/// imports both SwiftUI and BreakpointCore. A declaration in this module wins over imported ones,
/// so inside BreakpointKit `Settings` always means Breakpoint's settings struct.
public typealias Settings = BreakpointCore.Settings
