// swift-tools-version: 5.10
// Breakpoint: break reminders that wait for your agent.
// See docs/SPEC.md (behaviour) and CLAUDE.md (how to build and test).

import PackageDescription

let package = Package(
    name: "Breakpoint",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BreakpointCore", targets: ["BreakpointCore"]),
        .library(name: "BreakpointKit", targets: ["BreakpointKit"]),
        .executable(name: "BreakpointApp", targets: ["BreakpointApp"]),
        .executable(name: "breakpoint", targets: ["breakpoint-cli"]),
        .executable(name: "BreakpointSnapshots", targets: ["BreakpointSnapshots"]),
    ],
    targets: [
        // Foundation only. No AppKit, no SwiftUI, no system calls except files and sockets.
        .target(
            name: "BreakpointCore",
            path: "Sources/BreakpointCore"
        ),
        // AppKit + SwiftUI: design system, every window and view, system services.
        .target(
            name: "BreakpointKit",
            dependencies: ["BreakpointCore"],
            path: "Sources/BreakpointKit"
        ),
        // The menu-bar app. The bundle script renames the binary to "Breakpoint".
        .executableTarget(
            name: "BreakpointApp",
            dependencies: ["BreakpointCore", "BreakpointKit"],
            path: "Sources/BreakpointApp"
        ),
        // The `breakpoint` command-line tool used by agent hooks. Core only, so it stays small and fast.
        .executableTarget(
            name: "breakpoint-cli",
            dependencies: ["BreakpointCore"],
            path: "Sources/breakpoint-cli"
        ),
        // Renders registered views to build/snapshots/*.png for visual review. Never shipped.
        .executableTarget(
            name: "BreakpointSnapshots",
            dependencies: ["BreakpointCore", "BreakpointKit"],
            path: "Sources/BreakpointSnapshots"
        ),
        .testTarget(
            name: "BreakpointCoreTests",
            dependencies: ["BreakpointCore"],
            path: "Tests/BreakpointCoreTests"
        ),
    ]
)
