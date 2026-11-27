# Breakpoint — product and architecture spec (v2)

Breakpoint is a macOS menu-bar app for developers who work with AI coding agents. It offers short
movement and eye-rest breaks **at natural pauses in coding** (mainly while an agent is busy),
calls you back when the agent needs you, and helps you stop at night. It runs entirely on the
user's Mac, **never looks at the screen or reads code**, and needs **no permission prompt** for
any core feature.

One-line pitch: *Break reminders that wait for your agent.*

**How to read this document.** This file is the single source of truth. `docs/research/` holds
background (`agent-integrations.md` for hook formats); where it differs from this file, this file
wins (see §10). Sizes are in points (pt), durations in
seconds (s). "Must" is a requirement; "default" is a user-changeable setting value. Values marked
*measured* are used as given even when they fall off the 4-pt grid.

| Part | Sections | Code |
|---|---|---|
| Core logic | 2, 6, 7.1, 7.3 | `BreakpointCore` (all but `Integrations/`), `Breakpoint` app target |
| Integrations | 5, 6 | `BreakpointCore/Integrations`, `breakpoint-cli`, shell snippets |
| Break screens | 3.0–3.6, 4 | `BreakpointKit/Design`, `Break/`, the Kit services they use |
| Menu bar, settings, onboarding, the tour and hints | 3.7–3.10, 3.12 | `BreakpointKit/MenuBar`, `Settings/`, `Onboarding/` |

Parts meet only through the types named in §7 (`EngineSnapshot`, `AgentEvent`, `WireMessage`,
`AppState`, `AppActions`).

---

## 1. Principles (non-negotiable)

1. **Never interrupt a thought.** A nudge may only appear at an *opportunity* (§2.5): an agent
   just started working, a long command is running, or the user has paused typing while a break
   is overdue. Never while the user is typing or dragging, and never while a microphone or camera
   is in use. While the person presents or watches (a display mirrored or kept awake), nothing
   starts by itself and a pause in typing offers nothing (§2.4).
2. **Quiet by default.** A small nudge first; a full break only when accepted (or auto-started
   for the 20-second eye rest, which the user can switch off). Every *focused* surface closes
   with Esc; the break overlay needs **Esc twice** to skip. Pop-ups that never take focus close
   by click, by global hotkey, or by themselves.
3. **Private by construction.** No screenshots, no screen recording, no keystroke content, no
   window titles, no list of apps or websites used, no network calls except updates (§2.11): a
   daily download of a small public file that sends nothing about the person (Settings → About can
   turn it off), and the new version itself when the person installs it. The only inputs are listed
   in §2.4 and in the Privacy pane. All data stays in `~/Library/Application Support/Breakpoint/`
   (plus the CLI copy in `~/.breakpoint/`, §5.2). **No core feature may trigger a permission
   prompt** (no Accessibility, Input Monitoring, Screen Recording, Calendar, Focus, Notifications,
   Camera or Microphone access). The only prompt in the app belongs to the optional AirPods
   check (§2.9), shown only when the user turns it on.
4. **No medical claims.** Copy talks about movement, eye rest and stopping times. Never "treats",
   "prevents", "fixes posture", "diagnoses", stress or burnout scores. A one-line
   "General wellness, not medical advice." appears in About and on the `move` break screen.
5. **No guilt.** No streaks, no scores, no leaderboards, no "skipped" counts anywhere in the UI.
   History is a calm record. The popover's totals (§3.8) are the person's own all-time totals of
   what they did: never a target or goal, never a comparison with other people, never a streak,
   never a count of anything missed, skipped or declined, and they only grow.
6. **Native and calm.** It should feel like a first-party macOS utility: restrained, fast,
   legible. When Breakpoint decides something on its own it says what and why in one sentence
   and, if timers changed, offers Undo. It never asks a blocking question it could answer itself.

---

## 2. Behaviour

### 2.1 Break kinds and cadence

| Kind | Length | Content | When it is due |
|---|---|---|---|
| `eyes` | 20 s | Look at something far away | screen time ≥ eye cadence (default 20 min) |
| `move` | 2 min | A two-minute routine from the library, rotating (§2.2) | still time ≥ move cadence (default 50 min) |
| `walk` | 5–10 min | Stand up and walk; app calls you back | offered *instead of* `move` when the triggering agent's expected run ≥ walk threshold (default 8 min) |
| `breathe` | 60 s | Paced breathing, 5.5 s in / 5.5 s out | manual; or offered instead of `move` after two stretch offers in a row were turned down (Not now or ignored) |

Walk target = expected run length clamped to 5–10 min, rounded to the minute.

| Preset | Eye cadence | Move cadence |
|---|---|---|
| Gentle | 30 min | 75 min |
| Balanced (default) | 20 min | 50 min |
| Frequent | 15 min | 30 min |

Editing either cadence sets the preset to Custom.

### 2.2 The two-minute routines (`move`)

A stretch break plays one routine from a library (`BuiltInRoutines` in `Routines/`). Every
routine lasts exactly **120 s** in 3–5 steps of 10–120 s each. The no-equipment routines:

| Id (stable) | Name | Steps (seconds) |
|---|---|---|
| `neck-and-shoulders` | Neck and shoulders | Shoulder-blade squeeze 30 · Arms up the wall 36 · Slow shoulder rolls 24 · Gentle neck side-bend 30 |
| `wrists-and-forearms` | Wrists and forearms | Slow wrist circles 24 · Spread and close 24 · Palm-up stretch 24 · Palm-down stretch 24 · Shake out your hands 24 |
| `upper-back` | Upper back | Seated cat-cow 36 · Elbow circles 24 · Reach and row 30 · Seated twist 30 |
| `chest-opener` | Chest opener | Hands clasped behind 32 · Goalpost arms 30 · Open-arm sweeps 30 · Chest lift 28 |
| `hips-and-calves` | Hips and calves (standing) | Heel raises 30 · Calf stretch 30 · Hip circles 30 · March in place 30 |
| `stand-and-reach` | Stand and reach | Stand and reach 32 · Side reach 30 · Desk lean 30 · Shoulder shrugs 28 |
| `seated-legs` | Seated legs | Ankle circles 30 · Seated leg lifts 30 · Heel and toe rocks 28 · Seat squeeze 32 |

With "I have a resistance band" on, two band routines join the rotation: `band-raises` (band
lateral raises 30 · rest 15 · raises 30 · rest 15 · raises 30) and `band-pull-aparts` (pull-aparts
30 · rest 15 · palms-up pull-aparts 30 · rest 15 · pull-aparts 30). Without a band they never
appear.

Each step has a title (2–5 words), one instruction sentence (≤ 12 words), a cue for the chip
(e.g. "3 s squeeze · 3 s release"), a **tempo** — one repetition as phases with a label and
seconds (e.g. squeeze 3 s, release 3 s), repeated for the whole step — and a duration that is a
whole number of repetitions. Every routine has a stable id, a name and a one-line summary for
Settings. Routines must be doable standing or seated at a desk in ordinary clothes, without
equipment (band routines excepted) and without turning away from the screen for long; nothing
ballistic, no end-range neck circles, nothing held to discomfort; they describe movements only,
never benefits. `RoutineWordingTests` enforces the wording and timing rules on every routine.

**Rotation.** Each stretch break uses the *allowed* routine (available for the equipment, not
left out in Settings) started least recently, never the same one twice in a row when more than
one is allowed. Routines never done come first, in library order, so in practice the routines
take turns in library order. Every routine has the same weight. If every routine is left out
(only possible in a hand-edited file), the setting is ignored. Recency is counted in stretch
breaks started, not clock time. Preview a stretch shows the next routine and does not advance
the rotation.

**Copy.** Routines and all break copy are data (`Routine` / `RoutineStep` / `TempoPhase` /
`BreakCopy` in `Routines/`), with 4–6 title/instruction variants per kind. Each kind draws its
variants from its own **shuffle bag**: every variant once, in random order, before any repeats,
and never the same variant twice in a row (also across rounds and relaunches). The walk's idea
line and each kind's closing line (§3.3 Ending) draw from bags of their own the same way. A real
break draws; a preview does not.

The rotation (stretches started, when each routine was last started, the last routine, each
bag) is saved in `rotation.json` (§8) whenever a real break starts, so it survives a
relaunch.

### 2.3 Timers, away time and natural breaks

`ActivityClock` keeps two counters in a value type `TimerState`:
- **screen time** (drives `eyes`): accrues while the user is present.
- **still time** (drives `move`): accrues while the user is present.

**Present vs away.** The user is *away* when either:
- no keyboard or mouse input for ≥ the away threshold (default 3 min, range 2–10 min), **unless**
  a call signal is active or some process is preventing display sleep (§2.4) — then idle input
  never makes the user away; or
- the screen is locked, the displays are asleep, the screen saver is running, or the session is
  switched out.

Away time starts at the last input (retroactively for idle) or at the lock/sleep moment. Time
accrued between the last input and detection is removed. Nothing accrues while away. Away ends
at the next input, unlock or wake.

**Natural breaks (`AwayPolicy`, pure).** When an away period of duration *D* ends:
- for each of `eyes` (20 s) and `move` (2 min): if *D* ≥ that break's length, reset its timer;
  if its timer was at or past its cadence, record a `credited` history entry for it.
- because the away threshold is ≥ 2 min, any idle-based absence resets both timers; a short lock
  (e.g. 40 s) resets only the eye timer.
- if any timer was reset, create an `AutoDecision` (§7.1) holding the previous `TimerState`.
- if a due break was credited, show the away note (§3.5). Otherwise the reset is silent apart
  from the popover's decision line (§3.8).
- never show a question. **Undo** (available 10 min) restores the previous `TimerState`, adds *D*
  to both counters as if the user had been present, deletes the `credited` entries and shows the
  toast "Timers restored".

**After a break.** A break the person started counts, however briefly it ran and however it
ends (Skip, Esc twice, I'm back, Back to work, the ceiling): it is just less time. Its timer
restarts exactly as for a completed break of that kind, and it is never a refusal (§2.7): no kind
spacing, and a stretch, walk or breather clears the count of refused stretches. The totals show
the real seconds it ran (§2.7), so a short break counts for little there. The earliest a break
can end is 3 s with Skip or Esc twice (the Skip guard, §3.3); I'm back on a walk and Back to work
work at once. "Since you moved" means since the person last stood up and moved, so a stretch or
walk restarts both timers and the minutes it was on screen never count as sitting still.

| Kind | `completed` or `endedEarly` |
|---|---|
| `move`, `walk` | both timers restart |
| `eyes` | screen time restarts |
| `breathe` | nothing restarts; the stretch is held off for one move cadence (below) |

An eye rest rests the eyes only, so it never touches still time. A breather is done sitting down,
so it is not moving and still time carries on ("since you moved" stays true). It is still an
answer, though: once a breather the person started ends, the still-time slot (`move`, `walk`,
`breathe`) is not offered for one full move cadence (`settings.cadence.moveEvery`, default
50 min) from that moment (`stretchHeldUntil`). Eye rests are not held: one comes when due,
subject to nudge spacing. A stretch or walk taken meanwhile (from the menu) ends the hold. While
it lasts, the status counts down to its end rather than showing the stretch as due, and "Why
not now?" says "You took a breather: next stretch from 15:40" (§3.7).

### 2.4 Smart timing: signals, pauses and cool-downs

Every signal below is read without a permission prompt. Breakpoint must not use
`NSEvent.addGlobalMonitorForEvents` for key events, `CGEventTap`, the Accessibility API, window
lists, window titles, `ScreenCaptureKit`, `INFocusStatusCenter`, EventKit or
`UNUserNotificationCenter`.

| Signal | How it is read (macOS 14+) | Used for |
|---|---|---|
| Seconds since last key press | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, .keyDown)`, polled 1 Hz (10 Hz while a nudge or countdown is visible) | typing guard, `typingPause`, auto-start cancel |
| Seconds since last scroll | same API with `.scrollWheel` | auto-start cancel (reading) |
| Seconds since any input | same API with `kCGAnyInputEventType` | away detection |
| Mouse button held / dragging | `NSEvent.pressedMouseButtons != 0`; seconds since `.leftMouseDragged` / `.leftMouseDown` | drag guard, auto-start cancel by click |
| Microphone in use | CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on every input device, with property listeners | call pause once on for 60 s; holds offers before that |
| Camera in use | CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` on every video device, with listeners | call pause (can be turned off) |
| Lock / unlock | distributed notifications `com.apple.screenIsLocked` / `…Unlocked` | away |
| Display sleep / wake, system sleep / wake, session switch | `NSWorkspace` `screensDidSleep/Wake`, `willSleep/didWake`, `sessionDidResign/BecomeActive` | away |
| Screen saver | distributed `com.apple.screensaver.didstart` / `didstop` | away |
| Display sleep prevented | `IOPMCopyAssertionsStatus`: is any `PreventUserIdleDisplaySleep` assertion held (count only, no app names) | idle does not count as away (video, presentation); presenting guard |
| Display mirrored | `CGGetActiveDisplayList` + `CGDisplayIsInMirrorSet` (display configuration only, read with the assertion every 2 s) | presenting guard |
| Pointer position | `NSEvent.mouseLocation` | active display, countdown chip |

**Typing guard.** Input is *busy* when a key was pressed < 2 s ago, a mouse button is down, or a
drag happened < 1 s ago. An opportunity that arrives while input is busy is **held** (not
dropped) and re-evaluated every tick until input is quiet or the opportunity expires (30 s).
This is what lets `agentStarted` (fired by the Return key that submitted the prompt) produce a
nudge about 2 s later.

**Short microphone use (dictation).** Dictation is not detected as such (it would need a
permission); the microphone signal stands in for it. A microphone counts as a call only once it
has been on without a break for `Timing.microphoneCallAfter` (60 s; `MicrophoneCallGate`, Core).
Before that it is *pending*: opportunities are **held** while it lasts (`hold(.microphone)`, the
typing guard's way, so nothing appears while the person speaks) and an eye-rest countdown stops
(§3.1), but there is no pause, no toast and no cool-down afterwards. So a prompt dictated and sent
with Return still gets its offer a moment after the microphone goes off. The camera counts at once.
The cost: in an audio-only call's first minute, offers are held rather than paused (the call
pause, its toast and the withdrawal of a visible nudge come at 60 s).

**Presenting and watching (the presenting guard).** While some display is mirrored or something
keeps the display awake (slides, a video, a keep-awake tool; `InputSample.presentingCause`, a
mirrored display named first), Breakpoint gets quieter, not silent:
- `typingPause` opportunities are dropped (`suppress(.presenting(cause))`, §2.5 step 5): nothing
  is offered because the person stopped typing to watch;
- an eye rest never counts down to start by itself: it is a plain offer (Start / Not now), and a
  countdown already running stops as if a key were pressed (§3.1);
- offers from an agent run or a long command still appear as the usual small nudge, which starts
  nothing unless the person chooses Start. Keep-awake tools hold the assertion all day, so the
  guard must never stop every offer.
The guard is not a pause: the menu bar keeps its due or idle shape. "Why not now?" names it when it
is what keeps a well-overdue break from a pause in typing (§3.7).

**Pause reasons (`PauseReason`, §7.1).** While any is active, no nudge appears and the menu bar
shows the paused shape (§3.7):
- `manual(until:)` — from the Pause menu: 30 min, 1 h, or until tomorrow (05:00 local).
- `call(CallSignals)` — microphone on for 60 s and/or camera in use, if "Pause during calls" is on.
  Copy names the signal, not an app: "Paused: microphone is on", "Paused: camera is on",
  "Paused: microphone and camera are on". **Resume now** ignores the current call until all
  call signals have stopped.
- `windDownWrappedUp` — after the user chose Wrap up (§2.8), until 05:00 local.

Timers keep accruing during pauses (screen time is real), but a call never turns idle into away.

**Cool-downs.**
- **Resume cool-down:** no nudge for 60 s after any pause reason ends, after returning from away,
  or after unlock/wake.
- **Nudge spacing:** no nudge within 10 min of the previous nudge or of the end of any break.
- **Kind spacing:** after a nudge for a kind is declined or ignored, that kind is not offered
  again for 10 min (another due kind may be). A break the person started is never a refusal.
- **Saying no again and again:** from the third refusal in a row of a slot (the still-time slot
  `move`, `walk`, `breathe`; or `eyes`), each refusal spaces that slot for its whole cadence
  instead of 10 min (`Timing.refusalsBeforeCadenceSpacing` = 3; `BreakEngine.spacingAfterRefusal`).
  So someone who turns everything down is asked about each kind once per the cadence they chose,
  not every 10 min. A break of that slot the person started, or away time that resets its timer
  (§2.3), clears the count. Nothing is announced: the status still shows the break as due, and
  "Why not now?" says "Spacing out stretches: next one from 15:40" (§3.7). An offer held while
  typing or while a microphone is on was never shown, so it is not a refusal; under the presenting
  guard an agent's nudge that is turned down or left to go counts like any other (keep-awake tools
  hold the guard on all day, so not counting it would bring back an offer every 10 min).
