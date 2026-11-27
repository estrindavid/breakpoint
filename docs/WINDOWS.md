# Breakpoint on Windows

How the Windows app is built and where it differs from the Mac. [SPEC.md](SPEC.md) is still the
single source of truth for behaviour; this page records what Windows needs on top of it and why,
and SPEC.md links here wherever Windows does something its own way.

## One codebase, two shells

| Part | macOS | Windows |
|---|---|---|
| Engine, policies, integrations, wire format, updates | `BreakpointCore` | the same |
| `AppState`, `AppActions`, the coordinator and its engine loop, the debug harness | `BreakpointRuntime` | the same |
| `breakpoint` CLI | `breakpoint-cli` | the same, `breakpoint.exe` |
| Windows, pop-ups, status item, services | `BreakpointKit` (AppKit + SwiftUI) | `BreakpointWindows` (Win32 + Direct2D) |
| The app | `BreakpointApp` (`Breakpoint.app`) | `BreakpointWinApp` (`Breakpoint.exe`) |

The coordinator reaches the operating system only through `AppPlatform` and `PlatformShell`
(`Sources/BreakpointRuntime/Platform`). Everything the engine decides, says and records is the
same code on both; the unit tests (613) and the end-to-end flows (`scripts/e2e.sh`) run on both.

## Drawing and windows

- One UI thread: a Win32 message loop that also runs `DispatchQueue.main` and Foundation's
  timers (`MessageLoop`). It sleeps in `MsgWaitForMultipleObjectsEx` until a message arrives,
  the main queue has work (libdispatch's main-queue event) or a timer is due: an idle app uses no
  CPU.
- Every window is drawn with Direct2D and DirectWrite into a premultiplied-alpha DirectComposition
  swap chain (`CBreakpointWin32`, a small C++ target with a C API), GPU-composited and per-monitor
  DPI aware.
- Pop-ups and the tray flyout sit on Windows 11's own Acrylic backdrop (the transient-window
  system backdrop) with system rounded corners: the equivalent of the Mac's glass. Settings and
  Onboarding use Mica and follow the app mode (light or dark). With transparency effects off, or
  on Windows 10, they are drawn opaque.
- Type: Segoe UI Variable (Text for body sizes, Display for titles and numbers) for SF Pro.
- Glyphs: the break kinds and the agent sparkle are drawn as vectors in the brand's line style;
  every other SF Symbol the shared models name maps to its Segoe Fluent Icons equivalent
  (`Design/Glyphs.swift`), so controls look like Windows' own.
- Every surface is a pure `draw(canvas, controls, state)` function over immediate-mode controls
  (Tab and Shift+Tab, Enter, Space, arrows, Esc; a focus ring only once the keyboard is used, as
  Windows does). `Breakpoint.exe --debug-snapshots DIR` renders each one offscreen, in every state
  the shared previews describe, with the same code the windows run.
