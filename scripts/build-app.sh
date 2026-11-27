#!/bin/bash
# Release build of build/Breakpoint.app: the menu-bar app (no Dock icon), the `breakpoint` CLI in
# Contents/Helpers, the app icon rendered from the brand mark, ad-hoc signed. Prints the app path.
# Safe to run repeatedly; fails loudly on any error.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP="$ROOT/build/Breakpoint.app"
BUNDLE_ID="com.breakpointapp.Breakpoint"
VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/BreakpointCore/Models/Version.swift)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
[[ -n "$VERSION" ]] || { echo "error: could not read the version from Version.swift" >&2; exit 1; }

MINIMUM_SYSTEM="14.0"
# BREAKPOINT_ARCHS="arm64 x86_64" builds each architecture on its own and joins them with lipo into
# one universal app (the release workflow does this, so Intel Macs on macOS 14 or 15 run it too).
# Unset: the host's architecture only, as before.
ARCHS="${BREAKPOINT_ARCHS:-}"

echo "==> Building release products"
if [[ -z "$ARCHS" ]]; then
  swift build -c release --product BreakpointApp
  swift build -c release --product breakpoint
  swift build -c release --product BreakpointSnapshots
  BIN="$(swift build -c release --show-bin-path)"
  APP_BINARY="$BIN/BreakpointApp"
  CLI_BINARY="$BIN/breakpoint"
else
  HOST_TRIPLE="$(uname -m)-apple-macosx"
  APP_SLICES=()
  CLI_SLICES=()
  for arch in $ARCHS; do
    swift build -c release --triple "$arch-apple-macosx" --product BreakpointApp
    swift build -c release --triple "$arch-apple-macosx" --product breakpoint
    ARCH_BIN="$(swift build -c release --triple "$arch-apple-macosx" --show-bin-path)"
    APP_SLICES+=("$ARCH_BIN/BreakpointApp")
    CLI_SLICES+=("$ARCH_BIN/breakpoint")
  done
  # The icon renderer runs here and is not shipped: the host's architecture is enough.
  swift build -c release --triple "$HOST_TRIPLE" --product BreakpointSnapshots
  BIN="$(swift build -c release --triple "$HOST_TRIPLE" --show-bin-path)"
  UNIVERSAL="$ROOT/build/universal"
  rm -rf "$UNIVERSAL"
  mkdir -p "$UNIVERSAL"
  lipo -create "${APP_SLICES[@]}" -output "$UNIVERSAL/BreakpointApp"
  lipo -create "${CLI_SLICES[@]}" -output "$UNIVERSAL/breakpoint"
  APP_BINARY="$UNIVERSAL/BreakpointApp"
  CLI_BINARY="$UNIVERSAL/breakpoint"
fi

for binary in "$APP_BINARY" "$CLI_BINARY" "$BIN/BreakpointSnapshots"; do
  [[ -x "$binary" ]] || { echo "error: missing $binary" >&2; exit 1; }
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
# The executable target is BreakpointApp (a case-insensitive file system cannot hold both
# "Breakpoint" and "breakpoint" products); inside the bundle it is renamed to Breakpoint.
cp "$APP_BINARY" "$APP/Contents/MacOS/Breakpoint"
# The CLI lives in Contents/Helpers (Contents/MacOS/breakpoint would collide with Breakpoint).
cp "$CLI_BINARY" "$APP/Contents/Helpers/breakpoint"
[[ -z "${UNIVERSAL:-}" ]] || rm -rf "$UNIVERSAL"

# Debug-map entries point at the build machine's object files, which no other Mac has; only they
# are removed (strip -S). Function names stay, so macOS crash reports still name each frame. (strip
# warns that this invalidates the linker's signature; both are signed again below.)
strip -S "$APP/Contents/MacOS/Breakpoint" "$APP/Contents/Helpers/breakpoint"

# Every requested architecture is in both binaries, each built for macOS $MINIMUM_SYSTEM.
for binary in "$APP/Contents/MacOS/Breakpoint" "$APP/Contents/Helpers/breakpoint"; do
  for arch in $ARCHS; do
    lipo "$binary" -verify_arch "$arch" || { echo "error: $binary has no $arch slice" >&2; exit 1; }
  done
  for arch in $(lipo -archs "$binary"); do
    MINOS="$(otool -arch "$arch" -l "$binary" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" && !done { print $2; done = 1 }')"
    [[ "$MINOS" == "$MINIMUM_SYSTEM" ]] || { echo "error: $binary ($arch) is built for macOS $MINOS, not $MINIMUM_SYSTEM" >&2; exit 1; }
  done
  echo "$(basename "$binary"): $(lipo -archs "$binary"), macOS $MINIMUM_SYSTEM or later"
done

echo "==> Rendering the app icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT
"$BIN/BreakpointSnapshots" --app-icon "$ICONSET" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Breakpoint</string>
  <key>CFBundleExecutable</key>
  <string>Breakpoint</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Breakpoint</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MINIMUM_SYSTEM}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>General wellness, not medical advice.</string>
  <key>NSMotionUsageDescription</key>
  <string>Breakpoint uses head motion from your AirPods during stretches and walks to note that you moved. Only a yes or no is kept, on this Mac.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" > /dev/null

echo "==> Signing (ad hoc)"
codesign --force --sign - --identifier "${BUNDLE_ID}.cli" "$APP/Contents/Helpers/breakpoint"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "$APP"
