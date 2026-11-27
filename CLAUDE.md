# Breakpoint — working notes

Breakpoint is a native macOS menu-bar app: break reminders that wait for your coding agent. These
notes are for anyone working in the code, people and coding agents alike.
**[docs/SPEC.md](docs/SPEC.md) is the single source of truth** for behaviour, screens, design,
integrations and data. [docs/INTERFACES.md](docs/INTERFACES.md) maps the seams between the parts
of the code. `docs/research/` is background only; where it differs from SPEC.md, SPEC.md wins.

## Commands

| What | Command | Time on an M-series Mac (Command Line Tools only) |
|---|---|---|
| Build everything (debug) | `swift build` | ~1 min clean, a few s incremental |
| Run the tests | `scripts/test.sh` (extra args pass through, e.g. `scripts/test.sh --filter Wire`) | ~10 s after a build |
| Render snapshots | `scripts/snapshots.sh [FILTER…]` → `build/snapshots/**.png` (2×) | ~13 s for all |
| List snapshot names | `scripts/snapshots.sh --list` | |
| Build the app bundle | `scripts/build-app.sh` → `build/Breakpoint.app` | ~70 s (release) |
| Build and open the app | `scripts/run.sh [app args]` (quits a running copy first) | |
| Launch/quit smoke test | `scripts/smoke-app.sh` (after build-app; uses a temporary home, no window) | ~8 s |
| End-to-end flows | `scripts/e2e.sh [-v] [FLOW…]` (debug app, headless, temporary homes; needs `jq`, built into macOS 15+) | ~1 min after a build |
| Capsules in a real window | `.build/debug/BreakpointSnapshots --window-probe DIR` (off-screen window, no capture) | ~1 s |
| CLI during development | `swift run breakpoint …` or `.build/debug/breakpoint …` | |
| Ship a release (maintainers) | `scripts/release.sh X.Y.Z "One line of what's new"` (add `--dry-run` to only check; see [docs/RELEASING.md](docs/RELEASING.md)) | |

Release plumbing (docs/RELEASING.md), run by `.github/workflows/release.yml` rather than by hand:
`scripts/package-release.sh` (zip, feed, checksums), `scripts/make-update-feed.sh` and
`scripts/update-signing.swift` (Ed25519 keys and signatures). `scripts/release-keygen.sh` makes
the release key, once, for the maintainer; `scripts/install.sh` is the one-line installer
published with each release.

