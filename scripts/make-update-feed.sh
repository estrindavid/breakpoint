#!/bin/bash
# Prints the release feed the app reads (SPEC §2.11), as JSON on stdout:
#
#   scripts/make-update-feed.sh VERSION "One line of what's new" ARCHIVE [SIGNATURE]
#
# ARCHIVE is the zipped app (Breakpoint-VERSION.zip): its size and SHA-256 go into the feed.
# SIGNATURE is its Ed25519 signature (scripts/update-signing.swift sign); without it the feed
# only announces the version, and apps open the download page instead of installing.
# The release workflow attaches the output to every release as update-feed.json; apps read
# https://github.com/<repo>/releases/latest/download/update-feed.json. The repository address comes
# from UpdateFeed.repository in Sources/BreakpointCore/Models/Updates.swift. Needs jq.
#
# The minimum system version is macOS's (MINIMUM_SYSTEM in scripts/build-app.sh) unless
# MINIMUM_SYSTEM_VERSION is set: the Windows feed (update-feed-windows.json) passes Windows' own.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:?usage: make-update-feed.sh VERSION NOTES ARCHIVE [SIGNATURE]}"
NOTES="${2:-}"
ARCHIVE="${3:?archive}"
SIGNATURE="${4:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "error: '$VERSION' is not X.Y.Z" >&2; exit 1; }
[[ -f "$ARCHIVE" ]] || { echo "error: no archive at $ARCHIVE" >&2; exit 1; }

REPO_URL="$(sed -n 's/.*static let repository = URL(string: "\(.*\)")!.*/\1/p' Sources/BreakpointCore/Models/Updates.swift)"
[[ -n "$REPO_URL" ]] || { echo "error: could not read UpdateFeed.repository" >&2; exit 1; }
MIN_SYSTEM="${MINIMUM_SYSTEM_VERSION:-$(sed -n 's/^MINIMUM_SYSTEM="\([0-9.]*\)"$/\1/p' scripts/build-app.sh)}"
[[ "$MIN_SYSTEM" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "error: could not read MINIMUM_SYSTEM from scripts/build-app.sh" >&2; exit 1; }
SIZE="$(wc -c < "$ARCHIVE" | tr -d ' ')"
if command -v shasum >/dev/null; then
  SHA256="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
else
  SHA256="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
fi

jq -n \
  --arg version "$VERSION" \
  --arg notes "$NOTES" \
  --arg page "$REPO_URL/releases/tag/v$VERSION" \
  --arg archive "$REPO_URL/releases/download/v$VERSION/$(basename "$ARCHIVE")" \
  --argjson size "$SIZE" \
  --arg sha256 "$SHA256" \
  --arg signature "$SIGNATURE" \
  --arg minimum "$MIN_SYSTEM" \
  --arg published "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{version: $version, notes: $notes, page: $page, archive: $archive, size: $size, sha256: $sha256}
   + (if $signature == "" then {} else {signature: $signature} end)
   + {minimumSystemVersion: $minimum, published: $published}'
