# Contributing to Breakpoint

Thanks for wanting to help. Breakpoint is a small native macOS app with a written specification
and a strict review. This page tells you how to build it, what a reviewer checks, and how a
change gets in.

## Set up

You need a Mac with Apple's Command Line Tools (`xcode-select --install`). Xcode is not needed,
and the project has no Xcode project file: it is a Swift package. The code uses the macOS 26 SDK
(behind availability checks; the app itself runs on macOS 14 or later), so use Command Line Tools
recent enough to include that SDK. We build with Swift 6.3. `scripts/e2e.sh` also needs `jq`,
which macOS 15 and later include as `/usr/bin/jq`.

There are no third-party dependencies, so there is nothing else to install.

```sh
git clone https://github.com/estrindavid/breakpoint.git
cd breakpoint
swift build                    # debug build of everything; about a minute the first time
```

## Build, test, look

| What | Command |
|---|---|
| Build (debug) | `swift build` |
| Unit tests (Swift Testing) | `scripts/test.sh` (extra arguments pass through, e.g. `scripts/test.sh --filter Wire`) |
| End-to-end flows | `scripts/e2e.sh` (add `-v` to print an app trace when a check fails, or flow names to run only some) |
| Pictures of every screen | `scripts/snapshots.sh` → `build/snapshots/**.png`; `scripts/snapshots.sh nudge overlay` renders only matching names, `--list` lists them |
| The app bundle | `scripts/build-app.sh` → `build/Breakpoint.app` (a release build) |

Use `scripts/test.sh`, not plain `swift test`: with only the Command Line Tools installed,
`swift test` cannot find the Testing framework, and the script adds the paths it needs.

`scripts/e2e.sh` runs the whole debug app with nothing on screen (`--debug-headless`), with
simulated input, calls and clock (`--debug-simulate`), each flow in a fresh temporary home folder,
and drives it through the real `breakpoint` command-line tool. It never touches your real
settings. [CLAUDE.md](CLAUDE.md), "Testing the whole app", explains the harness and its commands.

**Keep your own setup safe.** When you run the app or the CLI by hand, set
`BREAKPOINT_HOME` to a stand-in folder so that nothing reads or writes your real home:

```sh
export BREAKPOINT_HOME="$(mktemp -d -t bp)"
.build/debug/BreakpointApp --debug-headless --debug-simulate --debug-trace &
.build/debug/breakpoint debug help
```

With `BREAKPOINT_HOME` set, the app's data folder, `~/.breakpoint` and every coding tool's config
file move under that folder, and the login item is never registered.

## Windows

The same package builds the Windows app (`Breakpoint.exe`, Win32 and Direct2D) and the same CLI.
The engine, the coordinator, the CLI and the tests are shared; only the windows and the system
services are per platform. [docs/WINDOWS.md](docs/WINDOWS.md) records how and why the Windows app
differs.

