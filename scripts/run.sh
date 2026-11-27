#!/bin/bash
# Builds build/Breakpoint.app and opens it. Quits a running copy first. Extra arguments are passed
# to the app (e.g. scripts/run.sh --show-onboarding, --debug-stall-main 5).
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/build-app.sh

if pgrep -x Breakpoint > /dev/null; then
  echo "==> Quitting the running Breakpoint"
  pkill -x Breakpoint || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Breakpoint > /dev/null || break
    sleep 0.3
  done
fi

echo "==> Opening build/Breakpoint.app"
if [[ $# -gt 0 ]]; then
  open build/Breakpoint.app --args "$@"
else
  open build/Breakpoint.app
fi