- **After a breather:** no stretch, walk or breather for one move cadence from its end (§2.3).

### 2.5 Opportunities and the engine

An `Opportunity` has a kind, an optional source and session, a creation time and an expiry
(creation + 30 s):
- `agentStarted` — an `agentStarted` event arrived (§2.6).
- `longCommand` — a shell `commandStarted` has had no `commandFinished` for 20 s and its command
  name is not on the interactive denylist (`vim nvim vi nano emacs less more man ssh mosh top htop
  btop tmux screen watch tail claude codex cursor-agent agent gemini copilot aider python python3
  node irb psql mysql sqlite3 fzf`, data in Core).
- `typingPause` — strict mode off, no key press for ≥ 8 s, user present, and some kind's timer is
  ≥ 1.5 × its cadence. At most one per continuous typing pause.
- `manual` — the user chose Take a break (bypasses everything below; starts the overlay directly).

`BreakEngine.decide(snapshot, opportunity, now) -> EngineDecision` is a **pure function** of an
`EngineSnapshot` and a clock. Order:
1. `suppress(.surfaceVisible)` if a break overlay, nudge or countdown is showing.
2. `suppress(.paused(reason))` if any pause reason is active.
3. `suppress(.away)` if the user is away.
4. `suppress(.cooldown(until))` / `suppress(.spacing(until))` per §2.4.
5. `suppress(.strictMode)` if strict mode is on and the opportunity is `typingPause`;
   `suppress(.presenting(cause))` if the presenting guard is on and the opportunity is
   `typingPause` (§2.4).
6. `hold(.typing)` / `hold(.pointer)` if input is busy; `hold(.microphone)` while a microphone is
   on but not yet a call (§2.4).
7. If `move` is due (and not kind-spaced or held after a breather): `breathe` if the still-time
   slot was refused (declined or ignored) twice in a row; else `walk` if the opportunity's session has expected run ≥ walk threshold; else `move`.
   For `typingPause` "due" means ≥ 1.5 × cadence.
8. Else if `eyes` is due (same rules): `eyes`.
9. Else `nothing`.

`offer(BreakOffer)` carries kind, length, the opportunity, and the facts for the *why now* line
(minutes overdue, the agent's usual run length). The coordinator evaluates on every event-driven
opportunity and on a 1 s tick for held opportunities; expired ones are dropped silently.

### 2.6 Agent sessions

`SessionTracker` turns `AgentEvent`s into `AgentSession`s keyed by (source, sessionID). States:
`working`, `waiting` (needs the user), `idle`.

| Event | Effect |
|---|---|
| `sessionStarted` | create session, `idle` |
| `agentStarted` | → `working`, start a run. If already `working`, the previous run closes as interrupted (not recorded). Emits an `agentStarted` opportunity |
| `agentActivity` | refresh last-event time; `waiting` → `working` (user approved something). A `tool` of kind `edit` or `command` is counted for the run (resume card, §3.5) |
| `agentNeedsUser` | → `waiting`. With detail `idle_prompt`: only if the session is `working` (likely interrupted); ignored on an `idle` session. An event naming a `tool` records what the agent asks for (the subject only with snippets on); one without keeps what is known. Leaving `waiting` forgets it |
| `agentFinished` with detail `background` | background work still running (Claude Code `Stop` with `background_tasks` in flight): handled like `agentActivity`, the session stays (or becomes) `working`, nothing ends |
| `agentFinished` | → `idle`. Detail `aborted` or `interrupted`: run discarded, no resume card. Detail `error`: run not recorded, resume card says why (`reason`). Otherwise record run length and keep the agent's last message (snippets on) |
| `subagentFinished` | refresh last-event time only |
| `sessionEnded` | remove session |
| `commandStarted` / `commandFinished` | tracked as `RunningCommand` (source `shell`, session = shell PID), not as sessions. `commandFinished` carries the exit status and duration (`durationMS`, else time since `commandStarted`) |

- **Interrupt fallback.** Claude Code sends no event when the user interrupts. A `working`
  session with no event for **10 min** (Claude Code, which sends `agentActivity` on every tool
  call) or **60 min** (every other source) becomes `idle`; its run is discarded. A later
  `agentFinished` on that session is still handled normally.
- **Relayed duplicates.** An event with `via = "claude-code-hooks"` and source `cursor` (§5.4) is
  dropped when the native Cursor integration is installed, and accepted otherwise.
- **Expected run length** = median of the source's last 20 recorded runs (default 90 s), stored in
  `sessions.json`.
- Sessions with no event for 2 h are removed; commands with no `commandFinished` after 60 min are
  removed.
- Display names: `claude-code` → Claude, `cursor` → Cursor, `codex` → Codex, `copilot` →
  Copilot, `gemini` → Gemini, `shell` → the command name; any other source string as sent.

### 2.7 Outcomes and history

`BreakOutcome`: `completed`, `endedEarly`, `declined` (Not now), `ignored` (nudge or countdown
timed out or was cancelled by input), `credited` (natural break from away time). `skipped` is
written only by earlier versions (a break ended with Skip in its first seconds): it is still read
from history, never recorded now, and counted nowhere.
`HistoryStore` appends one `HistoryEntry` per offer or break (kind, outcome, opportunity kind,
source, start, duration, movement-detected flag). The UI never shows counts of `skipped`,
`declined` or `ignored`. "Breaks taken" = `completed` + `endedEarly` + `credited`. A day runs 05:00 to 05:00.

How a break that started is recorded ("80%" is of the planned length plus extensions; timers per §2.3):

| Ending | Recorded |
|---|---|
| The timer reaches 0 (not `walk`), **Done**, the hard ceiling | `completed` |
| I'm back / Welcome back, Back to work | `completed` at ≥ 80%, else `endedEarly` |
| Skip, Esc twice (from 3 s, the Skip guard) | `completed` at ≥ 80%, else `endedEarly` |

None of these endings refuses the break: a break the person started counts, however soon they
closed it. Only `declined` and `ignored` (an offer never started) are refusals (kind spacing,
§2.4; `breathe` after two refused stretches, §2.5; a cadence of spacing from the third refusal
in a row, §2.4). A `completed` or `endedEarly` stretch, walk or breather clears the count of
refused stretches, an eye rest clears the count of refused eye rests, and so does away time that
resets the timer.

**All-time totals** (`HistoryTotals`, the popover's figures, §3.8), counted from the first entry:
- **moving** = the real elapsed `duration` of every `move` and `walk` entry that is `completed`
  or `endedEarly`, however short (a 5-second stretch adds 5 seconds); each adds at most
  `Timing.walkCeiling` (a guard against a damaged line). The figure is rounded down to minutes.
- **stretches** = those `move` entries; walks count toward moving only. **eye rests** = `eyes`
  entries that are `completed` or `endedEarly`. A short break counts once, with only its seconds.
- Not counted: `breathe` (done sitting down), `credited` away time (nobody knows what was done
  while away), `declined`, `ignored`, `skipped` (older history only), and previews (never
  recorded).
- The app scans `history.jsonl` once at launch (`HistoryStore.totals()`, reading its own compact
  lines from the raw bytes: a year of history in well under 0.1 s), then adds each entry it records;
  Undo of a credited break rescans; Delete all data resets them. Opening the popover reads nothing.

### 2.8 Wind-down

Off by default. After the user's stop time (e.g. 23:00, on chosen days), at the next
`agentFinished`, show the wind-down card (§3.6): "It's 23:20." / "You planned to stop at 23:00."
with **15 more minutes** and **Wrap up**. Each choice of 15 more minutes requires a longer hold
(3 s, then 6 s, then 10 s for every later one that night). Wrap up shows a "Where you left off"
note built from open agent sessions (project folder + prompt snippet) that the user can copy, and
sets the `windDownWrappedUp` pause until 05:00.

### 2.9 Optional: AirPods movement check (experimental, off by default)

If enabled and AirPods are connected, read head motion (`CMHeadphoneMotionManager`) during `move`
and `walk` breaks and mark the entry "movement detected" when rotation activity crosses a simple
threshold. Shown as a small tick in history. No rep counting. Turning it on triggers the system
Motion access prompt; this is the only prompt in the app and it is optional. Degrades silently
when unavailable or denied.

### 2.10 Out of scope

iPhone companion, Apple Health, self-experiments, team features, payments, analytics,
Windows/Linux, VS Code extension, standing-desk control, any cloud service. Also:
- scores of any kind, "skipped" or "snoozed" counters, streaks;
- hard modes that disable or hide Skip, and caps on snoozes or skips;
- tracking of apps or websites used, per-app call attribution, reading window titles;
- anything needing a permission prompt for core use: calendar or Focus-mode pausing, screen
  sharing / recording / video / fullscreen-app detection, dictation detection, notifications
  (the presenting guard and short microphone use, §2.4, read only permission-free signals);
- posture or blink mini-reminders, custom backgrounds, textures, custom sounds, Lock Screen
  countdown, a Lock Screen button on the overlay;
- Claude Code / Cursor / Codex *plugin* packaging (Breakpoint writes settings files), HTTP hooks,
  VS Code agent hooks, Aider, OpenCode, Windsurf.

### 2.11 Updates

The app's only network access. Breakpoint is not signed by Apple (no Developer ID, no
notarization); its updates are signed with the project's own Ed25519 key instead.

- **One version number.** `BreakpointVersion.current` (`Models/Version.swift`): `scripts/build-app.sh`
  writes it into `CFBundleShortVersionString`, `breakpoint --version` prints it, About shows it.
- **Releases.** `scripts/release.sh X.Y.Z "line"` sets the version and pushes tag `vX.Y.Z`;
  `.github/workflows/release.yml` builds the app (ad hoc signed), zips it, signs the zip with the
  release key (repository secret `UPDATE_SIGNING_KEY`, checked against the committed public key) and
  publishes `Breakpoint-X.Y.Z.zip`, `update-feed.json`, `install.sh` and `SHA256SUMS`
  (docs/RELEASING.md). The feed: `version`, `notes` (one line), `page`, `archive`, `size`, `sha256`,
  `signature`, `minimumSystemVersion`, `published`.
- **What is fetched.** (1) At most daily, one HTTPS GET of
  `https://github.com/estrindavid/breakpoint/releases/latest/download/update-feed.json` (GitHub
  redirects to its download host). (2) Only when the person clicks Update, or has turned on
  automatic installs: one GET of the release's `archive`. Both from an ephemeral session (no
  cookies, cache or credentials) with `User-Agent: Breakpoint/<version>`. Nothing about the person,
  their settings, breaks or tools is sent; GitHub sees the IP address, time and user agent.
- **When.** Automatic checks (`checkForUpdates`, on by default) run at most once per
  `Timing.updateCheckInterval` (24 h; `updateRetryAfterFailure`, 3 h, after a failure), never in the
  first `updateFirstCheckDelay` (2 min) after launch, before onboarding is finished, during a break,
  a call (microphone or camera in use), any pause, or while any pop-up is on screen. **Check now**
  runs at once and never shows the prompt.
- **The prompt** (§3.5) appears when the feed names a newer version that runs on this macOS, at a
  quiet moment: all of the above, plus present and no key pressed for `updatePromptQuiet` (30 s).
  Later, ×, or the prompt hiding itself put that version off for `updatePostpone` (3 days); a newer
  version is offered at once. **Install updates automatically** (`installUpdatesAutomatically`, off)
  installs at such a moment instead of asking; an automatic attempt that stops waits 3 days.
- **Trust.** The feed is read only if it is a JSON object under 64 KB with a valid version and a
  `page` (and `archive`) that is https on github.com inside the repository. Update installs only when
  this copy has a release key (`UpdateKey.publicKeyBase64`, written by `scripts/release-keygen.sh`; a
  copy built while it is `nil` opens the download page instead, and no release is published
  without it) and the feed entry is signed. Before anything is unpacked, the archive's size and SHA-256 must match the feed
  and the signature must verify over `breakpoint-update-v1 / version / size / sha256`, so it cannot
  be moved to another archive or version; the version must be newer than this one, so an old signed
  release cannot be replayed (downgrades are refused).
- **Installing** (`UpdateInstaller`): the app must be a writable bundle (not a development build,
  not translocated — a quarantined copy run where it was downloaded — and not in a folder this user
  cannot change); otherwise About says why and offers the download page. The archive is unpacked
  with `ditto` into `.Breakpoint-update-<id>/` next to the app; the bundle inside must be the only
  app, with our bundle identifier, the signed version, an executable, and no quarantine flag
  (Breakpoint does not set `LSFileQuarantineEnabled`, so its downloads carry none; it never removes
  one either). Then the two bundles are exchanged in one step (`renamex_np(RENAME_SWAP)`), the swap
  is recorded in `pending-update.json`, and `breakpoint update-relaunch` — run from the old copy,
  now in the staging folder — waits for the old process to quit, opens the new copy, and waits
  `updateConfirmTimeout` (30 s) for it to confirm. Confirmed: the old copy is deleted. Not
  confirmed, or the new copy died: it is stopped, the bundles are swapped back, the old copy is
  reopened and says "The update to X didn't start, so Breakpoint is back on Y", and that version is
  not installed automatically again. Never during a break: a break that starts while downloading
  stops the install before the swap. Any failure leaves the app as it was and offers the download
  page with one plain sentence.
- **After an update** the new copy shows "Breakpoint is now X" and registers the login item again
  if Open at login is on (a new ad hoc build may be a new app to macOS). The optional Motion
  permission is tied to the exact build for ad hoc apps, so macOS may ask again the next time the
  AirPods check runs.
- `updates.json` (§8) keeps the last attempt and check, the newest release seen, the postponed
  version and a version whose install failed, so a relaunch neither checks early nor asks again.

---

## 3. Screens

### 3.0 Shared rules for pop-ups (nudge, countdown chip, resume card, away note, toasts, wind-down)

- **Anchor.** All pop-ups except the countdown chip appear on the **active display** (the display
  under the pointer when the pop-up appears) at the position chosen in Settings: top centre
  (default), top left or top right. Top edge 8 pt below the bottom of the menu bar or notch
  (`min(visibleFrame.maxY, frame.maxY − safeAreaInsets.top) − 8`); side positions inset 16 pt.
  They stack downward with 8 pt gaps, **at most 2 at once**. Priority when a third arrives
  (lowest is removed): needs-you resume card > wind-down > other resume cards and away note >
  toasts > nudge. `TransientPanelStack` (§7.2) owns this; no surface positions itself.
- **Never steal focus.** Every pop-up is an `NSPanel` with `.nonactivatingPanel`, level
  `.statusBar`, `collectionBehavior` `[.canJoinAllSpaces, .fullScreenAuxiliary]`. Clicking a
  button must not change the frontmost app. Only the wind-down card may become key, and only
  after the user clicks into it.
- **Hidden from captures.** All Breakpoint windows set `sharingType = .none` (best effort).
- **Material** (§4.5), **one colour moment** per pop-up: the badge carries colour (mint for a
  break kind, indigo for agent working, amber for needs-you). Buttons on pop-ups are neutral glass;
  everything else uses the neutral text steps (§4.2). The wind-down card has no badge, so its
  primary button is mint.
- **Buttons.** Capsules. On pop-ups: 34 pt high (measured), 15 pt label at 75% white, 14 pt
  horizontal padding, 9 pt gap. Primary = 10% white fill; secondary = 1 pt outline at 14% white;
  tertiary = text only at 75%. Small card buttons (resume, away note): 28 pt high, 13 pt label.
- **Buttons under the pointer** (every capsule, the popover's gear, the pop-up ×, settings preset
  cards; `PointerLight` in Design/): on hover the fill rises +6% white, a soft light comes up
  inside the control where the pointer is and follows it with a slight lag, the rim catches that
  light, and the control rises 1 pt on a contact shadow (not text-only buttons, the gear or ×).
  Press: scale 0.97 and the light blooms under the pointer; a keycap inside the button presses
  too (½ pt down, brighter). Mint primaries stay solid mint; the light brightens them. The
  keyboard focus ring (2 pt mint at 60%) grows out from the rim as it fades in.
- **Auto-hide.** Hovering any self-dismissing pop-up pauses its timer. When the pointer leaves, a
  card (resume card, away note, toast) resumes with what it had left, but at least half its full
  time (`Timing.cardHoverResumeFloor`), so hovering never shortens its stay; the nudge restarts at
  half (§3.1). Cards show their time as a lit edge (the time rim, §3.5). A 16 pt × close button
  appears at the top-leading corner on hover.

### 3.1 Nudge card (the heads-up)

*Purpose: offer a break at an opportunity, readable in under a second, ignorable at no cost.*

- **Size:** 410 × ~122 pt, radius 28, padding 14 (measured).
- **Row 1:** kind badge (44 pt circle, Breakpoint gradient fill §4.2, white SF Symbol 20 pt
  semibold: `eye`, `figure.arms.open`, `figure.walk`, `wind`) · 12 · text column:
  - Title, 20 pt semibold, 100%: the offer, **always kind and length**, ≤ 7 words, question form:
    "20-sec eye rest?", "2-min stretch?", "6-min walk?", "1-min breather?".
  - Subtitle, 15 pt regular, 60%: context. `agentStarted`: "Claude is working";
    `longCommand`: "swift test is running"; `typingPause`: "52 min at the screen".
