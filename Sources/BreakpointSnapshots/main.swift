import AppKit
import SwiftUI
import BreakpointCore
import BreakpointKit

// Usage:
//   BreakpointSnapshots [FILTER ...] [--out DIR] [--list]
//   BreakpointSnapshots --app-icon ICONSET_DIR
//   BreakpointSnapshots --window-probe DIR   (capsule controls in a real off-screen window; WindowProbe.swift)
//   BreakpointSnapshots --motion-film|--motion-still|--motion-strip …   (pop-up motion; MotionFilm.swift)
//   BreakpointSnapshots --glass-film LABEL | --glass-still LABEL SECONDS OUT.png (GlassSnapshots.swift)
//   BreakpointSnapshots --controls-film|--controls-still …
//     (buttons under a pointer, frame by frame; see ControlsFilm.swift)
//   BreakpointSnapshots --rim-film|--rim-still …   (the cards' time rim frame by frame; CardRimFilm.swift)
//   BreakpointSnapshots --overlay-film NAME|list [--at SECONDS --png FILE]   (OverlayFilm.swift)
//   BreakpointSnapshots --tour-film | --tour-still SECONDS OUT.png | --tour-strip DIR   (TourFilm.swift)
// FILTERs are substrings matched against snapshot names ("design/", "nudge"); with none, all render.
// Prints each file written. Exits non-zero on any failure.

@MainActor
func registry() -> [Snapshot] {
    DesignSnapshots.all
        + BreakSnapshots.all
        + MenuBarSnapshots.all
        + SettingsSnapshots.all
        + OnboardingSnapshots.all
        + GlassSnapshots.all
        + TourSnapshots.all
        + HintSnapshots.all
}

@MainActor
func run() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    var outDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/snapshots", isDirectory: true)
    var listOnly = false

    if let status = MotionFilm.run(args) { return status }
    if let status = TourFilm.run(args) { return status }

    if let i = args.firstIndex(of: "--app-icon") {
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("--app-icon needs a .iconset directory\n".utf8))
            return 2
        }
        do {
            for url in try AppIconRendering.writeIconset(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) {
                print(url.path)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("app icon: \(error)\n".utf8))
            return 1
        }
    }
    if let status = GlassFilm.run(args) { return status }
    if let status = ControlsFilm.run(args) { return status }
    if let status = CardRimFilm.run(args) { return status }
    if let i = args.firstIndex(of: "--overlay-film") {
        return OverlayFilm.run(Array(args[(i + 1)...]))
    }
    if let i = args.firstIndex(of: "--window-probe") {
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("--window-probe needs a directory\n".utf8))
            return 2
        }
        return WindowProbe.run(into: URL(fileURLWithPath: args[i + 1], isDirectory: true))
    }
    if let i = args.firstIndex(of: "--out") {
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("--out needs a directory\n".utf8))
            return 2
        }
        outDirectory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        args.removeSubrange(i...(i + 1))
    }
    if let i = args.firstIndex(of: "--list") {
        listOnly = true
        args.remove(at: i)
    }
    let filters = args

    let all = registry()
    var seen = Set<String>()
    for snapshot in all where !seen.insert(snapshot.name).inserted {
        FileHandle.standardError.write(Data("duplicate snapshot name: \(snapshot.name)\n".utf8))
        return 1
    }
    let selected = filters.isEmpty ? all : all.filter { s in filters.contains { s.name.localizedCaseInsensitiveContains($0) } }
    if selected.isEmpty {
        FileHandle.standardError.write(Data("no snapshot matches \(filters.joined(separator: " "))\n".utf8))
        return 1
    }
    if listOnly {
        selected.forEach { print($0.name) }
        return 0
    }

    var failures = 0
    for snapshot in selected {
        do {
            for url in try SnapshotRenderingEngine.render(snapshot, into: outDirectory) {
                print(url.path)
            }
        } catch {
            failures += 1
            FileHandle.standardError.write(Data("\(snapshot.name): \(error)\n".utf8))
        }
    }
    return failures == 0 ? 0 : 1
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let status = MainActor.assumeIsolated { run() }
exit(status)
