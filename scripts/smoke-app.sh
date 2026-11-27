#!/bin/bash
# Launches build/Breakpoint.app against a temporary home folder (never the real one), checks that
# it stays running as a menu-bar-only app (UIElement, accessory policy, a status item), then lets it
# quit itself through NSApp.terminate and checks the exit status. Run scripts/build-app.sh first.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Breakpoint.app"
[[ -x "$APP/Contents/MacOS/Breakpoint" ]] || { echo "error: build the app first (scripts/build-app.sh)" >&2; exit 1; }
if pgrep -x Breakpoint > /dev/null; then
  echo "error: Breakpoint is already running; quit it first" >&2
  exit 1
fi

HOME_DIR="$(mktemp -d)"
trap 'rm -rf "$HOME_DIR"' EXIT
# Onboarding counts as done, so the only thing on screen is the menu-bar item (no window opens or
# takes focus while someone works at this Mac).
mkdir -p "$HOME_DIR/Library/Application Support/Breakpoint"
echo '{"version":1,"hasCompletedOnboarding":true}' > "$HOME_DIR/Library/Application Support/Breakpoint/settings.json"
START="$(date '+%Y-%m-%d %H:%M:%S')"

BREAKPOINT_HOME="$HOME_DIR" "$APP/Contents/MacOS/Breakpoint" --quit-after 6 > /dev/null 2>&1 &
PID=$!
sleep 3

kill -0 "$PID" 2> /dev/null || { echo "FAIL: the app exited early" >&2; exit 1; }
TYPE="$(lsappinfo info -only ApplicationType -app "$PID" 2> /dev/null || true)"
[[ "$TYPE" == *UIElement* ]] || { echo "FAIL: application type is '$TYPE', expected UIElement (no Dock icon)" >&2; exit 1; }
echo "ok: running as pid $PID, $TYPE"

set +e
wait "$PID"
STATUS=$?
set -e
[[ $STATUS -eq 0 ]] || { echo "FAIL: exit status $STATUS" >&2; exit 1; }
echo "ok: quit cleanly (exit 0)"

LOG="$(log show --style compact --info --start "$START" --predicate 'subsystem == "com.breakpointapp.Breakpoint"' 2> /dev/null || true)"
grep -q "activation policy: accessory" <<< "$LOG" || { echo "FAIL: no accessory activation policy in the log" >&2; exit 1; }
# The item exists either way; macOS hides it (off screen) when the menu bar is full.
grep -qE "Status item: (frame|none \(hidden by macOS: frame)" <<< "$LOG" || { echo "FAIL: no status item in the log" >&2; exit 1; }
if grep -q "Status item: none (hidden" <<< "$LOG"; then
  echo "note: macOS is hiding the status item (menu bar full?); the popover then opens from the top right"
fi
grep -q "Breakpoint stopped" <<< "$LOG" || { echo "FAIL: applicationWillTerminate did not run" >&2; exit 1; }
grep "Status item: " <<< "$LOG" | tail -1 | sed 's/^.*Status item/ok: status item/'
echo "PASS"