- **Row 2** (12 pt below, aligned to the text column): **Start** (primary) · **Not now**
  (secondary).
- **Hover** (pointer rests 300 ms): × appears; the subtitle cross-fades (0.2 s) to the *why now*
  line, e.g. "18 min overdue · Claude usually takes 4 min"; the hotkey
  keycaps in the buttons (11 pt) come forward. The keycaps are always there, at 40% while the card
  rests, so a button never changes size or moves as the pointer reaches it.
- **Ignored:** after 10 s without interaction (hover pauses; restarts at 5 s on exit) it folds
  back up into the point it grew from (§4.6, 0.35 s ease-in) and records `ignored`.
- **Keyboard:** the card never takes focus, so it cannot receive Esc. While a nudge is visible
  `HotKeyCenter` registers **⌃⌥⌘B = Start** and **⌃⌥⌘. = Not now** (`RegisterEventHotKey`, no
  permission) and unregisters them when it closes. Both can be turned off.
- **Withdrawn** immediately (settle and fade 0.2 s, nothing recorded) if an agent needs the user, a pause
  reason starts, or the user becomes away.
- **Exit on Start:** card scales 1.0 → 1.04 and fades over 0.2 s while the overlay entrance begins.
- **Eye rest auto-start** (`eyes` only, setting on by default) — the warning ladder:
  1. The card's title counts down: "20-sec eye rest in 10" (rolling digits) while a 2 pt ring
     (white 80%) sweeps around the badge.
  2. At 5 s remaining the card **becomes** the **countdown chip** (§3.2) at the pointer.
  3. At 0 the overlay entrance starts (§3.3).
  Any key press, any click outside the card, any scroll, Not now, or hovering the card
  **cancels** auto-start, and so do the presenting guard coming on and a microphone coming on
  (§2.4). While either is already on, an eye-rest offer is a plain offer with no countdown. Cancelled during step 1: the card reverts to a normal offer and stays 10 s.
  Cancelled during step 2: the chip folds away and `ignored` is recorded.

### 3.2 Countdown chip (eye rest auto-start only)

Glass capsule 32 pt high (radius 16), badge 22 pt + "Eye rest in 5" 13 pt semibold with rolling
digit. It sits 20 pt right of and 20 pt below the pointer, clamped inside the pointer's display,
and follows the pointer every frame. Ignores mouse events.

**Arrival: the card becomes the chip** (`LiquidMotion.handoff`, 0.8 s). The nudge card hands
itself to the chip's panel (`PopupHandoff` through `TransientPanelStack`), which starts exactly
where and as the card was. The glass gathers in (height first, on a quicker critically damped
spring) and glides to its place beside the pointer on a spring (response 0.6, damping 0.86),
following the pointer if it moves; the kind badge travels and shrinks from 44 to 22 pt as one
object; the card's words blur out in the first 0.2 s and the chip's come in as it settles. Under
Reduce Motion, or when the card is not on screen, the card fades and the chip arrives with the
pop-up entrance (§4.6) at its leading end. **Exit:** swells and fades (0.2 s) when the overlay
starts; folds into its leading end (0.35 s) when cancelled.

### 3.3 Break overlay: shared skeleton

- **Windows.** One borderless `NSPanel` per display at `.screenSaver` level,
  `[.canJoinAllSpaces, .fullScreenAuxiliary]`, `.nonactivatingPanel`; the active display's panel
  `canBecomeKey` and becomes key without activating Breakpoint. Rebuild on
  `didChangeScreenParametersNotification`. The **content column appears on the active display
  only**; other displays show the backdrop plus a 13 pt timer at 60% centred 40 pt below their
  safe-area top (setting "Show the full break on every display", off).
