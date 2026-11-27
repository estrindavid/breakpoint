#!/bin/bash
# Renders the README's hero picture (docs/readme/assets/hero.webp) from hero.html in this folder.
#
#   docs/readme/src/render.sh [hero]
#
# Needs: Google Chrome (headless), python3 with Pillow, and the two snapshots the page crops,
# break/overlay-move-middle-wallpaper-dark and break/nudge-move-on-dark
# (scripts/snapshots.sh break/overlay-move-middle-wallpaper break/nudge-move → build/snapshots),
# read through a temporary link, snap/. Override their location with
# BP_SNAPSHOTS. Writes assets/hero.webp at 2x (1660 px wide) with transparent corners; the 2x
# master goes to src/tmp/, which is ignored; delete it when done.
#
# assets/film.webp is a screen recording kept as a file; nothing here generates it.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ../../..)"
SNAP="${BP_SNAPSHOTS:-$ROOT/build/snapshots}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -d "$SNAP" ] || { echo "No snapshots at $SNAP (run scripts/snapshots.sh, or set BP_SNAPSHOTS)"; exit 1; }
for arg in "$@"; do [ "$arg" == hero ] || { echo "Unknown picture: $arg (only hero)"; exit 1; }; done
ln -sfn "$SNAP" snap
trap 'rm -f snap' EXIT

name=hero w=830 h=540
mkdir -p ../assets tmp
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --force-device-scale-factor=2 --window-size="$w,$h" --virtual-time-budget=4000 \
  --allow-file-access-from-files --screenshot="$PWD/tmp/$name.png" "file://$PWD/$name.html" >/dev/null 2>&1
python3 - "$PWD/tmp/$name.png" "$PWD/../assets" "$name" <<'PY'
import sys, os
from PIL import Image
src, out, name = sys.argv[1:4]
im = Image.open(src).convert("RGBA")
# One file for both of GitHub's themes: a lossy WebP that keeps the transparent corners, so no
# page colour is baked in (baked corners showed white on a dark page whenever GitHub served the
# light variant).
path = f"{out}/{name}.webp"
im.save(path, "WEBP", quality=90, method=6, alpha_quality=100, exact=False)
print(f"assets/{name}.webp  {os.path.getsize(path)//1024} KB")
PY
