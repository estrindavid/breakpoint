#!/bin/bash
# Runs the Swift Testing suite. Extra arguments pass through to `swift test` (e.g. --filter Wire).
#
# With only Apple's Command Line Tools installed, `swift test` cannot find the Testing module on
# its own; this adds the framework search paths and rpaths when that is the situation. With full
# Xcode selected, it runs plain `swift test`.
set -euo pipefail

cd "$(dirname "$0")/.."

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_USR_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
DEVELOPER_DIR_SELECTED="$(xcode-select -p 2>/dev/null || true)"

FLAGS=()
if [[ -d "$CLT_FRAMEWORKS" && "$DEVELOPER_DIR_SELECTED" != *".app/Contents/Developer"* ]]; then
  FLAGS=(
    -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS"
    -Xlinker -F -Xlinker "$CLT_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$CLT_USR_LIB"
  )
fi

# The CLI tests run the built `breakpoint` executable, which `swift test` does not rebuild.
swift build --product breakpoint ${FLAGS[@]+"${FLAGS[@]}"}
exec swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
