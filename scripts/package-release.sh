#!/bin/bash
# Packages a built app for a GitHub release (run by .github/workflows/release.yml after
# scripts/build-app.sh):
#
#   scripts/package-release.sh APP VERSION "One line of what's new" OUTDIR
#
# Writes into OUTDIR:
#   Breakpoint-VERSION.zip   the app, zipped with ditto, without extended attributes
#   update-feed.json         what the app reads: version, notes, page, archive, size, SHA-256 and
#                            the Ed25519 signature made with $UPDATE_SIGNING_KEY
#   install.sh               the one-line installer (scripts/install.sh)
#   SHA256SUMS               checksums of the zip and the feed
#   release-notes.md         the release's text: the line and how to install
# It fails if UPDATE_SIGNING_KEY is missing or UpdateKey.swift still holds nil (run
# scripts/release-keygen.sh and commit the public key first), and checks that the key matches the
# public key compiled into this version, so a release can never be unsigned or signed with a key
# its app ignores. A dry run of the workflow passes a throwaway key and writes its public half.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:?usage: package-release.sh APP VERSION NOTES OUTDIR}"
VERSION="${2:?version}"
NOTES="${3:-}"
OUT="${4:?output folder}"
SIGN="swift scripts/update-signing.swift"

[[ -d "$APP/Contents" ]] || { echo "error: $APP is not an app bundle" >&2; exit 1; }
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || { echo "error: the app says $APP_VERSION, the release says $VERSION" >&2; exit 1; }

FIX="run scripts/release-keygen.sh and commit the public key it writes first (docs/RELEASING.md); an unsigned release could never update itself"
COMMITTED="$(sed -n 's/.*publicKeyBase64: String? = "\(.*\)".*/\1/p' Sources/BreakpointCore/Updates/UpdateKey.swift)"
[[ -n "$COMMITTED" ]] || { echo "error: UpdateKey.publicKeyBase64 is nil: $FIX" >&2; exit 1; }
[[ -n "${UPDATE_SIGNING_KEY:-}" ]] || { echo "error: UPDATE_SIGNING_KEY is not set: $FIX" >&2; exit 1; }
[[ "$($SIGN public)" == "$COMMITTED" ]] || { echo "error: UPDATE_SIGNING_KEY does not match the public key in UpdateKey.swift" >&2; exit 1; }

mkdir -p "$OUT"
ZIP="$OUT/Breakpoint-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

SIGNATURE="$($SIGN sign "$VERSION" "$ZIP")"
$SIGN verify "$VERSION" "$ZIP" "$SIGNATURE" "$COMMITTED" || { echo "error: the signature does not verify" >&2; exit 1; }
echo "Signed with the release key."
scripts/make-update-feed.sh "$VERSION" "$NOTES" "$ZIP" "$SIGNATURE" > "$OUT/update-feed.json"
cp scripts/install.sh "$OUT/install.sh"
(cd "$OUT" && shasum -a 256 "Breakpoint-$VERSION.zip" update-feed.json install.sh > SHA256SUMS)

REPO_URL="$(sed -n 's/.*static let repository = URL(string: "\(.*\)")!.*/\1/p' Sources/BreakpointCore/Models/Updates.swift)"
{
  [[ -n "$NOTES" ]] && printf '%s\n\n' "$NOTES"
  echo "**Install or update** (Terminal):"
  echo
  echo '```sh'
  echo "curl -fsSL $REPO_URL/releases/latest/download/install.sh | bash"
  echo '```'
  echo
  echo "Breakpoint already installed? It offers this version by itself; Settings → About → Update."
  echo
  echo "Downloading the zip in a browser instead: open it, move Breakpoint to Applications, open it once,"
  echo "then go to System Settings → Privacy & Security and click **Open Anyway** (the app is not signed"
  echo "by Apple; see the README)."
} > "$OUT/release-notes.md"

ls -1 "$OUT"
