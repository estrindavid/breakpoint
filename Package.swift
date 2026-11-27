// swift-tools-version: 5.10
// Breakpoint: break reminders that wait for your agent.
// See docs/SPEC.md (behaviour) and CLAUDE.md (how to build and test).
//
// One package, two apps. BreakpointCore (the engine, integrations, wire format, updates), the
// `breakpoint` CLI and the unit tests are shared by macOS and Windows. Each platform adds its own
// shell around them:
//
//   macOS    BreakpointKit (AppKit + SwiftUI) · BreakpointApp · BreakpointSnapshots
//   Windows  BreakpointWindows (Win32 + Direct2D/DirectWrite) · BreakpointWinApp
//
// The shared app logic (the coordinator, `AppState`, `AppActions`) lives in BreakpointRuntime, so
// both apps run the same engine loop, decisions and debug harness.

import PackageDescription

let sharedProducts: [Product] = [
    .library(name: "BreakpointCore", targets: ["BreakpointCore"]),
    .library(name: "BreakpointRuntime", targets: ["BreakpointRuntime"]),
    .executable(name: "breakpoint", targets: ["breakpoint-cli"]),
]

let sharedTargets: [Target] = [
    // Foundation only. No AppKit, no SwiftUI, no system calls except files, sockets and the few
    // per-platform ones in Platform/ and Updates/AppBundle.swift.
    .target(
        name: "BreakpointCore",
        path: "Sources/BreakpointCore"
    ),
    // The app's brain, shared by both apps: AppState, AppActions, the coordinator and its engine
    // loop, the debug harness. Foundation only; each app passes in its platform's services.
    .target(
        name: "BreakpointRuntime",
        dependencies: ["BreakpointCore"],
        path: "Sources/BreakpointRuntime"
    ),
    // The `breakpoint` command-line tool used by agent hooks. Core only, so it stays small and fast.
    .executableTarget(
        name: "breakpoint-cli",
        dependencies: ["BreakpointCore"],
        path: "Sources/breakpoint-cli"
    ),
    .testTarget(
        name: "BreakpointCoreTests",
        dependencies: ["BreakpointCore"],
        path: "Tests/BreakpointCoreTests"
    ),
]

#if os(Windows)
let platformProducts: [Product] = [
    .library(name: "BreakpointWindows", targets: ["BreakpointWindows"]),
    .executable(name: "BreakpointApp", targets: ["BreakpointWinApp"]),
]
let platformTargets: [Target] = [
    // Direct2D, DirectWrite and Direct3D 11 behind a small C API (their headers are C++ COM).
    .target(
        name: "CBreakpointGraphics",
        path: "Sources/CBreakpointGraphics",
        cxxSettings: [.unsafeFlags(["-std=c++17"])],
        linkerSettings: [
            .linkedLibrary("d2d1"), .linkedLibrary("dwrite"), .linkedLibrary("d3d11"), .linkedLibrary("dxgi"),
            .linkedLibrary("dcomp"), .linkedLibrary("windowscodecs"),
        ]
    ),
    // Win32: the tray icon, every window and pop-up, the design system, system services.
    .target(
        name: "BreakpointWindows",
        dependencies: ["BreakpointCore", "BreakpointRuntime", "CBreakpointGraphics"],
        path: "Sources/BreakpointWindows",
        linkerSettings: [
            .linkedLibrary("user32"), .linkedLibrary("gdi32"), .linkedLibrary("shell32"), .linkedLibrary("ole32"),
            .linkedLibrary("advapi32"), .linkedLibrary("winmm"), .linkedLibrary("dwmapi"), .linkedLibrary("shcore"),
            .linkedLibrary("wtsapi32"), .linkedLibrary("powrprof"), .linkedLibrary("uxtheme"), .linkedLibrary("comdlg32"),
        ]
    ),
    // The tray app. The release script names the executable Breakpoint.exe.
    .executableTarget(
        name: "BreakpointWinApp",
        dependencies: ["BreakpointCore", "BreakpointRuntime", "BreakpointWindows"],
        path: "Sources/BreakpointWinApp",
        linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"])]
    ),
]
#else
let platformProducts: [Product] = [
    .library(name: "BreakpointKit", targets: ["BreakpointKit"]),
    .executable(name: "BreakpointApp", targets: ["BreakpointApp"]),
    .executable(name: "BreakpointSnapshots", targets: ["BreakpointSnapshots"]),
]
let platformTargets: [Target] = [
    // AppKit + SwiftUI: design system, every window and view, system services.
    .target(
        name: "BreakpointKit",
        dependencies: ["BreakpointCore", "BreakpointRuntime"],
        path: "Sources/BreakpointKit"
    ),
    // The menu-bar app. The bundle script renames the binary to "Breakpoint".
    .executableTarget(
        name: "BreakpointApp",
        dependencies: ["BreakpointCore", "BreakpointRuntime", "BreakpointKit"],
        path: "Sources/BreakpointApp"
    ),
    // Renders registered views to build/snapshots/*.png for visual review. Never shipped.
    .executableTarget(
        name: "BreakpointSnapshots",
        dependencies: ["BreakpointCore", "BreakpointRuntime", "BreakpointKit"],
        path: "Sources/BreakpointSnapshots"
    ),
]
#endif

let package = Package(
    name: "Breakpoint",
    platforms: [.macOS(.v14)],
    products: sharedProducts + platformProducts,
    targets: sharedTargets + platformTargets
)