App launch arguments: `--show-onboarding`, `--tour` (start the one-minute tour, as Settings →
General does), `--debug-stall-main N` (watchdog test, SPEC §7.3),
`--quit-after N` (smoke tests), `--demo NAME` / `--demo list` (break screens on real windows with
sample data; `--demo-volume V` sets the chime volume, 0…1), `--signals` (print the activity
monitor's diagnostic report and exit), and the debug-build-only harness flags below.
Environment: `BREAKPOINT_HOME=/some/dir` makes the app and the CLI use that folder as the home
directory (all of `~/Library/Application Support/Breakpoint`, `~/.breakpoint` and every tool's
config file move under it; the login item is never registered). Use it whenever you run the app or
CLI by hand, so you never touch the real configuration of coding agents on your Mac. Keep the path
short (under `$TMPDIR` is fine): the socket path must fit in 103 bytes, or it falls back to
`~/.breakpoint/run/bp.sock` under that home.

## Testing the whole app (debug builds only)

`Sources/BreakpointApp/DebugHarness.swift` is compiled only in debug builds (`#if DEBUG`); a
release build (scripts/build-app.sh) ignores these flags and its CLI has no `debug` command.

| Flag | Effect |
|---|---|
| `--debug-headless` | All logic runs; no window, panel, status item, popover, alert, sound or hotkey. A recorder stands in for every controller: it logs what would be on screen and plays the controllers' own timers (nudge ignored after 10 s, cards hidden after their time; no hover). |
| `--debug-simulate` | Input, call signals, presence and the AirPods check are simulated (driven by `breakpoint debug input/call/presence/headphones`), and the app's clock can be moved (`advance`, `idle`, `jump`). |
| `--debug-timers SCREEN,STILL` | Start with these timer values (seconds). |
| `--debug-trace` | Print every change of what is (or would be) on screen, with the app's clock. |

Drive it with the real CLI against the same home (`.build/debug/breakpoint debug help` lists
everything): `debug state` (JSON of timers, presence, pause, nudge, break, cards, decision,
sessions, history, sounds, AirPods calls, integrations, update), `debug log`, `debug timers S M`,
`debug advance N` (N seconds at 1 s steps, user present), `debug idle N` (no input),
`debug jump 23:20` (or `jump +SECONDS`), `debug input key|pointer|scroll|drag|mirrored on|…`, `debug call mic|camera|both|none`,
`debug presence locked|unlocked|…`, `debug settings '{"key": value}'` (through the app's own
update path), `debug update-feed FILE|fail|none` (the update check's feed; an archive it names
is read from the same folder: the harness never reaches the network), `debug update-key BASE64` and
`debug update-location APP` (a throwaway key and a stand-in app bundle for `debug action install-update`),
`debug install-check unreachable|normal` (the check after Install reaches no app, so it fails and says why),
`debug tour start|next|skip|popover-closed` (the one-minute tour; `debug state` also shows `hints` and `popover`) and `debug action accept|skip|extend|undo|install claude-code|…`. Example:

```sh
export BREAKPOINT_HOME="$(mktemp -d -t bp)"
.build/debug/BreakpointApp --debug-headless --debug-simulate --debug-trace &
.build/debug/breakpoint debug timers 1250 3050          # a stretch is due
.build/debug/breakpoint emit agentStarted --source claude-code --session s1
.build/debug/breakpoint debug state | jq .nudge          # {"kind":"move",…,"title":"2-min stretch?",…}
.build/debug/breakpoint debug action accept && .build/debug/breakpoint debug advance 121
.build/debug/breakpoint debug state | jq '.history[-1]'  # move completed
```

`scripts/e2e.sh` runs forty-one such flows and must pass after every change. Use the headless
harness for anything automated: a full-screen overlay or a window taking focus would interrupt
whoever is working at the Mac. `--demo selftest` and `BREAKPOINT_UI_SELFTEST` show real windows
(a few seconds each) and are for deliberate, attended checks only.

## Environment facts

- Builds with Apple's Command Line Tools alone (Swift 6.3, macOS 26 SDK, Apple Silicon); Xcode is
  not needed. A Swift package only: no .xcodeproj, asset catalogs, storyboards, Interface Builder
  or SwiftUI previews. Use the snapshot tool instead of previews.
- Tests use **Swift Testing** (`import Testing`); XCTest is not used. Plain `swift test` cannot
  find the Testing module with the Command Line Tools alone; `scripts/test.sh` adds the framework
  search paths when they are the selected developer directory, and runs plain `swift test` with Xcode.
- `ImageRenderer` renders SwiftUI to PNG without a window, but **not** materials, behind-window
  blur or AppKit-backed controls (toggles, pickers, menus, scroll views, lists). Snapshots force
  `glassRendering(.opaque)` (an opaque approximation of the glass; `GlassStage` blurs a drawn
  desktop instead, for honest pictures of the material) and use the `.window` renderer
  (an off-screen `NSHostingView`) for anything with native controls. Neither shows the macOS 26
  system Liquid Glass: `ImageRenderer` draws `glassEffect` without its blur, and `cacheDisplay`
  draws it blank.
- The default macOS file system is case-insensitive: the app target is **BreakpointApp** (renamed
  to `Breakpoint` inside the bundle) and the CLI product is **breakpoint**. In the bundle the CLI
  lives at `Contents/Helpers/breakpoint` (it cannot sit next to `Contents/MacOS/Breakpoint`).
- A debug build (`.build/`) takes about 450 MB, and more once the tests are built. `build/` and
  `.build/` are git-ignored.
- On macOS 26 status-item windows belong to Control Center, so window lists can't prove the status
  item exists; `scripts/smoke-app.sh` checks the frame the app logs instead.
- In zsh, `log` is a builtin; use `/usr/bin/log show --info --predicate 'subsystem == "com.breakpointapp.Breakpoint"'`.

## Conventions

- Swift 5 language mode, swift-tools-version 5.10, macOS 14+. **No third-party dependencies.** No
  SwiftPM resources (bundles break inside app bundles): draw marks and icons in code; sounds are
  synthesised.
- `BreakpointCore` is Foundation-only (no AppKit, no SwiftUI) and must build with **zero
  warnings**. Keep the other targets warning-free too.
- Core logic is pure: policies take values and return values; the coordinator owns state.
  Behaviour constants live in `Timing` (`Sources/BreakpointCore/Models/Timing.swift`); tests use
  them by name.
- Views read `AppState` and Core models only and act only through `AppActions`. Controllers
  conform to `SurfaceController` and reconcile windows in `sync()`. Nothing positions a pop-up
  except `TransientPanelStack`.
- Use the design system (`Theme`, components in `Sources/BreakpointKit/Design`) for every colour,
  size, radius, font and duration. Every component honours Reduce Motion, Reduce Transparency and
  Increase Contrast through `DesignTraits()`; do the same in screens (and use
  `traits.runsContinuousAnimations` for pulses, aurora and breathing so snapshots are stable).
- Pop-ups and the overlay are always dark (`.environment(\.colorScheme, .dark)`); Settings and
  Onboarding follow the system appearance.
- Copy: break, pause, decision and agent sentences come from `Copy` / `BreakCopyLibrary` in
  `Sources/BreakpointCore/Routines`. UI chrome (button labels, settings descriptions) lives in the
  view that shows it. Second person, plain verbs, no "should", no "!", **no medical claims**, no
  guilt counters or scores, never "look away".
- **No API that triggers a permission prompt**, except the optional AirPods motion check
  (`CMHeadphoneMotionManager`, only after the user turns it on). Forbidden: global key-event
  monitors, `CGEventTap`, Accessibility API, window lists/titles, ScreenCaptureKit,
  `INFocusStatusCenter`, EventKit, `UNUserNotificationCenter`, Apple events to other apps.
- **The network is for updates only** (SPEC §2.11): the release feed and, on Update, the archive,
  in `Services/UpdateFetcher.swift`. Nothing else connects anywhere; the harness and tests never do.
  Updates install only if signed with the release key (`Updates/UpdateKey.swift`); tests and e2e use
  throwaway keys made on the spot. Never create or commit a real key: `scripts/release-keygen.sh`
  is for the maintainer who publishes releases.
- **Tests never touch the real home directory**: use `TemporaryDirectory()` (Shared/TestSupport.swift)
  and `BreakpointPaths(home:)`. Nothing under `~/.claude`, `~/.cursor`, `~/.codex`, `~/.copilot`,
  `~/.gemini`, shell rc files, or `~/Library/Application Support/Breakpoint` may be created or
  read by tests. Made-up keys and tokens in tests say FAKE, so secret scanners and readers can
  tell them from real ones.
- `Settings` is ambiguous with SwiftUI's `Settings` scene. BreakpointKit exports
  `public typealias Settings = BreakpointCore.Settings` and the app target declares its own alias;
  in any other target that imports both, declare `typealias Settings = BreakpointCore.Settings`.
- Snapshot names start with their folder (`break/…`, `design/…`, `menubar/…`, `settings/…`,
  `onboarding/…`, `tour/…`, `hints/…`); build states with `AppState.preview(_:)`. SPEC §9 lists every state required.
- Commits: small and coherent.

## How the parts fit

The code has four parts that meet only through the types in docs/INTERFACES.md: core logic,
integrations, break screens, and the menu bar with settings and onboarding. The coordinator in
`Sources/BreakpointApp` wires them together.

- **Core logic**: `SessionTracker` emits `SessionTransition`s; the coordinator builds resume cards
  and the wind-down trigger from them. `PresenceTracker` reports `retroactiveSeconds` for idle away
  so the clock can remove accrued time. The engine loop that sequences the policies (tick, events,
  presence, pauses, nudge and break lifecycles) is `AppCoordinator+Loop.swift`.
- **Integrations**: the socket server answers events, status requests and `command` requests
  (`activate`, `signals`, `debug`) on the main queue. `HookPayloadParser` reads stdin and argv
  payloads and detects Cursor relaying through Claude Code's hooks. Installers run off the main
  thread and keep `integrations.json` (the ledger) so uninstall restores files exactly.
- **Break screens**: the overlay is per-display at `.screenSaver` with the watchdog running. Each
  card's surface owns its lifetime (auto-hide, hover pause); the coordinator never times cards out.
- **Menu bar, settings, onboarding**: the status item, popover, settings and onboarding; the
  popover shortcut uses `HotKeyCenter`.
- **Updates**: `UpdatePolicy` decides when to check and ask; `UpdateFetcher` downloads; the
  installer verifies the signature, swaps the app and reopens it (`AppCoordinator+Updates.swift`).

## Layout

```
Package.swift
Sources/
  BreakpointCore/      Foundation only. Models/ (shared types) · Engine/ Tracking/ History/ Settings/
                       Routines/ (core logic) · Wire/ Integrations/ (integrations) · Updates/
  BreakpointKit/       AppKit and SwiftUI. Design/ State/ (shared) · Break/ (break screens) ·
                       MenuBar/ Settings/ Onboarding/ · Tour/ (the one-minute tour) · Services/
                       (activity, AirPods motion, hotkeys, displays, login item, update download)
  BreakpointApp/       main, AppDelegate, AppCoordinator (+Loop, +Actions, +State, +Commands,
                       +Hints, +Pacing, +Rotation, +Tour, +Updates), DebugHarness (debug only)
  breakpoint-cli/      the `breakpoint` tool
  BreakpointSnapshots/ snapshot tool: one registry file per part (Design, Glass, Break, MenuBar,
                       Settings, Onboarding, Tour), the app icon, and frame-by-frame motion films
Tests/BreakpointCoreTests/  Shared/ · CoreLogic/ · Integrations/ · Motion/
scripts/               build, test, snapshot, e2e and release scripts (above)
docs/                  SPEC.md, INTERFACES.md, RELEASING.md, MAINTAINING.md, TRYING-IT.md ·
                       research/ (background notes) · readme/ (the README's pictures: assets/, and
                       src/, the page that renders the hero)
```