You need 64-bit Windows 10 2004 or later (Windows 11 for the Acrylic and Mica backdrops), the
[Swift toolchain for Windows](https://www.swift.org/install/windows/) 6.4.3, Visual Studio 2022 or
later (or its Build Tools) with the "Desktop development with C++" workload and a Windows 11 SDK,
and, for the end-to-end flows, Git for Windows (its bash) and `jq` on `PATH`.

| What | Command (PowerShell) |
|---|---|
| Build (debug) | `scripts/windows/build.ps1` (`-CheckWarnings` fails on any warning, as CI does) |
| Unit tests | `scripts/windows/test.ps1` (extra arguments pass through, e.g. `-- --filter Wire`) |
| End-to-end flows | `scripts/windows/e2e.ps1` (runs `scripts/e2e.sh` in Git Bash against the Windows build) |
| Pictures of every screen | `.build\debug\BreakpointApp.exe --debug-snapshots build\snapshots-windows` |
| The release zip | `scripts/windows/package.ps1 -Version (scripts/windows/version.ps1) -OutDir build/release` |
| Install and run it as a user would | `scripts/windows/smoke.ps1 -Zip build/release/Breakpoint-<version>-windows-x64.zip` |

Set `BREAKPOINT_HOME` the same way before running the app or the CLI by hand:

```powershell
$env:BREAKPOINT_HOME = Join-Path $env:TEMP "bp-$(Get-Random)"
.build\debug\BreakpointApp.exe --debug-simulate --debug-trace
.build\debug\breakpoint.exe debug help
```

Windows-only code lives in `Sources/BreakpointWindows` (Swift) and `Sources/CBreakpointWin32` (a
small C++ target with a C API for Direct2D, DirectWrite, DirectComposition, WinHTTP and the
notification area). A change to shared code must build and pass on both: CI runs "Build and test"
on macOS and "Build and test (Windows)" on Windows for every pull request. Each Windows surface is a
pure `draw(canvas, controls, state)` function, so `--debug-snapshots` renders exactly what the
window shows.

## What a reviewer checks

These rules are binding; a pull request that breaks one is sent back.

- **[docs/SPEC.md](docs/SPEC.md) is the truth.** It describes every behaviour, screen, word and
  integration. If your change alters behaviour, update SPEC.md in the same pull request. If the
  code and SPEC.md disagree, that is a bug in one of them; say which you think it is.
  [docs/INTERFACES.md](docs/INTERFACES.md) maps the seams between parts of the code.
- **No third-party dependencies.** No packages, no SwiftPM resources, no downloaded assets. Marks
  and icons are drawn in code; sounds are synthesised.
- **No API that triggers a permission prompt.** Breakpoint asks for no permission for any core
  feature. Not allowed: global key-event monitors, `CGEventTap`, the Accessibility API, window
  lists or titles, ScreenCaptureKit, `INFocusStatusCenter`, EventKit, `UNUserNotificationCenter`,
  Apple events to other apps. The one exception is the optional AirPods motion check, started only
  after the user turns it on. SPEC.md §1 and §2.4 list what the app may read.
- **Privacy.** No screenshots, no keystroke content, no window titles, no list of apps or sites,
  no network use except the update check. Nothing about the person leaves the Mac.
- **Words.** Sentences people read follow SPEC.md §3.11: second person, plain verbs, no "should",
  no "!", no medical or health claims, no streaks, scores or guilt counters, never "look away".
  Break, pause, decision and agent sentences live in `Copy` and `BreakCopyLibrary` in
  `Sources/BreakpointCore/Routines/`; button labels and settings text live in the view that
  shows them.
- **Tests never touch the real home folder.** Use `TemporaryDirectory()`
  (`Tests/BreakpointCoreTests/Shared/TestSupport.swift`) and `BreakpointPaths(home:)`. Nothing
  under `~/.claude`, `~/.cursor`, `~/.codex`, `~/.copilot`, `~/.gemini`, shell startup files or
  `~/Library/Application Support/Breakpoint` may be created or read by a test.
- **Zero warnings.** `swift build` must finish without a single warning; CI fails on any.
- **Design system.** Colours, sizes, radii, fonts and durations come from `Theme` and the
  components in `Sources/BreakpointKit/Design/`, and every screen honours Reduce Motion, Reduce
  Transparency and Increase Contrast.
- **Core stays pure.** `BreakpointCore` imports Foundation only (no AppKit, no SwiftUI).

[CLAUDE.md](CLAUDE.md) holds the rest of the working conventions; SPEC.md §11 is the checklist used
for screens.

## Proposing a change

- **Open an issue first** for anything beyond a small fix (a typo, an obvious bug with an obvious
  fix). New behaviour, a new screen, a new integration or a change to the wording should be agreed
  before you write it, so your time is not wasted.
- **One change per pull request.** Small, coherent commits; no unrelated reformatting or renames.
- **Write the pull request title as a plain sentence a user would understand**, for example
  "Breaks now wait for Gemini CLI too." Release notes are generated from pull request titles, so
  the title is what people read when they update.
- **Show UI changes.** Render the affected screens with `scripts/snapshots.sh` (add snapshot states
  for anything new; SPEC.md §9 lists the states every surface needs) and attach the before and
  after pictures to the pull request.
- Before you open it, run `swift build`, `scripts/test.sh` and `scripts/e2e.sh`, and fill in the
  pull request template.

## After you open a pull request

1. **CI runs** the same checks on a macOS runner: a build with zero warnings, `scripts/test.sh` and
   `scripts/e2e.sh`. For a first-time contributor, the maintainer may need to approve the run
   before it starts.
2. **The maintainer reviews it.** Expect questions and requests for changes; push new commits to
   the same branch to answer them.
3. **Only the maintainer merges, and only the maintainer releases.** A merged change reaches people
   with the next release; see [docs/RELEASING.md](docs/RELEASING.md) for how releases are made.

Security problems are not reported through issues or pull requests: see [SECURITY.md](SECURITY.md).
Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Licensing of contributions

Breakpoint is released under the [PolyForm Shield License 1.0.0](LICENSE.md): free to use, read,
change and share for any purpose except providing a product that competes with Breakpoint. It is
source-available, not "open source" in the OSI sense.

By opening a pull request you agree that:

1. You wrote the contribution yourself, or you have the right to submit it, and it contains no code
   or assets under terms that conflict with the project's licence.
2. Everyone receives your contribution under the project's licence, as part of Breakpoint.
3. You also grant the maintainer (the licensor named in [NOTICE](NOTICE)) a perpetual, worldwide,
   non-exclusive, royalty-free, irrevocable licence to use, change, distribute and relicense your
   contribution, including under other terms. This lets the project change its licence later
   without asking every contributor again.

You keep the copyright in what you wrote. If you cannot agree to these terms, please open an issue
describing the change instead of a pull request.