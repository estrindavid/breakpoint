#!/bin/bash
# Builds and runs the snapshot tool: renders registered views to build/snapshots/*.png at 2x and
# prints each path written. Arguments are name filters (substrings), e.g.:
#   scripts/snapshots.sh            # everything (stale images are removed first)
#   scripts/snapshots.sh design/    # only the design system
#   scripts/snapshots.sh nudge overlay
#   scripts/snapshots.sh --list     # names only
set -euo pipefail

cd "$(dirname "$0")/.."

swift build --product BreakpointSnapshots
BIN="$(swift build --show-bin-path)"

OUT="build/snapshots"
if [[ $# -eq 0 ]]; then
  rm -rf "$OUT"
fi
mkdir -p "$OUT"

exec "$BIN/BreakpointSnapshots" --out "$OUT" "$@"
