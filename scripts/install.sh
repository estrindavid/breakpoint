#!/bin/bash
# Installs (or updates) Breakpoint from its latest GitHub release:
#
#   curl -fsSL https://github.com/estrindavid/breakpoint/releases/latest/download/install.sh | bash
#
# What it does, and nothing else:
#   1. downloads update-feed.json and Breakpoint-<version>.zip from the latest release (curl, HTTPS);
#   2. checks the zip's size and SHA-256 against the feed, the app's bundle identifier, and that the
#      app has code for this Mac's processor (Apple silicon or Intel);
#   3. puts Breakpoint.app in /Applications, or ~/Applications if /Applications is not writable,
#      replacing an older copy (its settings and history live elsewhere and stay);
#   4. prints what it did. It does not open the app, change any setting, or ask for a password.
# Files fetched by curl carry no quarantine flag, so macOS opens the app without the
# "unidentified developer" dialog (SPEC §2.11, docs/RELEASING.md).
#
# For testing only: BREAKPOINT_INSTALL_BASE (where the release files are, e.g. file:///tmp/r),
# BREAKPOINT_INSTALL_DIR (the folder to install into), BREAKPOINT_INSTALL_ALLOW_RUNNING=1.
#
# Everything below is one { … } block: bash reads all of it before running any of it, so a
# download cut short runs nothing at all.
{
set -euo pipefail

BASE="${BREAKPOINT_INSTALL_BASE:-https://github.com/estrindavid/breakpoint/releases/latest/download}"
BUNDLE_ID="com.breakpointapp.Breakpoint"

die() { echo "Breakpoint was not installed: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "Breakpoint runs on macOS only."
MACOS="$(sw_vers -productVersion)"
if [[ "${BREAKPOINT_INSTALL_ALLOW_RUNNING:-}" != 1 ]] && pgrep -xq Breakpoint; then
  die "Breakpoint is running. Quit it first (menu-bar icon → right-click → Quit), then run this again."
fi

WORK="$(mktemp -d -t breakpoint-install)"
TARGET=""
# If anything stops the swap halfway (an error, Ctrl-C), the old copy goes back in place.
cleanup() {
  if [[ -n "$TARGET" && -d "$WORK/previous.app" && ! -e "$TARGET" ]]; then mv "$WORK/previous.app" "$TARGET" || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "Fetching the latest release…"
curl -fsSL --proto '=https,file' --proto-redir '=https' "$BASE/update-feed.json" -o "$WORK/feed.json" || die "could not download the release information."
field() { plutil -extract "$1" raw -o - "$WORK/feed.json" 2>/dev/null; }
VERSION="$(field version)" || die "the release information is not readable."
SHA256="$(field sha256)" || die "the release information has no checksum."
SIZE="$(field size)" || die "the release information has no size."
MINIMUM="$(field minimumSystemVersion || echo 14.0)"
[[ "$VERSION" =~ ^[0-9A-Za-z.-]+$ ]] || die "the release information names no version."
[[ "$MINIMUM" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "the release information names no macOS version."
if [[ "$(printf '%s\n%s\n' "$MINIMUM" "$MACOS" | sort -t. -k1,1n -k2,2n | head -1)" != "$MINIMUM" ]]; then
  die "Breakpoint $VERSION needs macOS $MINIMUM or later; this Mac has $MACOS."
fi

ZIP="Breakpoint-$VERSION.zip"
echo "Downloading Breakpoint ${VERSION}…"
curl -fSL --progress-bar --proto '=https,file' --proto-redir '=https' "$BASE/$ZIP" -o "$WORK/$ZIP" || die "the download did not finish."
[[ "$(stat -f %z "$WORK/$ZIP")" == "$SIZE" ]] || die "the download has the wrong size."
[[ "$(shasum -a 256 "$WORK/$ZIP" | cut -d' ' -f1)" == "$SHA256" ]] || die "the download does not match its checksum."

ditto -x -k "$WORK/$ZIP" "$WORK/unpacked" || die "the download could not be unpacked."
NEW="$WORK/unpacked/Breakpoint.app"
[[ -d "$NEW" ]] || die "the download does not contain Breakpoint.app."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]] \
  || die "the download is not Breakpoint."
# An app without code for this Mac's processor would not open: refuse before replacing anything.
if [[ "$(sysctl -n hw.optional.arm64 2> /dev/null)" == 1 ]]; then CPU=arm64 CPU_NAME="Apple silicon"; else CPU=x86_64 CPU_NAME="Intel"; fi
[[ "$(file -b "$NEW/Contents/MacOS/Breakpoint" 2> /dev/null || true)" == *"$CPU"* ]] \
  || die "Breakpoint $VERSION does not run on this Mac's processor ($CPU_NAME)."

if [[ -n "${BREAKPOINT_INSTALL_DIR:-}" ]]; then
  DEST="$BREAKPOINT_INSTALL_DIR"
elif [[ -w /Applications ]]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST" || die "could not create $DEST."
TARGET="$DEST/Breakpoint.app"

PREVIOUS=""
if [[ -e "$TARGET" ]]; then
  PREVIOUS="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist" 2>/dev/null || echo "an earlier version")"
  mv "$TARGET" "$WORK/previous.app" || die "could not move the old copy out of $DEST."
fi
if ! mv "$NEW" "$TARGET"; then
  [[ -n "$PREVIOUS" ]] && mv "$WORK/previous.app" "$TARGET"
  die "could not write to $DEST."
fi

echo
if [[ "$PREVIOUS" == "$VERSION" ]]; then
  echo "Reinstalled Breakpoint $VERSION in $TARGET."
elif [[ -n "$PREVIOUS" ]]; then
  echo "Updated Breakpoint $PREVIOUS → $VERSION in $TARGET."
else
  echo "Installed Breakpoint $VERSION in $TARGET."
fi
echo "Checked: size and SHA-256 match the release. Nothing was opened or changed besides that app."
echo "Open it from $DEST or Spotlight; it lives in the menu bar."
exit 0
}