- Nothing redraws unless something changed; a window animates (at the display's rate) only while
  something on it visibly moves, and stops by itself.

## The tray icon and the flyout (SPEC §3.7, §3.8)

- The notification-area icon draws the same mark states and badges as the menu bar, by shape, in
  the taskbar's own colour (white on a dark taskbar, near-black on a light one, following "Choose
  your Windows mode"); knocked-out parts are real holes in the icon. The working badge breathes;
  each mark cue plays once; both stop under "Animation effects" off and while the session is locked.
- Windows shows no text beside a tray icon: the menu-bar text (SPEC §3.7) joins the tooltip.
- Left click (or Enter on the focused icon) opens the flyout: the popover's content, from the same
  `PopoverModel`, above the taskbar at the icon, 12 DIPs from the taskbar and the screen's edge. It
  closes through the same `PopoverPolicy` as the Mac popover (a click elsewhere, Esc, a display
  change). Right click opens the menu; "Why not now?" is a greyed line at its top, since Windows has
  no Option-click.

## Signals (SPEC §2.4) without a hook

Windows lets any app install keyboard and mouse hooks or raw-input listeners without asking. The
Windows app uses none of them, for the same reason the Mac app asks for no permission: it never
needs to see input.

| Signal | Source |
|---|---|
| Seconds since any input | `GetLastInputInfo` (a tick count, nothing about the input) |
| Typing vs pointing | inferred: input while the cursor stays still and no button is down counts as typing; the scroll wheel cannot be told apart without a hook, so it counts as typing too (the typing guard then only delays an offer) |
| Click or drag | `GetAsyncKeyState` for the three mouse buttons only |
| Display kept awake | `ES_DISPLAY_REQUIRED` in the system's execution state, presentation mode or a full-screen Direct3D app (`SHQueryUserNotificationState`) |
| Display mirrored | two active display paths sharing one source (`QueryDisplayConfig`) |
| Microphone, camera | Windows' own record of apps using them now (`CapabilityAccessManager\ConsentStore`, the data behind Settings → Privacy), watched with `RegNotifyChangeKeyValue`; only whether any app does is kept |
| Lock, sleep, display off, remote sessions | `WTSRegisterSessionNotification`, `WM_POWERBROADCAST`, `GUID_CONSOLE_DISPLAY_STATE` |
| AirPods movement check | not available (no Core Motion); the setting is hidden |

## Integrations

- **Hook commands** name the CLI copy by its absolute path with forward slashes and no quotes:
  `C:/Users/x/.breakpoint/bin/breakpoint.exe emit agentStarted --source claude-code --stdin-json`.
  Tools run hooks through PowerShell (Cursor, Codex, Gemini CLI, Copilot CLI's `powershell`
  field), Git Bash or PowerShell (Claude Code) or `cmd`; this is the one form all of them run.
  A home folder with a space in its name is written in its 8.3 short form.
- Unlike the Mac's `[ -x … ] && … || true` wrapper, there is no form every Windows shell runs
  that makes a missing CLI copy a silent no-op. The install check and `doctor` say when the copy
  is missing, and Install puts it back.
- A settings file shared with a Mac (dotfiles) that holds the Mac's hook commands reads as
  "Needs an update" rather than "Edited outside Breakpoint"; Install rewrites them for this PC.
- **Copilot CLI** gets its `powershell` field (the one it runs on Windows) besides `bash`.
- **The install check** runs the hook command through Windows PowerShell (`-NoProfile
  -NonInteractive -Command`), the strictest of the shells about the command's form.
- **Shell integration** is PowerShell: a marker block at the end of each PowerShell's profile for
  the current user (`Documents\PowerShell` and `Documents\WindowsPowerShell`, wherever Documents
  is), dot-sourcing `~\.breakpoint\shell\breakpoint.ps1`. It wraps `PSConsoleHostReadLine` and
  `prompt`, takes the command's name from PowerShell's own tokenizer, and sends the finish only
  for commands of 2 s or more. PowerShell runs profiles only when its execution policy allows
  local scripts (RemoteSigned, the PowerShell 7 default).
- **The CLI** writes `\n` line endings, as on the Mac; `breakpoint.exe` and its Visual C++
  runtime are copied together to `~\.breakpoint\bin`.

## The socket (SPEC §5.1)

Windows 10 1803 and later have `AF_UNIX` sockets, so the wire format and the CLI are unchanged.
The socket file is `%LOCALAPPDATA%\Breakpoint\breakpoint.sock`. Windows has no `getpeereid`; the
same-user guarantee comes from the file's ACL, inherited from the user's own `%LOCALAPPDATA%`,
which only that user (and the system and administrators) can open. The server is one I/O thread
on `WSAWaitForMultipleEvents`.

## Data on disk (SPEC §8)

`%LOCALAPPDATA%\Breakpoint\` (never roamed, as Application Support is never synced) holds what
`~/Library/Application Support/Breakpoint/` holds on the Mac. `~\.breakpoint\` is the same.

## Updates (SPEC §2.11)

- The Windows app reads its own feed, `update-feed-windows.json`, from the same releases; installed
  Macs keep reading `update-feed.json`. Both archives are signed with the same release key, by the
  same tool, in the same workflow step.
- Signatures are checked with first-party SHA-2 and Ed25519 code (`Updates/SHA2.swift`,
  `Updates/Ed25519.swift`, tested against FIPS 180-4 and RFC 8032 and against CryptoKit on the
  Mac), since Windows has no CryptoKit.
- The install folder is `%LOCALAPPDATA%\Programs\Breakpoint` (per user: no administrator).
  Windows cannot rename a folder while a program inside it runs, but it can rename the running
  program's files, so the in-place swap exchanges the two folders' contents item by item, undoing
  every step if one fails. The relaunch helper (`bin\breakpoint.exe update-relaunch`) runs from
  the old copy as on the Mac.
- The archive is about 41 MB: both executables link the Swift runtime and ICU's data in, so the
  CLI copy needs nothing else. The size limit for a Windows archive is 96 MB.

## Building

See [CONTRIBUTING.md](../CONTRIBUTING.md#windows). In short: the Swift toolchain for Windows
(6.4), Visual Studio Build Tools with the C++ workload, then `scripts/windows/build.ps1`,
`test.ps1`, `e2e.ps1` (needs jq), `package.ps1` and `smoke.ps1`.
