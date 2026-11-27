import BreakpointCore
import Foundation

// WinSDK also declares `UUID` (a GUID) and the runtime re-exports Core's `Settings`; a declaration
// in this module wins over imported ones, so inside BreakpointWindows these names are unambiguous.
public typealias UUID = Foundation.UUID
public typealias Settings = BreakpointCore.Settings