- **Backdrop** (bottom to top): behind-window blur of the live desktop (`NSVisualEffectView`,
  `.behindWindow`, `.fullScreenUI`, dark); scrim `#070A12` at 60%; a vignette (the scrim colour
  deepening to 45% more in the corners, clear around the column); the Breakpoint aurora; a hush
  (scrim colour at 22% behind the column, fading out by 42% of the display's width); and a fixed
  fine grain (monochrome noise, 128 px tile, 3.5%) so no gradient bands. The **aurora** is five
  soft lights (mint, teal `#26A8B8`, indigo, deep blue `#2B3FB8`, a small second mint), each with a
  Gaussian-like falloff, drifting on their own slow paths that all repeat once a minute
  (`AuroraField`). It is drawn twice: in deep tones (`#0A5A4C`, `#0B4A63`, `#232C82`, `#0E1A5C`)
  over the scrim at 55%, so the grey of the blurred desktop turns to colour, then as light
  (plus-lighter) at 12%. Mint is always the strongest light. The user's own desktop stays faintly
  present. The column's text keeps its contrast: behind the timer and title the backdrop is no
  brighter than with the plain scrim.
- **Column** (centred, max 640 pt wide, text group's optical centre at 44% of display height):

  | # | Element | Spec |
  |---|---|---|
  | 1 | Agent chip | Top edge 40 pt below safe-area top. Capsule 28 pt, dot 8 pt + 13 pt semibold. Working: indigo dot pulsing 0.5 Hz, "Claude is still working · 1:42". Done: mint dot, "Claude is done. No rush." Needs you: amber dot, "Claude needs you". Several sessions: the most urgent (needs you > working > done), or "2 agents working". No agent: time of day "14:05", 13 pt, 60% |
  | 2 | Title | SF Pro Rounded bold, size = clamp(34, 3.3% of display width, 56) pt (≈ 50 pt on 1512 pt), 100%, one line |
  | 3 | Instruction | SF Pro Text 19 pt regular, 85%, max 2 lines, baseline 58 pt below the title baseline |
  | 4 | Kind line (optional) | e.g. `move` cue chip, 16 pt below the instruction |
  | 5 | Hairline | 1 pt, 160 pt wide, white 25%, 44 pt below the instruction (or kind line) baseline |
  | 6 | Guide | Per kind (§3.4). A plain timer's centre sits 66 pt below the hairline; a ring's top sits 32 pt below it |
  | 7 | Controls | Centre 96 pt above the display's bottom edge. Capsules 34 pt high, 15 pt semibold, 12 pt gaps, translucent glass with a light rim. Order: Skip, then kind controls; the primary is rightmost and mint |
  | 8 | Hint | 12 pt below the controls, 11 pt, 50%, keys drawn as keycaps: "[esc] [esc] to skip · [return] I'm back" |

- **Timer** (wherever shown): SF Pro Rounded semibold 38 pt, monospaced digits, 60% white,
  format `m:ss`, rolling digits. It is always quieter than the title and instruction, except in
  `breathe`, where the ring is the content.
- **Skip guard.** Skip is disabled for the first 3 s; a 14 pt ring inside the button fills over
  those 3 s. Keys and clicks on Skip during the guard do nothing.
- **Esc.** Two presses within 1.2 s skip: the break ends and still counts (`endedEarly`, or
  `completed` past 80%, §2.7). A single press pulses the hint line (opacity 1 → 0.5 → 1
  over 0.3 s).
- **Done.** Once ≥ 80% of the planned length has elapsed, Skip relabels to **Done** (records
  `completed`) and becomes the **mint primary**, matching the hint "[return] Done" (it stays in
  Skip's place, so the button under the pointer never changes job; when Back to work is showing,
  that is the mint one and Done stays neutral). Not shown on `walk` (I'm back covers it).
- **1 more minute** (`move` and `breathe` only) extends the *break* by 60 s, at most twice per
  break, then disappears. On `move` it appends 60 s replayed from the routine just done
  (`RoutineReplay`): its steps in order, starting where the previous extra minute stopped, whole
  steps while they fit, then the next one shortened to what is left (or, when under 10 s would
  be left, the last step lengthened instead).
- **Keyboard.** Return triggers the primary; Tab and arrow keys move between controls.
- **Needs you during a break:** the chime plays once (if on, §4.7); the chip turns amber
  (cross-fade 0.3 s); the primary becomes **Back to work** (mint, focused, replacing I'm back);
  the hint shows "[return] Back to work". The break never ends by itself because of this. Back to
  work records `completed` if ≥ 80% elapsed, else `endedEarly`.
- **Ending.** The timer reaching 0 records `completed` (not `walk`, §3.4). Lock, display sleep or
  away during a break do not end it; if the timer ends while locked, the overlay closes and
  records `completed`.
- **Closing moment.** A break that ends `completed` (the timer, Done, or Esc or I'm back past
  80%; not Back to work, not a break ended early, never a preview) holds for `Timing.completionMoment`
  (1.2 s) before the exit: the instruction, kind line, guide, controls and hint fade, the ring
  closes from where it stood into a full mint ring with a check drawn inside (`eyes`, which has
  no ring, gets a 64 pt one centred on its timer), and the title becomes a short **closing line**
  that rotates per kind: it names the time spent or the routine ("That's two minutes.",
  "Shoulders done.", "Six minutes on your feet."), never praise and never a count. The outcome is
  recorded when the moment begins. Esc or Return during it ends it at once. The closed ring is
  the same luminous ring the break drew (§3.4), its glowing head running to the top. The moment
  happens on the settled overlay (the aurora keeps drifting); the exit below begins when it ends,
  and the closing line and the check leave with the content, the line defocusing as the title
  would. Only one ending plays: a break that ends any other way goes straight to the exit.
- **Exit:** the content fades over 0.2 s while the title defocuses (blur 0 → 4); the backdrop
  lets go in layers, the reverse of the entrance: the aurora fades with the content (0–0.35 s),
  the scrim and vignette lift (0.15–0.6 s), and the desktop comes back into focus last
  (0.3–0.75 s). Then `FocusRestorer` runs (§7.2).
  If an agent finished or needs the user, the resume card follows (§3.5).
- **Safety.** `OverlayWatchdog` (§7.2) guarantees a frozen app can never leave displays covered;
  a hard ceiling closes the overlay at planned length + extensions + 60 s (`walk`: 30 min) and
  records the outcome by the rules above.
- **VoiceOver** announces "Break started: {title}, {length}", "Break over" and "{Agent} needs you".

### 3.4 Overlay per kind

| Kind | Title / instruction (examples, rotate) | Guide | Controls (primary last) |
|---|---|---|---|
| `eyes` | A tiny task at a distance, rotating: "Find something green far away" / "A plant, a sign, a roof. Rest your eyes on it."; "Count the windows in view"; "Trace the far horizon line"; "Find three distant colours"; "Pick the smallest far-off thing"; "Watch something far away" | Timer only (`0:19`) | Skip |
| `move` | Step name, e.g. "Shoulder-blade squeeze" / the step's one-line instruction; kind line = cue chip (capsule 24 pt, 12% white fill, 12 pt semibold, e.g. "3 s squeeze · 3 s release") | **Pace ring** 140 pt, 4 pt mint stroke (luminous: the arc brightens from 30% mint at its tail to full mint at its head, with a soft mint glow at the head; Increase Contrast: solid, no glow), pacing the step's tempo (below); the phase word inside ("Up", "Hold", "Other side"; SF Pro Rounded medium 22, as on `breathe`); step dots below (6 pt, 8 pt gap: done mint, current white, upcoming 25%); the whole routine's time left under the dots, 15 pt 60% ("1:24 left", as on `breathe`) — the screen's only clock. A step without a tempo shows the plain step ring (luminous too) with its seconds inside | Skip · 1 more minute |
| `walk` | "Take a walk" / "We'll chime when Claude needs you." (without an agent: "Come back whenever you're ready."; once the agent needs you: "Claude needs you. Head back when you're ready."); kind line = an idea chip, rotating: "Refill your water", "Take the stairs", "Step outside for a minute", "Walk a lap of the room", "Water a plant", "Open a window for some air" | Ring 160 pt, 3 pt mint (luminous, as on `move`), fills toward the target; elapsed time inside as the timer | Skip · **I'm back** |
| `breathe` | "Breathe with the ring" / "In as it grows, out as it shrinks." | Ring 220 pt, mint 20% fill + 3 pt mint stroke, scales 0.72 → 1.0 over 5.5 s and back over 5.5 s (sine ease-in-out); "In"/"Out" inside, SF Pro Rounded medium 22 pt, cross-fading at each turn; time left below, 15 pt 60% | Skip · 1 more minute |

- `move` **pace ring** (`TempoPacing`, pure, a function of the seconds into the step like the
  breathing ring): one repetition of the step's tempo plays over and over. A phase that moves
  out ("up", "squeeze", "reach", "one side") fills the mint arc clockwise from 12 o'clock over its
  seconds; the phase that returns ("down", "release", "other side") empties it; a "hold" after a
  movement keeps it full (a hold that opens the repetition fills it); a one-phase repetition
  ("circle", "shake", "rest") sends a 22% arc once around the ring per repetition, with no jump.
  Each phase eases with the `breathe` curve (sine ease-in-out). A mint disc inside brightens with
  the arc (10% → 30%, the `breathe` Reduce Motion range), so the rhythm reads from the corner of
  the eye. At each turn the word dims to 35% over the last 0.25 s of a phase and the next word
  rises from 35% over the first 0.25 s of the next (never at the step's own start or end), so the
  ring always has one word. **Reduce Motion:** the arc and disc
  move in whole-second steps (a 3 s "up" reads 1/3, 2/3, full; "down" 2/3, 1/3, empty), the
  travelling arc jumps by the second, and the word swaps with a 0.2 s fade.
- `move`: steps change by sliding the old step 12 pt left while fading and the new one in from
  12 pt right (0.3 s ease-in-out); the ring resets with a 0.2 s fade. A soft tick sounds at each
  step change the timer makes (§4.7). → / ← go to next / previous
  step (announced). Footer on this screen only: "General wellness, not medical advice." 11 pt 50%.
- `walk`: elapsed counts up; at the target the ring is full and the overlay stays until I'm back
  or the 30 min ceiling. I'm back records `completed` if elapsed ≥ 80% of the target, else
  `endedEarly`. After 30 s with no input the overlay goes **ambient**: scrim 85%, all text except
  chip and timer at 50%, controls hidden until the pointer moves. When input returns after ≥ 60 s
  idle it wakes (0.3 s) and the primary reads "Welcome back". Breakpoint never blocks display sleep.

### 3.5 Resume card, away note and toasts

**Resume card** — shown when a break ends and an agent finished or needs the user during it, or
when the user returns from away and an agent finished or needs them meanwhile. It answers "what
happened while I was away?" at a glance: one strong line, at most one supporting line.
- 360 pt wide, radius 28, padding 14.
- Row 1: source badge 28 pt (indigo; amber if anything needs you; glyph ✓ finished, ! stopped with
  an error or a command failed, raised hand needs you) · the strong line, 13 pt semibold, one line,
  tail-truncated · on a one-row card, the project folder, 12 pt 60%, trailing, middle-truncated.
  - Finished: "Claude finished · ran 6 min".
  - Stopped with an error, in plain words from the tool's reason (Claude Code `StopFailure`
    `error`): "Claude hit the usage limit" (`rate_limit`), "Claude could not sign in", "Claude
    stopped: server error", "Claude stopped: reply too long", …; unknown: "Claude stopped with an
    error".
  - Needs you: "Claude needs you".
  - A long shell command: "swift failed after 4 min" (exit status not 0) / "swift finished in
    6 min" (under a minute: "in 45 s").
- Row 2 (one row only, optional): the supporting line, 12 pt 85%, one line, tail-truncated:
  - finished: the first line of the agent's last message (snippets on), else the prompt snippet
    (snippets on), else counts "7 edits · 12 commands", else nothing;
  - stopped with an error: the prompt snippet (snippets on), else the counts;
  - needs you: what it asks for. Snippets on: "Wants to run `npm install`", "Wants to edit
    `Auth.swift`", "Wants to open `example.com`" (the subject in 12 pt monospaced, truncated first).
    Snippets off: "Wants to run a command", "Wants to edit a file", "Wants to open a web page".
    Either way: "Has a question for you", "Has a plan for you to review", "Wants to use a tool";
  - a command: nothing.
- More than one row: one card titled "3 agents finished" ("2 commands finished", "3 runs finished"
  for a mix; "Claude needs you" or "2 agents need you" when any needs you), rows of name · folder
  with a short status on the right ("6 min", "usage limit", "error", "needs you", "failed"), needs
  you first, then failures, then the rest; max 3, then "+N more".
- **Long shell commands** appear when a command tracked by the shell integration ends during a
  break or while away, ran at least 20 s (the `longCommand` threshold) and was not interrupted
  (exit status 130, Control-C). The row is keyed by the shell.
- **A run still going** (resumed working, or a `Stop` with background work) has no row.
- Auto-hides after 10 s (needs-you cards stay until dismissed). **A needs-you row is removed as
  soon as its session leaves `waiting`** (resumed working, run ended, session ended); a card left
  with only other rows starts its 10 s then, and a card left with none goes.
- Click anywhere dismisses. **Keyboard:** the card never takes focus, so while a resume card shows
  and the nudge hotkeys are on, ⌃⌥⌘. dismisses it (a visible nudge takes the key first: it still
  means Not now). Hover shows the key as a keycap in row 1 while it would reach the card.
- **Privacy.** The agent's last message and what a waiting agent asks for are treated like prompt
  snippets: sent by `emit`, kept and shown only while "Keep prompt snippets" is on, reduced to one
  line (Markdown removed, ≤ 120 characters; a request ≤ 60, a file by its name only, a page by its
  host only) with the same secret masking as prompts, kept in memory only (never in history,
  `sessions.json`, the status reply or logs), and forgotten when the setting is turned off. The
  outcome, durations, the failure reason, the kind of request, counts, folder and command name are
  not sensitive and are shown either way.

**Away note** — a single-line glass capsule 44 pt high: kind badge 32 pt (the larger credited
kind; inset 6 pt, concentric) · "Counted your 6 min away as a break" 13 pt · **Undo** (tertiary,
28 pt). Auto-hides after 10 s. Undo → §2.3, then the toast "Timers restored".

**Time rim** — every card that hides itself (resume card while nothing needs you, away note,
toasts) shows its time on its edge: a 1.5 pt line of white at 45% runs 2 pt inside the card's
glass rim, centred on the top edge. It draws itself out from the top centre as the card arrives
(0.45 s ease-out), then draws back toward the top centre at the card's own pace, linear, both ends
together, so the card visibly runs out just before it drifts away. With the pointer on the card
the line stops and brightens to 70% (0.2 s); when the pointer leaves it eases up (0.45 s) to what
the card has left, at least half, and carries on. A needs-you card has no rim until it starts
hiding itself, when the rim draws itself out. One `CardCountdown` drives both the line and the
timeout, so the line reaches the top centre exactly when the card goes. Increase Contrast: 80%
(held 100%). Reduce Motion: the line never moves along the edge; the whole line stays and fades
with the time left. Decorative: hidden from VoiceOver.

**Toasts** — same capsule without a badge, 3 s: "Timers restored". The call-pause toast
"Breaks paused: microphone is on" with **Resume** (tertiary) appears only if the pause began while
a break was due or withdrew a visible nudge; otherwise call pauses are silent (menu bar and
popover only), except the first one, whose toast carries its first-use hint (§3.12).

**Update prompt** (§2.11) — "Breakpoint 0.3.0 is ready".
- The resume card's shape: 360 pt wide, radius 28, padding 14. Row 1: brand-gradient badge 28 pt
  with an arrow (Breakpoint's own news; the one colour moment) · the title, 13 pt semibold. Row 2:
  the release's one line of notes, 12 pt 85%, up to two lines (fallback "A new version is on
  GitHub."). Right-aligned 28 pt buttons: **Later** (secondary) · **Update** (primary: downloads,
  verifies, replaces and reopens), or **Download page** when this copy cannot install itself.
- Installing: the second line says the step ("Downloading…", "Checking the signature…",
  "Installing…", "Reopening Breakpoint…") in 60% white; no buttons; the card stays until Breakpoint
  reopens. Failed: badge grey with "!", title "Couldn't install 0.3.0", the reason in one sentence,
  **Close** · **Open download page**.
- Priority of a toast; an offer hides itself after `Timing.updateCardAutoHide` (20 s; hover holds
  it, its lit edge is the timer); × on hover. Never takes focus. After an update the new copy shows
  the toast "Breakpoint is now 0.3.0".

### 3.6 Wind-down card

- 410 pt wide, radius 28, padding 20.
- Title SF Pro Rounded 17 pt semibold "It's 23:20."; body 13 pt 85% "You planned to stop at
  23:00."; buttons right-aligned, 28 pt: **15 more minutes** (secondary) · **Wrap up** (primary,
  mint, Return once the card is key).
- **Hold:** 15 more minutes shows "Hold 3 s" (then 6 s, 10 s). While held, a 20% mint fill sweeps
  left to right at linear speed; releasing early springs it back (0.3 s) and does nothing. No
  shaming copy, ever.
- **Wrap up:** the card grows (spring 0.45/0.85) into "Where you left off": a monospaced 12 pt
  list, one line per open session (folder + snippet); **Copy note** (primary, ⌘C) · **Done** (Esc).
- Stays until answered; becomes key only after the user clicks into it.

### 3.7 Menu-bar status item

Template image (18 pt mark), drawn in code, plus optional text. The item has two independent
layers so every state differs by **shape**, not colour:

| Layer | State | Shape |
|---|---|---|
| Mark | idle | plain mark: the outlined tag with its two oval eyes |
| Mark | break due | the mark's notch filled (a rounded block with the eyes knocked out) |
| Mark | on a break | the whole mark filled (eyes knocked out) |
| Mark | paused (any reason) | the mark with a single horizontal pause bar in place of the eyes |
| Badge | agent working | small filled dot at the trailing-bottom corner, breathing at 0.5 Hz (static under Reduce Motion) |
| Badge | agent needs you | small hollow ring at the same spot, static |

Mark priority: on a break > paused > break due > idle. Text (setting): none (default) / time to
next break ("6m", "due") / agent state ("Claude 3m"); "Paused" when paused. Tooltip and
accessibility label give one sentence with the cause, e.g. "Paused: microphone is on". Left click
opens the popover; right click opens a menu: Take a break ▸ (kinds), Pause ▸, Settings…, Quit
(headed by the status sentence and, while a due break is not offered, the "Why not now?" line).

**Movements.** Besides the 0.2 s cross-fade between states, the mark has three one-shot movements,
each played once at the moment it means something and never looped (`MarkCuePolicy`, Core; drawn
as template-image frames, so they work on light, dark and tinted menu bars):

| Moment | Movement | Length |
|---|---|---|
| An agent's run finishes normally (`agentFinished` without error, abort or interrupt) and no other agent is working | the working dot slides from its corner into the notch, shrinking, and disappears | 0.4 s |
| An agent starts needing you (the badge becomes the ring) | the two eyes grow about 1 pt taller (1.1 grid units: they widen) and settle back | 0.3 s |
| Wrap up starts the wrap-up pause (the wind-down's end state) while the eyes show | the two eyes fold into the single rest bar of the paused mark | 0.45 s |

A failed, cancelled, stale or ended run is not a finish: the dot just goes. If two moments
coincide, needs-you wins, then finish, then wrap-up. Nothing moves under Reduce Motion, while the
screen is locked or the displays sleep (the new state simply appears, as the breathing dot stops
then too), or for a cue older than 2 s. The limits of §4.1 apply.

**Why not now?** Option-click on the mark shows one line saying what Breakpoint is waiting for,
derived from the engine itself (`WhyNotNow`, Core: it runs `BreakEngine.decide` on the held
opportunity, or on an agent starting this moment, and names the answer), refreshed while the menu
is open. It uses only facts the app shows elsewhere (timers, pause, agents and their states,
typing). Strict mode, the presenting guard and the holds (§2.5 steps 5–6) are named only while a
break is due and not spaced: when every due kind is spaced (kind spacing, a cadence after the third
refusal in a row, or the breather hold), the line names the spacing, which is what still stands
once they lift:

| Engine answer | Line |
|---|---|
| overlay up / nudge showing | "On a break now" / "Offering a break now" |
| paused | the pause sentence, "Paused: microphone is on" |
| away | "Waiting for you to come back" |
| nothing due | "Nothing due: eye rest in 12 min" |
| resume cool-down | "Easing back in after a pause: next nudge from 15:31" |
| nudge spacing | "Spacing out nudges: next one from 15:34" |
| every due kind kind-spaced | "Spacing out stretches: next one from 15:40" |
| stretch held after a breather, no eye rest due | "You took a breather: next stretch from 15:40" |
| held by the typing guard | "Holding the nudge: you are typing" / "…: you are clicking or dragging" / "…: a microphone is on" |
| due, waiting for an opportunity, ≥ 1.5 × cadence | "Waiting for a pause: Claude is idle and you are typing" (quiet ≥ 8 s: "Waiting for your next pause in typing: …") |
| due, waiting for an opportunity, below 1.5 × cadence | "Waiting for an agent run: Claude is idle" / "Waiting for your next prompt: Claude is working" (strict mode adds "(only during agent runs)") |
| due, ≥ 1.5 × cadence, presenting guard on | "Waiting for an agent run: Claude is idle and the display is kept awake" / "Waiting for your next prompt: Claude is working and a display is mirrored" |

### 3.8 Popover

`NSPopover`, 320 pt wide, dark appearance in both system modes, pop-up glass inside (§4.5), inset cards
radius 14. Order top to bottom — status, then the likely action, then detail:
1. **Top bar:** gear button at the top right (menu: Settings… ⌘,, About, Quit ⌘Q).
2. **Status:** caption 13 pt 60% ("Eye rest in" / "Stretch due" / "Paused: microphone is on")
   over one big number, SF Pro Rounded bold 38 pt, monospaced, rolling digits ("6 min"). A 44 pt
   ring at the leading side shows progress toward the break the caption names, with that kind's
   glyph (eye rest: screen time against the eye cadence; stretch: still time against the move
   cadence; during a break: the break's own progress), and "42 min since you moved" 12 pt below.
   Until a break or time away has reset still time, Breakpoint cannot know when the user last
   moved: the first minute after launch reads "Counting from now", not "You moved less than a
   minute ago". The ring is hidden from VoiceOver (the caption and detail line say it). Paused: the number is replaced by "until 15:30" (manual) or nothing (call)
   and a **Resume now** button. Wrapped up for the night: the detail line is one of five, one per
   night (§3.11).
   **Why not now?** While a break is due but not on offer and nothing paused it (the rows of the
   table in §3.7 from "resume cool-down" down), a 12 pt line at 60% with an hourglass sits under
   the status: "Waiting for a pause: Claude is idle and you are typing". At every other moment the
   status block already answers the question, so the line is absent.
3. **Actions:** capsules 28 pt: **Take a break ▾** (primary, menu of kinds) · **Pause ▾** (30 min /
   1 h / until tomorrow). Arrow keys and Return work here.
4. **Decision line** (only while an `AutoDecision` is undoable, 10 min): "Counted 6 min away as a
   break · Undo" or "Reset timers after 4 min away · Undo".
5. **Agents:** inset rows 36 pt: source glyph in a 20 pt rounded-square tile, project folder
   13 pt, state chip with text (indigo "working" / amber "needs you" / grey "idle"), elapsed time
   right-aligned in monospaced digits. Running long commands appear here too. At most 4 rows,
   then "+N more".
6. **Totals** (about 100 pt, no card): the section label is the period, "Today" while everything
   recorded is from today's Breakpoint day, then "Since Nov 16" (with the year once it is another
   year). Below it, three figures side by side, each a number over a short label so it reads as a
   phrase: **"74 min" moving · "26" stretches · "61" eye rests** (§2.7). Numbers SF Pro Rounded
   bold 30, white, monospaced digits rolling on change; units 15 semibold at 75%; labels 13 at
   60%. The moving column is 114 pt wide, the two counts share the rest; a number that does not
   fit scales down in its own column. Moving time rounds down: "74 min" under 100 min, then
   "5 h 20 min" ("5 h" on the hour), and from 10 h whole hours ("12 h", "1,040 h"). Counts use the
   locale's grouping ("2,915") and the singular at 1 ("1 stretch", "1 eye rest").
   Under them, once the moving time reaches the first example, one small quiet line, 12 pt at the
   hint step: **"That's like {activity}."** ("That's like walking the dog."), the highest example
   in `MovingExamples` (Routines/) at or below the moving time in whole minutes. Each example's
   threshold is the long end of the activity's usual length, so the comparison can only
   understate; it frames the total as something done, never as distance, effort, calories or a
   health effect. The activity is at 75%; while the latest stretch or walk is the one that
   reached it (a new example), it is mint instead (no animation). Before the first example there
   is no line. No bar, pictures, goals or "next". VoiceOver reads the section as one sentence:
   "Since Nov 16: 74 min moving, 26 stretches, 61 eye rests. That's like a full yoga class."

A global shortcut to toggle the popover can be set (off by default).

### 3.9 Settings window

- Sidebar window, default 860 × 770 pt, minimum 720 × 560, sidebar 200 pt, follows system
  appearance. Sidebar groups: **Breaks** (Breaks, Routine, Pauses, Wind-down) · **Connections**
  (Integrations) · **You** (General, Privacy, About). Sidebar icons: 20 pt rounded squares
  (radius 5), white glyph, fills stepping along a mint → teal → indigo ramp down the list.
- Pane header: icon + 17 pt semibold title. Content: inset grouped sections, 13 pt bold section
  titles, 24 pt between sections, rows 40–44 pt, label left and control right.
- **Sentence rows** wherever a value has units; the control sits inside the sentence.
- **Toggle rows:** 24 pt grey circular icon, 13 pt title, 11 pt secondary description saying
  *what will happen*, optional **Options…**, toggle on the right.
- **Show, don't tell:** preset picker = three cards, each with a mini timeline of a 2-hour session
  with ticks where eye and move breaks would fall; pop-up position = three thumbnails of a desktop
  showing where the card lands; **Preview nudge** and **Preview break** show the real component
  (for 5 s or until Esc; previews record nothing); sound row has ▶ and a volume slider; the
  routine pane lists the routines a stretch takes turns through, and **Preview a stretch** shows
  the next one.
- Selection is shown with a checkmark as well as colour. Leaving an unsaved drill-down asks
  Save / Discard.

| Pane | Row as shown (control in brackets) — description | Key · default |
|---|---|---|
| Breaks | Preset cards Gentle / Balanced / Frequent | `preset` · balanced |
| Breaks | "Offer an eye rest after [20 ⌄] min of screen time" | `eyesEveryMinutes` · 20 (10–60) |
| Breaks | "Offer a stretch after [50 ⌄] min without moving" | `moveEveryMinutes` · 50 (20–120) |
| Breaks | "Offer a walk when {agent}'s run is likely over [8 ⌄] min" | `walkThresholdMinutes` · 8 (5–20) |
| Breaks | Start eye rests by themselves — "A 10-second countdown runs first; typing, clicking or scrolling cancels it." | `autoStartEyes` · on |
| Breaks | Only during agent runs — "Breakpoint offers breaks only when an agent or long command starts, never when you pause typing." | `strictAgentOnly` · off |
| Breaks | Show the full break on every display — "Otherwise other displays show the blurred backdrop and a small timer." | `fullBreakOnAllDisplays` · off |
| Breaks | Preview nudge · Preview break buttons | — |
| Routine | I have a resistance band — "Band routines join the rotation." | `hasBand` · off |
| Routine | **Stretches** section: one row per available routine — symbol, name, one-line summary and a checkbox (ticked: in the rotation; unticking leaves it out and dims the row to 50%; the last ticked routine cannot be unticked). Nothing else per row: no steps, counts or times in Settings | `excludedRoutines` · [] |
| Routine | Last row of the section: "Each stretch is the next routine in turn, two minutes each." · Preview a stretch | — |
| Routine | Check movement with AirPods (experimental) — "Uses head motion during stretches and walks. macOS will ask for Motion access." | `airpodsMovementCheck` · off |
| Pauses | Pause during calls — "No break is offered while any microphone is in use." Options…: also when the camera is on | `pauseForMicrophone` · on · `pauseForCamera` · on |
| Pauses | "Treat me as away after [3 ⌄] min without input" | `awayThresholdMinutes` · 3 (2–10) |
| Pauses | (read-only) "Breakpoint also waits while you type, drag or dictate, and for 1 minute after a pause ends." | — |
| Pauses | (read-only) Quiet while you present or watch — "While a display is mirrored or kept awake, only an agent run or a long command offers a break, and eye rests never start by themselves." | — |
| Wind-down | Remind me to stop — "After your stop time, the next finished agent run shows a wrap-up card." | `windDownEnabled` · off |
| Wind-down | "Stop at [23:00] on [Mon–Sun ⌄]" | `stopTime` · 23:00 · `stopDays` · all |
| Wind-down | Ask for longer holds — "Each extra 15 minutes needs a longer press: 3, 6, then 10 seconds." | `escalatingHold` · on |
| Integrations | One row per tool: icon, name, status pill, Install / Remove; Install checks the hooks by itself and the pill turns to ✓ "Connected", or the row says what is wrong (§5.6) | — |
| Integrations | Codex folder override (shown only if `~/.codex` is absent) | `codexHome` · nil |
| Integrations | "Use with any tool" snippet: `breakpoint emit agentStarted --source my-tool --session ID` | — |
| General | Getting started (§3.12): The one-minute tour — "Rehearses one break with sample data, on the real screens. Nothing is recorded." [Take the tour] · Show hints | `showHints`; `tourStatus`, `hintsSeen` (not shown) |
| General | Open at login — "Breakpoint starts quietly in the menu bar." Outside an Applications folder the description adds "This works once Breakpoint is in your Applications folder." and turning it on registers nothing; turning it off still removes an item an older copy left (§3.10) | `launchAtLogin` · on (off on a first launch outside an Applications folder) |
| General | "Show [nothing ⌄] next to the menu-bar icon" (nothing / time to next break / agent state) | `menuBarText` · nothing |
| General | Pop-up position thumbnails (top left / centre / right) | `popupPosition` · topCentre |
| General | Hotkeys for the nudge — "⌃⌥⌘B starts the offered break. ⌃⌥⌘. dismisses it, or a resume card." | `nudgeHotkeys` · on |
| General | Popover shortcut [record] | `popoverHotkey` · nil |
| General | Chime when an agent needs you during a break [▶] [volume] | `chimeNeedsYou` · on · `volume` · 0.5 |
| General | Chime when a break ends [▶] | `chimeBreakEnd` · off |
| General | Tick at each new stretch step — "A short, quiet tone, so you can follow a stretch without watching." [▶] | `stepTick` · on |
| Privacy | Keep prompt snippets — "The first line of your prompt and of the agent's last reply, and the command it asks to run, label sessions and resume cards. Secrets are masked." | `storePromptSnippets` · on |
| Privacy | "What Breakpoint reads" plain list (the §2.4 signals, events from your tools) and **"No permissions needed."** (with the AirPods footnote) | — |
| Privacy | Export history · Delete all data | — |
| About | Version · "Paused at a breakpoint since 2026." · Updates · "General wellness, not medical advice." · Evidence notes · Acknowledgements | — |
| About | Updates: status row ("Breakpoint is up to date" — "Checked today at 09:12." · "Version 0.3.0 is available" — its notes, [Update] or [Download page…] · the install step with a spinner · "Couldn't install 0.3.0" — why, [Open download page…] · "Couldn't reach GitHub" · "Not checked yet") with [Check now] | — |
| About | Check for updates automatically — "Once a day, Breakpoint downloads a small file from its GitHub page to see the latest version number. It sends nothing about you or your breaks." | `checkForUpdates` · on |
| About | Install updates automatically — "When a new version is out, Breakpoint installs it at a quiet moment and reopens itself. Off: it asks first." (disabled, with the reason as its description, when this copy cannot install) | `installUpdatesAutomatically` · off |

`Settings` is a versioned Codable struct; keys above are its property names.

### 3.10 Onboarding (first launch)

Window 560 × 460 pt, centred, follows system appearance. Page dots at the bottom; **Continue**
(primary, Return) and **Back** (Esc / ⌘[) bottom-right. Completable by keyboard alone in < 60 s.
1. **Welcome:** the mark arrives with its signature motion (§4.6); a ≤ 6-word headline, one
   sentence, and "No permissions needed."
2. **How it works:** a looping 6 s demo built from the **real components at 60% scale** (not a
   video): nudge over a mock terminal → Start → overlay entrance → agent chip turns amber "Claude
   needs you" → back. Reduce Motion: three stills with captions.
3. **Connect your agent:** detected tools, each with Install. **Install is the whole step**: a
   spinner while Breakpoint writes the hooks and checks them by itself (§5.6, under a second as a
   rule), then a mint pill, ✓ "Connected"; the ✓ hops 4 pt once and the pill flashes mint (§4.6);
   reopening the step shows it at rest. The user is never asked to send anything or to wait for
   the tool. If the check fails, the row shows no ✓ but one orange line that says what is wrong and
   what to do, with Install again (and Remove). Under the name: where the hooks live, plus the
   install's own notes where they are true ("Open a new terminal window to start." for the shell).
   Codex alone keeps one line until Codex itself is first heard from, "One step in Codex: open
   /hooks and trust the entries.", because Codex skips hooks nobody trusted. "Skip for now" (the
   Continue button until something is installed) is always available and is this step's only skip
   control (no "Skip setup" here). Nothing is written until Install is pressed.
4. **Pick your pace:** the preset cards from Settings, Balanced preselected.
5. **Done:** "Breakpoint lives in your menu bar" with a small arrow pointing at the status item's
   actual position, and the choice "Open Breakpoint at login". Registers the login item (if on).
   Closing the window offers the one-minute tour under the mark (§3.12) the first time; declining it, or a later run of onboarding, opens the popover once. A login item points at the app where it is now, so
   Breakpoint registers one only from an Applications folder (`/Applications`, `~/Applications` or
   a folder inside either; `LoginItemAvailability`). Run from anywhere else (Downloads, a disk
   image, a translocated copy, a build folder), `launchAtLogin` starts off on the first launch and
   the choice is off and disabled, with "This works once Breakpoint is in your Applications
   folder." under it.

### 3.11 Wording

- Second person, present tense, plain verbs, one idea per line. Titles 2–5 words; instructions
  one sentence of ≤ 12 words; nudge offers ≤ 7 words and always state kind and length.
- Name the cause whenever Breakpoint acts on its own ("Paused: microphone is on", "Counted your
  6 min away as a break").
- Never: medical claims, "should", "!", guilt counters, scores. All copy lives in `Routines/`.
- Eye-rest titles give a small task at a distance and start with a verb ("Find", "Count",
  "Trace", "Pick", "Watch"); never "look away".
- Walk ideas are chips: ≤ 6 words, no full stop, something to do on the way.
- Closing lines (§3.3) are ≤ 5 words and name the time spent (rounded: "twenty seconds", "two
  minutes") or the routine's short name ("Shoulders done."); never praise ("Great", "Well done",
  "Nice") and never a count.
- **Debugger voice, rarely.** The name is a debugger term, and a few lines play on it, used
  straight (each reads plainly to someone who has never used a debugger). Never on the nudge (it
  is read in under a second) and never more than one in five of any rotation (a unit test holds
  this). The whole set (`Copy.debuggerVoice`):

  | Where | Line | Rotation |
  |---|---|---|
  | `walk` overlay title | "Step out for a while" / "We'll chime when Claude needs you." | 1 of 5 walk variants |
  | `move` title (announcement, previews) | "Step through a few moves" / "One at a time, at your own pace." | 1 of 5 |
  | `eyes` overlay title | "Watch something far away" / "Let your focus go soft until the timer ends." | 1 of 6 |
  | Popover, wrapped up for the night | "Paused at a breakpoint until morning." | 1 of 5, one line per night |
  | About | "Paused at a breakpoint since 2026." | fixed (About only) |

  Not used: "State saved" (Breakpoint saves nothing at wrap-up; the note is the user's to copy) and
  "[return] Continue" on the needs-you hint (the hint must name the button it triggers, Back to work).
- The popover's example line (§3.8) compares the person's own moving to an everyday activity
  they would recognise anywhere ("That's like a full yoga class."): activity done, not time;
  never distance, calories, fitness or benefit words, elite feats, or spellings that differ
  between British and American English. The examples are data (`MovingExamples`), strictly
  increasing, dense at the start (the first after a stretch or two, a new one every day or two in
  the first weeks), then about weekly, and still arriving after months; a test checks the order,
  the vocabulary and that each line fits the popover at 12 pt.

### 3.12 The one-minute tour and first-use hints

*Purpose: a new user knows what each thing on screen is, what to press, and that they are in
control, in about a minute, by meeting the real surfaces once; what a rehearsal cannot show is
said once, in one line, the first time it happens for real.* `TourPolicy` and `HintPolicy` (Core)
hold the rules; `AppCoordinator+Tour.swift` shows the sample surfaces and `AppCoordinator+Hints.swift`
the hints. Words in `TourCopy` and `HintCopy` (`Routines/TourCopy.swift`).

**The tour** rehearses one break cycle with sample data on the real surfaces, in their real places.

- **When.** Offered once, when onboarding closes, as a coach card hanging from the menu-bar mark:
  "Take the one-minute tour?" · **Not now** · **Take the tour**. Not now opens the popover once,
  as finishing onboarding did before. Settings → General → Getting started → **Take the tour**
  replays it (the window closes; the tour starts at the mark; `--tour` does the same at launch).
  It never starts or is offered by itself otherwise: `Settings.tourStatus` (notOffered → offered →
  declined / started → skipped / interrupted / finished) only stops a second offer, and a settings
  file from a version without the tour has onboarding done, so it is never offered after an update.
- **Steps** (progress: six dots, the current one a short mint capsule; Not now shares step 2):
  1. **The mark.** A coach card under the mark: what it is, and a legend of its states drawn with
     the real mark (working, needs you, break due, on a break, paused). The real mark shows the
     sample: due, with the working dot. **Next**.
  2. **The nudge.** A real nudge card in its real place: "15-sec eye rest?" / "{Agent} is working",
     with its buttons' keycaps as always (§3.1) and a coach line underneath that names them:
     "Press Start or Not now, or the keys shown on each button. It never takes your keyboard."
     (without the keys when the nudge hotkeys are off). It never times out and never auto-starts.
     **Not now** folds it and says what that did ("Nothing starts and nothing is counted…" ·
     **Offer it again**). **Start** (or ⌃⌥⌘B) is the only way to the break screen.
  3. **The break.** A 15 s eye rest (`Timing.tourBreakLength`) on the real break screen, with its
     real Skip guard, Esc Esc and timer. Coach lines in place: under the agent chip ("Your agent,
     live. It turns mint when the run ends."; the sample agent finishes after
     `Timing.tourAgentFinishesAfter`, and the chip turns to "{Agent} is done. No rush."), beside the
     controls ("Skip, or esc twice, ends it early. Nothing is forced."), and a footer with a mint
     **Rehearsal** chip, "Rehearsal with sample data. Nothing is recorded." and Skip tour.
  4. **The resume card.** The real card, sample row "{Agent} finished · ran 6 min" / "Added the
     sign-in form and its tests" / my-app, with its coach line underneath. It does not hide itself;
     **Next** or a click on the card moves on.
  5. **The popover**, opened for the user. Its parts are named one at a time in a strip at its
     bottom (status and "Why not now?", Take a break and Pause, the totals, the gear with Settings
     and the shortcut): the part named keeps full strength on a soft plate (the strip's 7% fill
     and rim) with the coach mark at its leading edge; the rest steps back to 45% at half
     saturation (65% with Increase Contrast). **Next** (its Return keycap shown) or Return;
     closing the popover moves on.
  6. **The last card**, under the mark: Settings and the tour are under the gear; the first real
     break comes while the agent works, once one is due. **Done**.
- **The user drives the pace.** Nothing moves past a step the user has not answered; the only step
  that ends by itself is the sample break, by its own timer, on screen. **Skip tour** is on every
  coach line (on the offer, Not now). While a standalone card shows (offer, mark, Not now, last
  card) and the nudge hotkeys are on, ⌃⌥⌘B presses its button and ⌃⌥⌘. skips.
- **Ends cleanly** on Skip tour, Done, or anything real: a call starting (a camera at once, a
  microphone once it counts as a call, §2.4; dictation does not end it), a real offer or a real
  Take a break, an agent needing you, going away, a pause that withdraws the sample nudge,
  quitting. Every sample surface goes at once (the break screen leaves as it always does); the
  real offer, if that was the cause, takes the nudge's place. It never resumes by itself.
- **Records nothing and disturbs nothing.** No history entry, no timer change (a sample eye rest
  resets no screen time), no kind spacing, no `lastNudgeAt`, no breather hold, no sound; real
  offers are never held back by a sample surface. The sample agent is the first connected tool's
  (else Claude); it never enters the session tracker.

**First-use hints.** The first time a real surface appears it may carry one line, once:

| Surface | Line | After the tour |
|---|---|---|
| Nudge, an ordinary offer | "Start, or carry on: it asks again later." | taught: not shown |
| Nudge, an eye rest that starts by itself | "It starts by itself. Press any key to keep working." (goes when a key cancels the countdown) | shown: the sample never auto-starts |
| Break screen, under the agent chip | "The chip above follows {Agent} and turns amber if {Agent} needs you." ("…your agents… if one needs you"; with no agent: "Skip whenever you like: nothing is forced.") | taught: not shown |
| Resume card that goes by itself | "It sums up your time away, then goes by itself." | taught: not shown |
| Resume card that waits (needs you) | "It stays until you press ⌃⌥⌘. or click it." ("…until you click it." with the hotkeys off) | shown: the sample is never a needs-you card |
| Popover, the first time it opens | "Option-click the mark to see why no break yet." | shown: the tour does not show Option-click |
| The first call pause | under "Breaks paused: camera is on": "Breaks come back by themselves after the call." The toast appears this once even with nothing due, and stays 10 s instead of 3. | shown: the tour has no call |

- **Rules** (`HintPolicy.shows`): Show hints on; onboarding done and its window closed; the tour not
  running; the surface real (not the tour's sample, not a Settings preview); the lesson not known;
  no other hint on screen (hints never stack: the later surface shows none and keeps its hint for
  next time). A hint never delays, holds or changes anything else about its surface.
- **Once per surface.** Showing a hint marks every lesson of its surface known (`Settings.hintsSeen`,
  saved at once), so a surface carries one hint at most. The tour marks a lesson known when the
  user answers that step (Start or Not now on the sample nudge; the sample break ending; Next or a
  click on the sample card), also with Show hints off, so turning hints on later never repeats it.
  A tour skipped or interrupted before a step leaves that step's hint for real use.
- **Existing users.** A settings file without `showHints` (a version before hints) decodes it as
  **off** when onboarding was done: an update brings no tour and no hints. Turning Show hints on
  is asking for them: each surface then carries its hint once. New installs start with it on.
- **Settings → General → Getting started**: Take the tour, and the Show hints switch ("The first
  time a pop-up or the break screen appears, one short line says how to use it. Each shows once.").

**One visual language** (`Design/CoachLine.swift`). Every line that teaches carries the coach mark,
a small mint target (a 4 pt dot in a 1 pt ring, 9 pt across, on a faint dark halo) that never reads
as a status dot: at the end of a coach line's 1 pt pointer, at the head of a hint and of the popover
strip, beside the part the popover step names. Words are 13 pt regular at the body step on
pop-ups and in the popover (titles 13 pt semibold), 16 pt regular in a dark capsule (scrim 42%,
1 pt rim) on the break screen, where the tour's lines and the first-break hint sit in the same
place under the chip; keys are keycaps. Coach cards are dark glass (radius 20, 340 pt), never take
focus, hang under the mark when the item is visible (else where pop-ups go), and fade as one
picture (composited, so glass, rim and shadow never show through each other). Reduce Motion:
fades only; Increase Contrast: brighter pointer, mark ring and rims.

---

## 4. Design language

**Feeling:** calm, clear, a little warm; a well-made system utility, not a wellness app. Polish
bar: the best native Mac utilities.

### 4.1 Identity guardrails

Breakpoint's own: the **name**, the **gutter-tag mark** (a rounded tag pointing right with two
small oval eyes), the **mint/indigo palette and the mint → indigo gradient**, and **all
wording**. Do not use: another app's character, artwork, gradient, badge, copy or feature names,
any blob/face illustration (no closed-eye faces), or the phrase "look away". No illustrated
characters at all.

The mark's eyes are two 3 × 3.6-unit ovals on the 24-unit grid, 1.6 units apart, centred across
the tag body and 0.6 units above its middle (eyes sit high in a face). They replaced two upright
2 × 5.5 bars, which read as a pause button. Below 48 px the app icon draws them 3.6 × 4.2, and
below 24 px as one slot; in a terminal (§5.8) each is 2 × 3 half-block pixels. The paused state
keeps a single horizontal bar, so paused never looks like the resting eyes.

The mark may *move* (§3.7) but stays a mark: its two eyes, and that is as far as it goes. Its movements play once at a moment that means something and never loop; there is
no blinking, no closed eyes, no idle animation, no added features (mouth, limbs, expressions), and
nothing reacts to whether the person took or skipped a break (no celebration, no confetti, no
counts). The movements show agent and day state only: a finish, a needs-you, the day wrapped up.
This sits at the edge of "no illustrated characters".

### 4.2 Colour

- Accent **mint** `#3DD6B0` (dark surfaces and dark mode) / `#12A688` (light mode). Text on mint:
  `#04140F`.
- **Indigo** `#6C7CFF` only for agent activity; **amber** `#FFB454` only for "needs you".
- Breakpoint gradient (badges, aurora): mint `#3DD6B0` → indigo `#6C7CFF`, 135°.
- Neutrals on dark surfaces: white at 100% (titles), 85% (body), 75% (button labels), 60%
  (secondary, timers), 50% (hints; lowest step allowed for text). Hairlines 25%, outlines 14%,
  fills 10%. Light-mode windows use system label colours.

### 4.3 Type

SF Pro Rounded for titles and every number; SF Pro Text for body. Every countdown or duration
uses monospaced digits and the numeric-text transition (per-digit roll).

| Use | Spec |
|---|---|
| Overlay title | Rounded bold, clamp(34, 3.3% display width, 56) |
| Overlay instruction | Text 19 regular |
| Timers (overlay, ring) | Rounded semibold 38 |
| Breathe In/Out | Rounded medium 22 |
| Nudge title / subtitle | 20 semibold / 15 regular |
| Pop-up and overlay buttons | 15 semibold (small card buttons 13) |
| Agent chip | 13 semibold |
| Popover big number / caption / body | Rounded bold 38 / 13 / 13 |
| Popover totals number / unit / label / example line | Rounded bold 30 / rounded semibold 15 / 13 / 12 |
| Wind-down title | Rounded semibold 17 |
| Settings pane title / section / row / description | 17 semibold / 13 bold / 13 / 11 |
| Hints, footers | 11 |

### 4.4 Shape and spacing

Continuous corners on rounded rectangles; capsules have true half-circle ends (the circular
capsule style: AppKit draws a continuous capsule's outline with flat ends in real windows). Radii: pop-up cards 28; nudge and away capsules full capsule; countdown chip
16; popover inset cards 14; settings sidebar tiles 5. Every control is a capsule. New spacing uses
4, 8, 12, 16, 24, 32, 48; measured values in this spec (6 concentric inset, 9, 14, 58, 44, 66, 96)
are used as given.

### 4.5 Material

All pop-ups are dark glass in both system modes, with two shadows (y 9, blur 18, black 14%) and
(y 21, blur 48, black 24%). `GlassPanelBackground` (§7.2) is the only implementation.

- **macOS 26 and later:** the system Liquid Glass (`glassEffect(.regular)` in the pop-up's shape,
  dark colour scheme) under an 18% black veil, so white text holds on bright desktops. The system
  draws the rim, the lensing at the edge and the tint from what is behind. The popover keeps the
  `NSPopover` window's own glass and adds only the veil.
- **macOS 14 and 15** (and every snapshot): `NSVisualEffectView` `.hudWindow` plus a 12% black
  tint that clears to about a third of that over the outer 10 pt, so the edge shows more of what
  is behind. Lit, never animated: a 1 pt rim that catches light at the top-leading corner (45%
  white) and faintly at the bottom-trailing one (22%), with the plain 10% on the sides; that
  light spread 3 pt inwards, soft; a 10 pt band of added light inside the rim (10% at the top,
  4% at the bottom), which takes the colour of what is behind; a still sheen from the
  top-leading corner (7% white, gone by the middle); and a 1 pt shade inside the bottom rim
  (black 16%), so the surface reads as a thick slab. The popover gets the same tint and light.
- Reduce Transparency and Increase Contrast: §4.8 (no lighting, no system glass under Reduce
  Transparency).

Overlay backdrop: §3.3.

### 4.6 Motion

Springs never overshoot visibly (damping ≥ 0.8). Discrete transitions ≤ 0.5 s except the overlay
entrance; continuous animations (rings, aurora, pulses, breathing) are exempt.

| Moment | Motion |
|---|---|
| Pop-up in | The glass grows out of a small capsule under the card's top edge (22% wide, 8–14 pt high): it spreads along the edge first, the height trailing by 18% of the progress, then drops open; spring 0.5 / 0.82 (≈ 1% overshoot, settled by 0.6 s). The content comes into focus over 45–95% of the progress (6 pt blur and 6 pt drop → rest), clipped to the glass |
| Pop-up out (timeout) | Folds back into its seed: the words fade (and blur) while the glass holds, then the glass folds up into the top edge with a 4 pt upward drift; 0.35 s ease-in |
| Pop-up out (action) / withdraw | Settles to 96% towards the top edge and fades, 0.2 s ease-out |
| Nudge → countdown chip | The card becomes the chip (§3.2), 0.8 s |
| Nudge subtitle swap on hover | 0.2 s cross-fade after a 300 ms rest |
| Digit roll | 0.25 s per change |
| Brand mark arrival (onboarding Welcome, About) | Slides 6 pt in from the leading edge and settles, spring 0.35/0.8 |
| Overlay entrance | See table below (≈ 1.55 s) |
| Overlay exit | Content 0.2 s fade (title defocuses 0 → 4 pt); backdrop lets go in layers over 0.75 s: aurora, then scrim and vignette, desktop focus last (§3.3) |
| Agent chip colour change | 0.3 s cross-fade; working dot pulses 0.5 Hz |
| `move` step change | 0.3 s ease-in-out, 12 pt slide; ring reset 0.2 s fade |
| `move` pace ring | Each tempo phase over its own seconds, sine ease-in-out; at each turn the word dips to 35% over 0.25 s and the next rises over 0.25 s |
| Closing moment (1.2 s) | Content fades 0.2 s; title out 0.15 s, closing line in 0.15 s; ring closes 0.45 s ease-in-out; check draws from 0.3 s over 0.3 s ease-out; then the overlay exit |
| `breathe` | 5.5 s in / 5.5 s out, sine ease-in-out |
| Aurora | 60 s drift loop (five lights on their own paths, all closing each minute); 15 fps |
| Wind-down hold | Linear fill over 3 / 6 / 10 s; release springs back 0.3 s |
| Card time rim (§3.5) | Draws out 0.45 s ease-out on arrival; draws back linearly over the card's time; held: brightens 0.2 s; pointer leaves: eases up 0.45 s ease-out |
| Card grows (wind-down note) | Spring 0.45/0.85 |
| Install verified (Settings) | The status pill flashes mint, 0.4 s |
| Menu-bar mark: agent finished (§3.7) | Working dot slides into the notch, shrinking, and disappears; 0.4 s ease-in-out, once |
| Menu-bar mark: needs you | Both eyes 1.1 grid units (≈ 1 pt) taller over the first 35%, then settle; 0.3 s, once |
| Menu-bar mark: wrapped up | Eyes fold into the rest bar; 0.45 s ease-in-out, once |
| Onboarding install verified | The pill's ✓ hops 4 pt (up 40%, down 60%) over 0.45 s; the pill flashes mint 0.4 s |
| Control hover in / out | Light, +6% fill and 1 pt lift: spring 0.28/0.9 in, 0.4/1 out; the light follows the pointer on a spring 0.22/1 and comes up where the pointer enters |
| Control press / release | Scale 0.97 and light bloom: spring 0.16/0.86 down, 0.34/0.8 back |
| Keyboard focus ring | Opacity and 2 pt growth, spring 0.25/0.9 |

Overlay entrance (measured pacing, steps of 0.3–0.5 s, ordered by importance):

| t (s) | Event |
|---|---|
| 0.00 | Windows visible. The desktop softens: the blur view fades 0 → full over 0.5 s, cubic ease-out, so edges dissolve before anything darkens (the system blur radius is fixed; its opacity animates) |
| 0.05 | The edges darken: vignette 0 → full over 0.55 s (smoothstep) |
| 0.15 | The screen settles into deep tones: scrim 0 → full over 0.6 s (smoothstep) |
| 0.35 | The light rises from behind the words: the aurora's lights start gathered around the column's centre (45% of their distance out, 70% of their size) and spread to their drifting places as they brighten, 1.2 s ease-out (done at 1.55 s, with the content) |
| 0.55 | Title: opacity 0 → 1 and blur 8 → 0 over 0.35 s (focus pull) |
| 0.95 | Instruction, kind line, hairline, guide: opacity + 6 pt rise over 0.35 s |
| 1.25 | Agent chip, controls, hint: opacity over 0.3 s (done ≈ 1.55 s) |

Pop-up shapes are pure functions of a progress value (`LiquidMotion` in BreakpointCore): the live
panels animate that value with SwiftUI's spring and curves, and the motion film
(`BreakpointSnapshots --motion-film`) draws the same shapes frame by frame. Inside a pop-up the
glass is drawn by the motion (`LiquidPopupPose`), not by `GlassCard` / `GlassCapsule`, so it can
change shape while the card's layout stays put; it is the same `GlassPanelBackground`, so the
material is unchanged. The system's own morph (`GlassEffectContainer`, `glassEffectID`, macOS 26)
works only inside one view tree, and the nudge and the chip are separate windows in different
places, so the hand-made morph is used on every macOS version.

**Reduce Motion:** every animation above becomes a ≤ 0.2 s opacity cross-fade (overlay entrance:
one 0.25 s fade of every layer together, no bloom); no scale, blur, slide, roll or drift; the aurora
is static; controls do not
lift or scale, and their light sits still at the top edge, fading in and out in 0.15 s (a press
shows as a brighter light); `breathe` animates
fill opacity 10% → 30% → 10% with the same timing instead of scaling; the `move` pace ring steps
by whole seconds; the closing moment is one 0.2 s cross-fade (content out, then the closed ring
with its check and the line in); the menu-bar dot is static;
a card's time rim stays whole and fades with the time left instead of drawing back; the menu-bar
mark's movements do not play (the new state appears with the usual cross-fade); the onboarding hop
does not play and the pill's flash is a 0.2 s fade.

### 4.7 Sound

Off by default except the needs-you chime during a break and the step tick. The chimes are
synthesised in code (`AVAudioEngine`, two sine partials, ≥ 30 ms attack, ~1.5 s exponential decay,
no transient spike), ≤ −18 LUFS at full volume (−20 measured); volume default 50%.

The **step tick** marks each new step of a stretch so it can be followed without watching: the
same family made small (E6 + a faint B6, the break-end chime's fifth an octave up), 40 ms attack,
0.07 s decay, 0.45 s long, −30 LUFS at full volume (10 dB under the chimes), scaled by the volume
setting. It plays only when the timer moves a real stretch to its next step (not on ← / →, not
at the end, never on previews), and never during a call. On by default (decision 39).

Every sound row has ▶ preview. No sound plays while a call signal is active (screen sharing
cannot be detected without a permission).

### 4.8 Accessibility

- Every control has an accessibility label; every action is reachable by keyboard; keycaps shown
  for the main ones.
- Text contrast ≥ 4.5:1, checked over pure white and over a busy photo wallpaper.
- **Reduce Transparency:** pop-ups solid `#151A22` with a 1 pt rim at 12% white (no lighting and
  no system glass, on every macOS version); overlay solid
  `#0B0F17` with the static aurora (light pass only) at 8%, and the grain.
- **Increase Contrast:** overlay scrim 75%, aurora off (vignette, hush and grain stay); break
  rings solid mint without the glow; pop-up rim 30% white, no sheen, glint
  or band, and an even tint; hint text 60%; a
  hovered control's rim catches more light (75% white at the pointer).
- **VoiceOver:** nudge appearance posts an announcement ("Break offer: 2-minute stretch.
  Control-Option-Command-B to start."); break start, end and needs-you are announced (§3.3).
- State is never shown by colour alone: menu-bar shapes, chip text, checkmarks on selection.
- Layouts must not clip at larger accessibility text sizes.

---

## 5. Integrations

### 5.1 Transport

Events reach the app **only** through the `breakpoint` command-line tool, which writes one JSON
line (§6) to a Unix domain socket at `~/Library/Application Support/Breakpoint/breakpoint.sock`
(if that path exceeds 103 bytes, `~/.breakpoint/run/bp.sock`; `SocketPath` decides for both
sides). No HTTP server, no TCP port, no network. The socket is mode 0600 in a 0700 directory and
the server rejects peers whose uid (`getpeereid`) differs from its own.

At launch the app opens the socket before anything else. If another copy of Breakpoint already
answers on it (same home), the new copy sends it `activate` (§6), which shows the running copy's
popover, and quits without showing or writing anything. If something that is not a socket sits at
the path, or the socket cannot be opened, the app keeps running (breaks offered at typing pauses
still work) and tells the user once, in one alert, what is in the way; `breakpoint doctor` shows
it too.

### 5.2 CLI location

Hooks call `~/.breakpoint/bin/breakpoint` (no spaces in the path; hooks do not get the user's
`PATH`). It is a **copy** of the CLI, written on the first Install and refreshed at app launch
when its version differs, so moving or translocating the app never breaks hooks. Every shell-form
hook is wrapped so a missing binary is a silent no-op:

```sh
[ -x "$HOME/.breakpoint/bin/breakpoint" ] && "$HOME/.breakpoint/bin/breakpoint" emit agentStarted --source claude-code --stdin-json >/dev/null 2>&1 || true
```

### 5.3 The `emit` contract

`breakpoint emit` must:
1. **Print nothing** on stdout or stderr, in every case.
2. **Always exit 0** — app not running, socket missing, bad arguments, malformed stdin.
3. With `--stdin-json`: read stdin to EOF (cap 1 MB, 250 ms total). With `--argv-json`: take the
   last argument as the payload (Codex `notify`).
4. Connect and write with a 100 ms timeout, not wait for a reply, and exit. Target p95 < 50 ms.
5. Start no child processes.
6. Take the **kind from the positional argument** (each hook is registered on one event); the
   payload only supplies session, folder, title and `detail`.
7. Truncate the title to its first line minus `<pasted_content…>` wrapper lines, ≤ 80 characters.

If a tool turns out to reject empty stdout (§5.7), fix that tool's hook command (e.g.
append `; printf '{}'`), never `emit`.

### 5.4 Host detection (no double counting)

Cursor runs Claude Code's user hooks by default. Parsing (`HookPayloadParser`, Core): if the
payload has `cursor_version` or the environment has `CURSOR_VERSION`, the event's source becomes
`cursor` and `via` becomes `claude-code-hooks`, whatever `--source` said. (`CLAUDE_PROJECT_DIR`
is set by both tools and is not a discriminator.) The app then applies §2.6.

### 5.5 Per-tool installation

| Tool | File (user level only) | Write mode | Marker | Async | Notes |
|---|---|---|---|---|---|
| Claude Code | `~/.claude/settings.json` | merge into `hooks` | `/.breakpoint/bin/breakpoint" emit` + `--source claude-code` | `"async": true` on all; `SessionEnd` sync, `"timeout": 2` | Never write project `.claude/` files (Copilot CLI reads them). Hooks wait for the user to accept workspace trust |
| Cursor | `~/.cursor/hooks.json` (`"version": 1`) | merge | `--source cursor` + binary path | no async option; sync, `"timeout": 2` | Never register permission hooks: `preToolUse`, `beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile`, `beforeTabFileRead`, `subagentStart`. No heartbeat. No needs-you signal exists |
| Codex CLI | `$CODEX_HOME/hooks.json`, default `~/.codex/hooks.json` | merge | `--source codex` | async except `Interrupt` (sync, `"timeout": 1`) and `SessionEnd` (always sync, `"timeout": 2`) | After install, tell the user to open `/hooks` in Codex and trust the entries; keep command strings byte-identical across versions |
| Codex (legacy) | top-level `notify` in `~/.codex/config.toml` | one marked line | marker comments around the line | not awaited by Codex | Fallback only, via Options… → "Use legacy notify (older Codex)". Never installed together with hooks. Refuses (with an explanation) if `notify` already exists |
| Copilot CLI | `~/.copilot/hooks/breakpoint.json` | own file | the file | sync, `"timeoutSec": 2`, fails open | Never register `preToolUse` (fails closed). Supported because it is one owned file |
| Gemini CLI | `~/.gemini/settings.json` | merge into `hooks` | `--source gemini` | sync only, `"timeout": 2000` (ms) | Supported where Gemini's hooks are on and accept empty stdout (§5.7). Older versions may have hooks off |
| Shell | `~/.breakpoint/shell/breakpoint.zsh` / `.bash` sourced from a marker block in `.zshrc`, and in both `.bashrc` and `.bash_profile`; fish: `~/.config/fish/conf.d/breakpoint.fish` | own files + marker blocks | `# >>> breakpoint >>>` … `# <<< breakpoint <<<` | backgrounded (`&!`, `( … & )`, `& disown`) | Snippets from `agent-integrations.md` §5, plus `--session "$$"` (fish: `$fish_pid`). Sends only the command's first word |

All installers (Core `Integrations/`, injectable home directory; tests never touch the real one):
write nothing until the user presses Install (or runs `breakpoint install`); back up the file to
`backups/` first; refuse and explain if the file does not parse; re-read immediately before
writing; append without touching foreign keys or entries, preserving key order and 2-space
indentation; write to a temp file in the same directory and `rename`, keeping the file mode; be
idempotent (skip events already marked); uninstall removes only marked entries, then empty groups,
arrays and `hooks`.

### 5.6 Event mapping

| Breakpoint kind | Claude Code | Cursor | Codex CLI | Copilot CLI | Gemini CLI |
|---|---|---|---|---|---|
| `sessionStarted` | `SessionStart` | `sessionStart` | `SessionStart` | `sessionStart` | — |
| `agentStarted` | `UserPromptSubmit` | `beforeSubmitPrompt` | `UserPromptSubmit` | `userPromptSubmitted` | `BeforeAgent` |
| `agentActivity` | `PostToolUse` (heartbeat for §2.6) | — | — | — | — |
| `agentNeedsUser` | `PermissionRequest` (matcher `*`); `PreToolUse` matcher `AskUserQuestion`; `Notification` matcher `permission_prompt\|elicitation_dialog\|elicitation_url_dialog\|idle_prompt` (detail = type) | — (none exists) | `PermissionRequest` | `notification` matcher `permission_prompt\|elicitation_dialog` | `Notification` (`ToolPermission`) |
| `agentFinished` | `Stop` (detail `background` while `background_tasks` lists work in flight); `StopFailure` (detail = `error`) | `stop` (detail = `status`: `completed`/`aborted`/`error`) | `Stop`; `Interrupt` (detail `interrupted`) | `agentStop` | `AfterAgent` |
| `subagentFinished` | `SubagentStop` (dropped when `agent_type` is empty) | `subagentStop` | `SubagentStop` | — | — |
| `sessionEnded` | `SessionEnd` | `sessionEnd` | `SessionEnd` | `sessionEnd` | — |
| Codex `notify` | — | — | `agent-turn-complete` → `agentFinished` | — | — |

| Field | Claude Code | Cursor | Codex | Copilot | Gemini |
|---|---|---|---|---|---|
| session | `session_id` | `conversation_id` (`session_id` on session hooks) | `session_id` (`thread-id` for notify) | `sessionId` | `session_id`, else `gemini:<folder>` |
| project folder | `$CLAUDE_PROJECT_DIR`, else `cwd` | `workspace_roots[0]`, else `$CURSOR_PROJECT_DIR` | `cwd` | `cwd` | `cwd` |
| title | `prompt` | `prompt` | `prompt` (notify: `input-messages[0]`) | `prompt` | `prompt` |
| message (`agentFinished`) | `last_assistant_message` on `Stop` (not `StopFailure`, where it is the raw API error) | — | `last_assistant_message` (notify: `last-assistant-message`) | — | — |
| reason (`agentFinished`) | `error` on `StopFailure` | — | — | — | — |
| tool + message (`agentNeedsUser`) | `tool_name` / `tool_input` (`PermissionRequest`, `PreToolUse`); tool `question` for `elicitation_*` | — | `tool_name` / `tool_input` | — | — |
| tool (`agentActivity`) | `tool_name` (`PostToolUse`) | — | — | — | — |

Tool names map to kinds: `Bash` (Codex `shell`, `exec_command`, …) → `command`; `Edit`, `Write`,
`MultiEdit`, `NotebookEdit`, `apply_patch` → `edit`; `WebFetch` → `fetch`; `AskUserQuestion` →
`question`; `ExitPlanMode` → `plan`; anything else → `other`. The request's subject comes from
`tool_input`: `command` (a string, or an argv array whose `sh -c` wrapper is dropped), the last
path component of `file_path` / `notebook_path` / `path`, or the host of `url`. Messages and
subjects are left out entirely when "Keep prompt snippets" is off (§3.5).

**Install check** (`InstallCheck`). Pressing Install is all the user does: right after the files
are written the app verifies, by itself and silently, everything that can be known before the tool
runs, and the row is ✓ "Connected" as soon as it passes:

1. The tool's file reads back with Breakpoint's current entries (`status() == .installed`).
2. The CLI copy the hooks call, `~/.breakpoint/bin/breakpoint`, is in place and executable.
3. The tool has not turned hooks off: Claude Code's `"disableAllHooks": true` in
   `~/.claude/settings.json`.
4. End to end: the app runs the hooks' own command form with kind `test`
   (`HookCommand.shell(.test, source:)`) the way a tool runs a hook (`/bin/sh -c`, `HOME` = the
   home the hooks see, empty stdin), and the `test` event must reach the app's socket within
   `Timing.installCheckTimeout` (10 s; a freshly copied binary's first run can take a few seconds
   while macOS checks it). A `test` event never changes sessions and never counts as the tool's
   last event.

1–3 are also re-checked whenever the app re-reads install states (launch, Settings, every 30 s of
events), so a CLI copy deleted later shows up. When a check fails the row shows no ✓ and one line
with what to do: "The command its hooks call is missing from ~/.breakpoint/bin. Install again to
put it back.", "The command its hooks call, in ~/.breakpoint/bin, doesn't run on this Mac. Install
again to replace it.", "Its hooks can't reach Breakpoint. To see why, run
~/.breakpoint/bin/breakpoint doctor." or "Claude Code's settings have disableAllHooks on.
Turn it off, then install again." A failed end-to-end check lasts
until the next Install or the first real event from that tool.

What the check cannot know, and the row therefore does not claim beyond "Connected": whether the
tool itself will run the hooks. **Codex** skips hooks until the user trusts them in `/hooks`, so its
row keeps that one step as a line until Codex is first heard from. **The shell** snippet loads
only in shells started after Install ("Open a new terminal window to start."). **Claude Code** runs
hooks only in folders whose workspace trust was accepted, and an administrator's
`allowManagedHooksOnly` blocks them; open sessions pick up settings edits by themselves. **Cursor**
reloads `hooks.json` on save ("If Cursor does not pick the hooks up, restart it."). **Gemini CLI**
runs hooks only in versions that have them on. **Copilot CLI**'s documentation does not say when
running sessions read a new hook file. None of this is a step the user must prove: the first real
event is shown afterwards as information ("Connected · last event 2 min ago"), never as a condition.

Status pill states: ✓ "Connected", "Connected · last event 2 min ago", "Not installed", "Not found"
(tool folder absent), "Needs an update" / "Edited outside Breakpoint" (outdated or edited entries),
"Needs attention" (an install check failed) and "Can't read its settings" (unparseable file).

### 5.7 Open questions about the tools

The installers follow each tool's documentation (docs/research/agent-integrations.md). The rows
below are behaviour that documentation implies without stating it outright; this spec records none
of them as confirmed by hand. Each row says what changes if a tool behaves otherwise.

| Assumed behaviour | If a tool behaves otherwise |
|---|---|
| Cursor runs `command` through a shell (`$HOME`, `&&`, redirects) | point hooks at a wrapper script `~/.breakpoint/bin/cursor-hook` |
| Cursor `beforeSubmitPrompt` accepts empty stdout | that hook's command appends `; printf '{"continue":true}'` |
| Codex accepts `async` on `PermissionRequest` | make it sync with `"timeout": 2` |
| Codex `Stop`/`SubagentStop` accept empty stdout | those commands append `; printf '{}'` |
| Claude Code sends `idle_prompt` after an interrupt | rely on the 10 min fallback only |
| Gemini hooks are on and accept empty stdout | Gemini's events do not arrive; turn its hooks on, or add a JSON reply to its hook commands |

### 5.8 CLI

```
breakpoint emit <kind> --source S [--session ID] [--cwd PATH] [--title TEXT] [--detail TEXT]
                [--duration-ms N] [--exit-code N] [--stdin-json | --argv-json]
breakpoint status              # prints the app's status JSON, or "not running"
breakpoint status --line [--color]
                               # one short line for a shell prompt, tmux or an agent's status bar
breakpoint install <tool>      # claude-code | cursor | codex | codex-notify | copilot | gemini | shell | all
breakpoint uninstall <tool>
breakpoint doctor              # socket, app, CLI copy, each integration and its last event, and
                               # the app's signal report (idle time, lock and sleep, camera, one
                               # name-free line per audio device and the microphone decision);
                               # ends "Everything checks out." or "N problems found."
breakpoint --version           # in a terminal: the mark in block characters beside the version
                               # (mint when the terminal takes colour; NO_COLOR or TERM=dumb: plain);
                               # piped or redirected: exactly "breakpoint 0.3.0", one line
```

The app's executable prints the same signal report on its own with `--signals` (for when the app
is not running). Debug builds of the CLI also have `breakpoint debug …`, the end-to-end harness
(CLAUDE.md); release builds do not. `breakpoint update-relaunch --pid N` is not listed in the help:
the app runs it from the old copy during an in-place update (§2.11).

`status`, `install`, `uninstall` and `doctor` print human-readable text and may exit non-zero;
only `emit` is silent.

**`status --line`** is for things that redraw often: a shell prompt, tmux, a status bar, Claude
Code's `statusLine` command. It asks the app once, waits at most `Timing.statusLineTimeout`
(0.25 s) and reads no files; with the app not running or not answering it prints nothing and
exits 0, so a prompt never shows an error. The line is two parts joined by " · ", in the menu
bar's words (lower case, like a prompt):

| Part | Text (first that applies) |
|---|---|
| Break (always) | on a break: "stretch 1:20 left" · a nudge on screen: its title, "2-min stretch?" · paused: the pause sentence, "paused until 15:30", "paused: microphone is on" · due: "stretch due" · else: "eye rest in 12 min" (minutes rounded up, the stretch counted as §2.3 holds it after a breather) |
| Agents (only while one works or needs you) | one: "Claude working 3 min" (no time under a minute), "Claude needs you" · several: "1 needs you · 2 working", needs you first, so a bar that cuts the end keeps it |

Idle agents and away are not shown. The break part follows the menu bar's mark, not "Why not
now?": a stretch that is due stays "stretch due" while a microphone holds offers, while the
presenting guard is on, and while kind spacing (a cadence from the third no in a row, §2.4) keeps
it from being offered; the stretch's routine is not named. On a terminal the line is coloured as the app is: mint for a
break on screen, offered or due; indigo for working; amber for needs you; dim for paused and the
separators; nothing due stays plain. `NO_COLOR` and `TERM=dumb` turn colour off, as for
`--version`; `--color` turns it on in a pipe too (Claude Code and tmux read the output through
one) and wins over `NO_COLOR`. Nothing else is added to the socket: the line is built from the
`status` reply.

---

## 6. Wire format

One UTF-8 JSON object per line over the socket, max 64 KB per line:

```json
{"v":1,"type":"event","event":{"kind":"agentStarted","source":"claude-code","sessionID":"abc",
 "cwd":"/path/project","title":"fix the login redirect","detail":null,"via":null,"ts":1795400000.0}}
```

Event kinds: `sessionStarted`, `agentStarted`, `agentActivity`, `agentNeedsUser`,
`agentFinished`, `subagentFinished`, `sessionEnded`, `commandStarted`, `commandFinished`, `test`.
Optional fields: `title`, `detail`, `via`, `durationMS`, `exitCode`, `message` (the agent's last
message, or what it asks for; snippets on only), `tool` (`command`, `edit`, `fetch`, `question`,
`plan`, `other`; unknown values read as `other`) and `reason` (why a run failed, e.g.
`rate_limit`); the last five are written only when present. `{"v":1,"type":"status"}`
returns one JSON line describing sessions (with `runStartedAt` while one runs), timers, pause
state, the next break as the menu bar counts it (`nextBreak`: `kind`, `seconds`, ≤ 0 when due),
the break on screen (`activeBreak`: `kind`, `startedAt`, `length`) and the nudge on screen
(`nudge`: `kind`, `title`); previews are left out, and a reply without the last three (an app
before 0.3) still decodes.
`{"v":1,"type":"command","name":"signals","args":[]}` returns one
`{"v":1,"type":"reply","text":"…"}` line; the commands are `activate` (a second copy hands over),
`signals` (the diagnostic report) and, in debug builds only, `debug`. Unknown fields are ignored;
unknown kinds and types are dropped without error.

---

## 7. Architecture

Swift package (no Xcode project, **no third-party dependencies**), macOS 14+, Swift 5 language
mode.

```
Package.swift
Sources/
  BreakpointCore/        Foundation-only. Models, engine, tracking, stores, wire format, installers.
  BreakpointKit/         AppKit + SwiftUI. Design system, all windows and views, the tour, system services.
  BreakpointApp/         The app executable (named Breakpoint inside the bundle): main, AppDelegate,
                         AppCoordinator wiring Core + Kit (+Loop, +Actions, +State, +Commands, +Hints,
                         +Pacing, +Rotation, +Tour, +Updates), DebugHarness (debug builds only).
  breakpoint-cli/        The `breakpoint` command-line tool (product name: breakpoint). Depends on Core.
  BreakpointSnapshots/   Renders key views to PNG, and motion films, for visual review (never shipped).
Tests/
  BreakpointCoreTests/   Swift Testing. Shared/ (models, wire, formatting), CoreLogic/ (engine, policies,
                         tracker, stores, routines, updates), Integrations/ (installers, parser, socket,
                         CLI), Motion/.
scripts/                 test.sh, snapshots.sh, build-app.sh, run.sh, smoke-app.sh, e2e.sh; releases:
                         release.sh, release-keygen.sh, package-release.sh, make-update-feed.sh,
                         update-signing.swift, install.sh
docs/                    SPEC.md, INTERFACES.md, RELEASING.md, MAINTAINING.md, TRYING-IT.md, research/,
                         readme/
```

### 7.1 BreakpointCore (pure logic, fully testable; no AppKit, no system calls except files and sockets)

- `Models/` — `AgentSource`, `AgentEvent` (kind, source, sessionID, cwd, title, detail, via,
  timestamp, durationMS, exitCode, message, tool, reason), `AgentToolKind`, `AgentSession` +
  `AgentState` + `RunReport` (edits, commands, message, failure, request) + `AgentRequest`,
  `RunningCommand` + `CommandResult`, `ResumeFacts` (what one resume-card row says), `BreakKind`,
  `BreakOffer`, `BreakOutcome`, `Opportunity` + `OpportunityKind`, `EngineDecision` (`offer`,
  `hold(HoldReason)`, `suppress(SuppressReason)`, `nothing`), `PauseReason`, `CallSignals`
  (option set: microphone, camera), `PauseState` (active reasons, `cooldownUntil`, ignored call),
  `InputSample` (seconds since key / any input / drag / scroll, button down, display-sleep
  prevented, display mirrored; `presentingCause`),
  `PresenceEvent` (locked, unlocked, displaysSlept, woke, screensaverStarted/Stopped,
  sessionResigned/Activated), `AutoDecision` (id, kind `creditedAway([BreakKind], duration)` or
  `timersReset(duration)`, madeAt, sentence, `previous: TimerState`, `historyEntryIDs`,
  `undoExpiresAt` = madeAt + 600 s), `Routine`, `RoutineStep`, `BreakCopy`, `HistoryEntry`,
  `DaySummary` (breaks taken in one day).
- `Settings/` — `Settings` (Codable, versioned, defaults per §3.9), `SettingsStore`.
- `Tracking/` — `SessionTracker` (events → sessions, transitions, stale fallback, duplicate drop,
  run-length estimator), `ActivityClock` (pure: `advance(TimerState, InputSample, presence, dt)`),
  `TimerState`, `PresenceTracker` (input samples + presence events → present/away periods).
- `Engine/` — `EngineSnapshot`, `BreakEngine.decide(snapshot, opportunity, now) ->
  EngineDecision`, `OpportunityDetector` (pure: `typingPause` and `longCommand` from a snapshot),
  `AwayPolicy.resolve(period, TimerState, settings) -> (TimerState, AutoDecision?)`,
  `PausePolicy` (pause reasons + cool-downs from inputs and clock), `WindDownPolicy`, `Cadence`
  presets, `CommandDenylist`, `BackdropTimeline` and `AuroraField` (the overlay backdrop's
  layers over time and the aurora's lights, pure, §3.3).
- `History/` — `HistoryStore` (append-only JSONL, day summaries, all-time totals, delete entries
  by id for Undo, export, delete all), `HistoryTotals` (the popover's figures, kept incrementally).
- `Wire/` — `WireMessage`, `SocketPath`, `EventSocketServer`, `EventSocketClient` (POSIX, no
  AppKit).
- `Integrations/` — `Integration` protocol (`id`, `displayName`, `detect()`, `status()`,
  `install()`, `uninstall()`), one type per tool in §5.5, `JSONSettingsMerger`, `MarkerBlockEditor`
  (rc files and the TOML `notify` line), `HookPayloadParser`, `CLIInstaller` (copies the CLI to
  `~/.breakpoint/bin`).
- `Routines/` — built-in routines and all copy.
- `Updates/` — `UpdateKey` (the release key's public half), `UpdateSignature`, `UpdateInstaller`,
  `UpdateRelauncher` (§2.11).

### 7.2 BreakpointKit (UI + system services)

- `Design/` — `Theme` (colours, type, spacing, radii, `Theme.Motion` with every §4.6 value),
  `GlassPanelBackground`, components: `GlassCard`, `PillButton` (roles primary / secondary /
  tertiary / mintPrimary; sizes 34 / 28; optional keycap; optional guard ring), `KindBadge`,
  `AgentChip`, `ProgressRing`, `StatusDot`, `KeyHint` (keycaps), `RollingNumber`, `BrandMark`,
  `SectionHeader`, `SettingRow`, `SentenceRow`, `PresetCard`, `Chip`.
- `State/` — `AppState` (`@MainActor final class: ObservableObject`) and `AppActions` (struct of
  closures). Views depend only on these and Core models. `AppState.preview(...)` factories cover
  every snapshot state. Contents:
  - `AppState`: `menuBar` (mark state, badge state, text, tooltip), `status` (next break, still
    time, pause state), `lastDecision: AutoDecision?`, `sessions`, `commands`, `today`, `totals`, `nudge`
    (offer, subtitle, why-now, auto-start remaining), `activeBreak` (kind, step, elapsed, planned
    length, extensions used, skip enabled at, agent chip, needs-you, ambient), `cards`
    (resume / away / toast / wind-down), `integrations`, `settings`.
  - `AppActions`: `acceptNudge`, `declineNudge`, `startBreak(kind)`, `skipBreak`,
    `finishBreak(reason)`, `extendBreak`, `stepRoutine(±1)`, `undoLastDecision`,
    `pause(duration)`, `resume`, `dismissCard(id)`, `windDownExtend`, `windDownWrapUp`,
    `copyWrapUpNote`, `install(tool)`, `uninstall(tool)`,
    `updateSettings((inout Settings) -> Void)`, `previewNudge(kind)`, `previewBreak(kind)`,
    `openSettings`, `quit`.
- `MenuBar/` — `StatusItemController` (layered template images), popover root view.
- `Break/` — `TransientPanelStack` (anchor, stacking, priority, max 2), `NudgePanelController`,
  `CountdownChipController`, `BreakOverlayController` + one view per kind, `RoutinePlayerView`,
  `ResumeCardController`, `ToastController`, `WindDownCardController`.
- `Settings/` — settings window and one view per pane.
- `Onboarding/` — onboarding window and steps.
- `Tour/` — the one-minute tour's coach card, captions and popover strip (§3.12).
- `Services/` —
  - `ActivityMonitor`: produces `InputSample` (1 Hz, 10 Hz on request), `CallSignals` changes,
    `PresenceEvent`s (§2.4 APIs only).
  - `ActiveDisplay`: the `NSScreen` under the pointer.
  - `HotKeyCenter`: `RegisterEventHotKey` wrapper; register/unregister per surface.
  - `FocusRestorer` (in `Break/`): records `NSWorkspace.frontmostApplication` when a break starts; on close, if
    Breakpoint is frontmost, reactivates the recorded app (unless it quit). Never acts if the user
    switched apps during the break.
  - `OverlayWatchdog` (in `Break/`): while an overlay is up, the main thread stamps a heartbeat every 0.5 s; a
    dedicated background thread checks it. If the heartbeat is older than 3 s, it appends a line
    to `watchdog.log`, spawns `/bin/sh -c 'sleep 1; /usr/bin/open -g "<app path>"'` detached,
    and calls `_exit(70)`, which removes every window. The app relaunches into its normal state.
  - `HeadphoneMotionMonitor`, `SoundPlayer` (in `Break/`; synthesised chime, §4.7), `LoginItem`
    (`SMAppService.mainApp`).
  - `UpdateFetcher`: the release feed and, on Update, the archive (§2.11); the debug harness
    replaces it with local files or a simulated failure, so tests never reach the network.

### 7.3 Breakpoint (app, `Sources/BreakpointApp`)

`AppCoordinator` owns `SettingsStore`, `HistoryStore`, `SessionTracker`, `ActivityClock`,
`PresenceTracker`, `ActivityMonitor`, `EventSocketServer`, the engine loop (1 s tick for timers,
held opportunities and detectors, plus event-driven opportunities), the current `AutoDecision`,
and all window controllers. It builds an `EngineSnapshot` for each decision, maps Core state into
`AppState` and implements `AppActions`. It is the only place that knows about everything. Debug
launch argument `--debug-stall-main N` blocks the main thread for N seconds during the next
overlay (watchdog test); `--signals` prints the signal report and exits. Debug builds add the
end-to-end harness (`--debug-headless`, `--debug-simulate`, `--debug-timers`, `--debug-trace`;
see CLAUDE.md), compiled out of release builds.

---

## 8. Data on disk

`~/Library/Application Support/Breakpoint/`: `settings.json`, `history.jsonl`, `sessions.json`
(run-length estimator state), `rotation.json` (routine and copy rotation, including the walk-idea
and closing-line bags, §2.2: removed by
"Delete all data"; a missing or damaged file starts the rotation afresh), `integrations.json` (the integrations ledger: the original content
of files Breakpoint created or found empty, containers that were empty before, and folders it
created, so uninstall restores everything exactly; kept by "Delete all data"; updates hold an
flock on `integrations.lock`), `pending-update.json` (an in-place update between the swap and the new copy's confirmation),
`updates.json` (the update check: last attempt and check, the
newest release seen, a postponed version; §2.11), `breakpoint.sock`,
`watchdog.log`, `backups/` (integration file backups, `<tool>-<yyyyMMdd-HHmmss>.<ext>`).
`~/.breakpoint/`: `bin/breakpoint` (CLI copy), `shell/breakpoint.zsh`, `shell/breakpoint.bash`,
`run/` (socket fallback only).

---

## 9. Quality bar

- `swift build` and `swift test` pass with zero warnings in Core.
- Unit tests cover: engine decision order (every suppress, hold and offer branch), opportunity
  detector, `AwayPolicy` (short lock, idle away, call active, display-sleep assertion, Undo
  round-trip), `PausePolicy` cool-downs, tracker (stale fallback, interrupted runs, relayed
  duplicate drop, `idle_prompt`), every installer (fresh file, foreign entries preserved,
  idempotent, parse failure refused, exact uninstall), `HookPayloadParser` against the payload
  samples in `agent-integrations.md` for every tool, wire format.
- Every surface has snapshots in `build/snapshots/`, including: nudge for each kind, hover,
  auto-start at 10/5 and the countdown chip; overlay for each kind at entrance end, with
  Done visible, needs-you, and `walk` ambient; the `move` pace ring at up, top, down and a hold
  (also under Reduce Motion), a circle and a side; the closing moment frame by frame (and into the exit) and for
  each kind; three eye-rest tasks and three walk ideas; resume card (finished with a last message, snippets
  off, usage limit, other error, a failed and a finished command, needs-you asking to run a
  command, asking to edit, and with snippets off, several, several mixed, five, long text, hover
  with the keycap); away note;
  toast; the time rim (running, held, Reduce Motion) on the resume card, away note and toast;
  wind-down (card, holding, note); the update prompt (offer, installing, failed, hover, rim) and
  Settings → About in each update state; popover (normal, paused, decision line, the "Why not now?" line;
  totals after the first break, on the first day, a week in, a month in and with very large
  numbers); the menu-bar mark's movements as key-frame strips on light, dark and tinted bars;
  every settings pane; every onboarding page, the Connect step's rows (installing, connected, a failed install check) and the ✓ hop; every step of the tour (§3.12) with its coach line, the tour in place as a film, and every first-use hint on its surface (`hints/…`). Each in Reduce Transparency and Increase Contrast; system-following
  surfaces also in light and dark.
- Manual checks: `build/Breakpoint.app` shows the menu-bar item, receives
  `breakpoint emit agentStarted` and shows a nudge within a second (≈ 2 s after a key press);
  after a break ends the previously frontmost app is frontmost again; with
  `--debug-stall-main 5`, all overlays disappear within 4 s and the app relaunches; no permission
  prompt appears from first launch through a full break with every integration installed.
- Idle CPU ≈ 0%; memory under 80 MB; `emit` p95 < 50 ms.
- `scripts/e2e.sh` passes: the whole app, driven through the CLI with the headless debug harness.

---

## 10. Decisions

Where this spec departs from the research or from an earlier version, and why.

1. Credit natural breaks only through the away definition (idle ≥ threshold, or lock/sleep at
   least as long as the break), not after 20 s of idle input — reading agent output is idle but
   not an eye rest.
2. Active display = display under the pointer — another app's key window cannot be found
   without Accessibility or window-list access.
3. The overlay animates the blur view's opacity, not a blur radius — `NSVisualEffectView` has no
   public radius control.
4. The watchdog terminates and relaunches the app instead of closing windows — windows cannot be
   closed safely off the main thread, and process exit removes them all.
5. No sound during call signals, instead of "during recording or sharing" — those cannot be
   detected without a permission.
6. Call pauses name the signal ("microphone is on"), not the app — attributing audio to an app is
   app-use tracking.
7. Camera still pauses, as in an earlier version, but can be switched off separately, because camera
   detection is the main source of false positives.
8. Auto-start is cancelled by a key press rather than waiting for typing to stop — Principle 1.
9. The nudge is a heads-up card, not a 44 pt pill (the maintainer's decision); a compact variant
   is deferred.
10. Eye rest uses the plain timer skeleton (title, instruction, hairline, timer) instead of a
    120 pt ring, per the same direction.
11. One colour moment per pop-up: the badge is coloured and pop-up buttons are neutral glass;
    mint primary buttons appear on the overlay and wind-down card only.
12. Lowest text opacity raised from 40% to 50%, and the hint uses 50% — 40% white on the scrim
    falls below the 4.5:1 contrast rule.
13. No snooze stack behind Skip and no snooze timer — "Not now" defers to the next opportunity and
    breaks only start after the user accepted, so snoozing from the overlay adds nothing.
14. No Lock Screen button — there is no public API to lock the screen.
15. "1 more minute" on `move` and `breathe` only — `eyes` is too short and `walk` counts up.
16. Nudge hotkeys are registered only while a nudge is visible (and ⌃⌥⌘. also while a resume
    card is), so they never hold the key combination otherwise.
17. Toasts for call pauses only when a due break or visible nudge was affected — otherwise a
    toast would itself be an interruption at the start of a call.
18. Popover is dark glass in both modes (an earlier version followed the system), matching every
    other pop-up.
19. Pop-up position is user-selectable (top left / centre / right, default centre).
20. Pop-ups use the system Liquid Glass (`glassEffect`) on macOS 26 and later and
    `NSVisualEffectView` with drawn lighting on macOS 14 and 15 (§4.5) — each system gets its own
    native material. `GlassPanelBackground` holds both behind one availability check, so screens
    never choose; snapshots always show the macOS 14 and 15 look, approximated.
21. `Notifier` removed from Services — user notifications would require a permission prompt.
22. `hasBand` defaults off so the default routine needs no equipment. With it on, band routines
    join the rotation instead of replacing every stretch, so a band owner still gets variety.
23. `emit` takes the kind from its argument, not the payload — each hook is registered on one
    event, so this is simpler and immune to the host-name ambiguity in relayed Cursor events.
24. Codex legacy `notify` refuses to chain an existing `notify` — chaining is fragile and it is a
    fallback for old versions only.
25. The CLI is copied, not symlinked, to `~/.breakpoint/bin` — a symlink breaks when the app moves.
26. The interrupt fallback is 10 min for Claude Code (with a `PostToolUse` heartbeat) and 60 min
    elsewhere — long single tool calls emit nothing, so shorter values mark live runs idle.
27. The shell opportunity is named `longCommand` — the shell sends `commandStarted` at launch and
    only the app can tell 20 s later that it is long.
28. Display-sleep assertions (count only) stop idle from counting as away — video and
    presentations hold them; read without a permission and without app names.
29. Some values are set by eye rather than on the grid: nudge ignore time
    10 s, overlay entrance ≈ 1.55 s, timer 38 pt semibold at 60%, title 3.3% of width, vertical
    rhythm 58 / 44 / 66 pt, card radius 28, settings window 860 × 770.
30. The resume card dismisses with the nudge's ⌃⌥⌘. rather than a key of its own — one "dismiss"
    key to learn; the nudge keeps priority while both show, so the key never surprises.
31. Agent messages and request subjects follow "Keep prompt snippets" instead of a new setting —
    they are at least as sensitive as prompts, and one switch is easier to trust.
32. Long shell commands on the resume card show the command's name only ("swift failed after
    4 min"), because the shell integration sends only the first word (§5.5); sending more would
    change the installed snippets for a little more detail.
33. The overlay's backdrop is staged in layers (blur, vignette, scrim, aurora) rather than one
    fade, and the aurora is laid on in deep tones as well as added as light, at a stronger
    presence than an earlier version's 12% — that aurora was all but invisible over the blurred desktop. Its
    lights are Breakpoint's own mint → indigo family; no wallpaper is read (Principle 1), so the
    desktop's own colours reach the backdrop only through the live blur.
34. Offers are at least 10 min apart (the maintainer's decision); 5 min felt like nagging. With nudge
    spacing equal to kind spacing, the other due kind can come only in the moments between the
    end of nudge spacing (counted from the nudge) and of kind spacing (counted from the answer),
    or through a typing pause when only it is well overdue.
35. A break the person started counts however briefly it ran and however it ends (the maintainer's
    decision): it is just less time, and only the totals show it was short. Before, a stretch or
    walk counted only after 60 s, an eye rest only after half its time, and Skip on an eye rest
    or breather was a refusal, so someone who had rested was asked again as if they had said no.
    `skipped` is no longer recorded; older lines are still read. The 3 s Skip guard stays: it
    protects against a stray key press, not against a short break.
36. A breather the person started holds off the stretch for one move cadence instead of
    restarting still time (the maintainer's decision). Restarting still time would make "since you
    moved" untrue; leaving the slot open asked for a stretch again ten minutes after every
    breather, so someone who turned stretches down was asked every ten minutes all day.
37. A microphone counts as a call only after 60 s on — dictating a prompt to an agent switched
    the call pause on and off with every prompt (a toast, then a cool-down that dropped the
    prompt's own offer). Before 60 s offers are held, so nothing appears while a microphone is in
    use (Principle 1); the cost is that an audio-only call's pause starts a minute in.
38. A mirrored or kept-awake display makes Breakpoint quieter rather than paused — no typing-pause
    offers, no eye rest that starts by itself — because keep-awake tools hold the display-sleep
    assertion all day and a pause would silence those people for good; an agent's small nudge
    still comes and starts nothing by itself. Scrolling cancels an eye-rest countdown like a key
    press (reading); moving the pointer does not, since the countdown chip follows the pointer.
39. The step tick is **on by default**, unlike the other sounds: the stretch is meant to be
    followable without watching, and a tick nobody hears about does not do that. It is 10 dB
    under the chimes, plays at most a few times in a two-minute stretch the user chose to start,
    never during a call, and has its own switch.
40. The closing moment is skipped after Back to work: the user is on the way to their agent.
41. Done turns mint where Skip was rather than moving to the rightmost place, so the button
    under the pointer never changes job at 80%.
42. The Routine pane stays small (the maintainer's decision): one list with a checkbox per routine and
    Preview a stretch. No pins (every routine has the same weight), no per-routine steps or ▶ at
    4× (Preview a stretch shows the real screen), no "Next" marker or counts. A checkbox stays
    because some routines are standing ones that not everyone can do.
43. From the third refusal in a row, a slot waits its whole cadence instead of ten minutes. With
    decisions 34–36 alone, someone who says Not now to everything (or lets every nudge go)
    was still offered something every ten minutes from morning to evening: 47 offers in an
    eight-hour simulated day, a breather every twenty minutes, because only a breather that was
    taken held the slot. Now the same day has 30, each kind asked about once per its cadence after
    the first three noes. Ignoring now counts like Not now (both were already refusals for kind
    spacing), so two ignored stretches also lead to the breather. It is silent on purpose: the
    rule only spaces out offers the person keeps turning down, so a note saying so would be one
    more interruption; "Why not now?" names it. It is not a score: the count is never shown, and
    taking any one break of that kind, or time away, ends it. An earlier version of this idea
    lengthened the stretch cadence for the rest of the day and announced it with Undo; it was
    dropped for this smaller rule that composes with 34–36.

---

## 11. Reviewer checklist

Answer each with yes or no for the screen under review; any wrong answer blocks merge.

1. **Timing:** is this surface kept from appearing while the user is typing or dragging, while a
   microphone or camera is in use, and within the cool-downs of §2.4?
2. **No surprise:** before anything full-screen, did a smaller pop-up state *what* and *how long*
   (nudge, and for auto-start the countdown chip)?
3. **Focus:** does the frontmost app stay frontmost, or get restored after the overlay?
4. **Explain:** if Breakpoint decided something on its own, does the UI say what and why in one
   sentence, with Undo where timers changed, and no blocking question?
5. **Hierarchy:** can the single most important element be named within a second? Is the timer
   quieter than the title and instruction (except on `breathe`)?
6. **Colour:** does each pop-up have exactly one colour moment (badge, or mint primary where no
   badge exists), with everything else neutral? Indigo only for agent activity, amber only for
   needs-you?
7. **Material and shape:** shared dark glass with rim and two-layer shadow, capsule controls,
   continuous corners, the stated radii and spacing?
8. **Numbers:** monospaced digits that roll rather than jump?
9. **Motion:** values from §4.6; nothing bounces; overlay entrance ≈ 1.55 s in the stated order;
   Reduce Motion gives plain cross-fades?
10. **Keyboard:** every action reachable by keyboard, keycaps on the main ones, double Esc to skip
    the overlay, hotkeys for the nudge?
11. **Accessibility:** contrast ≥ 4.5:1 on white and busy wallpapers; solid fallbacks under Reduce
    Transparency; Increase Contrast handled; state shown by shape or text, not colour alone;
    VoiceOver labels and announcements present?
12. **Words:** kind and length stated; offers ≤ 7 words; no "should", no "!", no medical claims,
    no guilt counters, no score; the cause named when Breakpoint acted on its own?
13. **Agent:** if an agent is involved, does the surface say what it is doing (working, done,
    needs you)?
14. **Privacy and permissions:** does it read only the §2.4 signals and tool events, and trigger
    no permission prompt?
15. **Identity:** is everything in §4.1 Breakpoint's own — name, mark, palette and gradient,
    wording — with no character art or borrowed copy?
16. **States:** are snapshots present for every state listed in §9 for this surface?
