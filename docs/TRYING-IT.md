# Trying Breakpoint

A first walk-through of a build from source: build it, go through onboarding, watch the screens,
get a real nudge from Claude Code, and judge the things no script can. Run everything from the
repository folder. About 20 minutes.

## 1. Build and check

```sh
cd breakpoint                 # your clone
scripts/build-app.sh          # ~1 min → build/Breakpoint.app
scripts/smoke-app.sh          # launch and quit in a stand-in home; only the menu-bar icon appears
scripts/e2e.sh                # ~1 min; forty-one flows with nothing on screen; should end "0 failed"
```

## 2. Open it and go through onboarding

```sh
open build/Breakpoint.app
```

Onboarding opens on the first launch. Go through it with the keyboard only (Return to continue,
Esc to go back); it should take under a minute.

1. Welcome: the mark slides in; "No permissions needed."
2. How it works: the looping demo (nudge over a terminal, the break, the amber "Claude needs you").
3. Connect your agent: press Install next to Claude Code. This adds marked hooks to
   `~/.claude/settings.json` (a backup goes to `~/Library/Application Support/Breakpoint/backups/`)
   and copies the CLI to `~/.breakpoint/bin/breakpoint`. Within a second the row should turn to a
   mint ✓ "Connected", with nothing else to press.
4. Pick your pace: Balanced is preselected.
5. Done: the arrow points at the menu-bar icon; closing the window opens the popover once.

To see onboarding again later: `scripts/run.sh --show-onboarding`.

## 3. Play the most telling screens

These use the real windows with sample data and record nothing. Each quits by itself; Esc Esc
closes an overlay early.

```sh
APP=build/Breakpoint.app/Contents/MacOS/Breakpoint
$APP --demo flow              # nudge → Start → stretch → Claude finishes → Done → resume card
$APP --demo needs-you         # during a stretch: chime, amber chip, Back to work focused
$APP --demo autostart         # the eye-rest countdown card, then the chip that follows the pointer
$APP --demo walk-ambient      # the walk screen dims after 4 s idle; move the pointer for Welcome back
$APP --demo stack             # three pop-ups: the needs-you card pushes the toast out
$APP --demo wind-down         # hold "15 more minutes" for 3 s, or Wrap up for the note
$APP --demo list              # all 27 scenarios
```

Breakpoint itself keeps running in the menu bar while a demo plays; the demo is a separate process.

## 4. A real nudge from Claude Code

Claude Code reads its hooks when a session starts, so open a new Claude Code session (and accept
workspace trust if it asks). A nudge appears only when a break is due, so either wait, or start the
debug build with the timers already due:

```sh
swift build                                        # debug build, ~1 min the first time
pkill -x Breakpoint                                # the running copy owns the socket
.build/debug/BreakpointApp --debug-timers 1250,3050 &
```

(`--debug-timers` exists only in debug builds. This debug copy uses your real Breakpoint folder and
shows real windows; quit it from its menu-bar icon when done, then `open build/Breakpoint.app`.)

Now type a prompt in Claude Code and press Return. About 2 seconds after your last key press, the
"2-min stretch?" card should appear at the top centre, saying "Claude is working". Hover it for
the "why now" line and the keycaps; ⌃⌥⌘B starts it, ⌃⌥⌘. dismisses it. During the stretch, if
Claude asks for a permission, the chime plays and the chip turns amber.

`~/.breakpoint/bin/breakpoint status` shows what the app knows (sessions, timers, pause) at any
moment; `~/.breakpoint/bin/breakpoint doctor` checks the whole path.

## 5. What only a person at the screen can judge

- **Keyboard on the break screen while another app is in front.** With a terminal or editor
  focused, start a break (popover → Take a break → Eye rest). Esc Esc should skip it and Return
  should press the primary, without clicking first; afterwards the app you were in is in front
  again.
- **Blur and motion.** The overlay entrance (≈ 1.5 s: blur, then title, then the rest), the aurora
  drifting, the routine's step slide, the breathing ring. Calm, not bouncy? Try it once with
  System Settings → Accessibility → Display → Reduce motion on.
- **Following a stretch without watching.** Settings → Routine → Preview a stretch, then let a real
  stretch run to the end: can you keep pace from the ring's swell and the soft tick at each step,
  glancing only now and then? Does the closing ring and its line feel like a moment, not a
  reward? Is the tick quiet enough (Settings → General → ▶ next to "Tick at each new stretch step")?
- **Hover on the cards.** A resume card or away note hides after 10 s; hovering keeps it, leaving
  restarts it at 5 s. A card you hover for half a minute must stay. (`--demo resume-one`,
  `--demo away-note`.)
- **The chime.** Settings → General → ▶ next to "Chime when an agent needs you": soft, short,
  no click at the start. Is 50% volume right?
- **AirPods and the call rule.** Join a call with AirPods in, then run
  `~/.breakpoint/bin/breakpoint doctor`. The AirPods line should read like
  "Bluetooth, input+output, running, 16 kHz → counted as call" and "Microphone in use: yes", and
  the menu-bar icon should show the pause bar. Then play music on the AirPods with no call: the line
  should end "not counted: headset not in call mode" (48 or 44.1 kHz is playback). If the call is
  not detected, the report shows what the headset reported; keep that output.
- **The menu-bar icon when the menu bar is full.** macOS hides menu-bar icons that do not fit
  (the smoke test says so when it happens). Check that the icon shows its states (a filled notch
  when a break is due, the pause bar when paused, a small dot while an agent works). When macOS hides it, `open build/Breakpoint.app` again or press your
  popover shortcut: the popover should open from the top right of the screen instead.
  Settings → General → Popover shortcut sets one; check that pressing it opens and closes the
  popover from any app.

- **Focus and clicks, which no script can exercise.** Five quick checks on real windows:
  1. Open the popover from the menu-bar icon, press Esc, and type: the keys should land in the
     app you were in before, without a click.
  2. Start a break from the popover ("Take a break"), let it end or skip it: the app you were in
     gets the keyboard back.
  3. Leave the pointer parked near the top centre of the screen and trigger a nudge
     (section 4): it should still fade out by itself after about 10 seconds, and pause only once
     you move the pointer onto it.
  4. `--demo wind-down`: click the card, then hold Space on "15 more minutes" and press Return on
     "Wrap up": both should work after the click.
  5. Settings → Privacy → Delete… (leave the alert open), then start a break from the popover:
     Esc Esc should still end the break. Cancel the alert afterwards.
  Also click just below a nudge card, on its shadow: the click should reach the window underneath.

## 6. Undo everything

```sh
~/.breakpoint/bin/breakpoint uninstall all     # every hook out; files restored exactly
```

Then turn off Settings → General → Open at login if you turned it on, quit Breakpoint, and
`rm -rf ~/.breakpoint "$HOME/Library/Application Support/Breakpoint"`.
