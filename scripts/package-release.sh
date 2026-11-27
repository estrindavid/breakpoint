#!/bin/bash
# Packages a built app for a GitHub release (run by .github/workflows/release.yml after
# scripts/build-app.sh):
#
#   scripts/package-release.sh APP VERSION "One line of what's new" OUTDIR [WINDOWS_ZIP]
#
# Writes into OUTDIR:
#   Breakpoint-VERSION.zip   the app, zipped with ditto, without extended attributes
#   update-feed.json         what the app reads: version, notes, page, archive, size, SHA-256 and
#                            the Ed25519 signature made with $UPDATE_SIGNING_KEY
#   install.sh               the one-line installer (scripts/install.sh)
#   SHA256SUMS               checksums of the zips, the feeds and the installers
#   release-notes.md         the release's text: the line and how to install
# and, given WINDOWS_ZIP (Breakpoint-VERSION-windows-x64.zip from scripts/windows/package.ps1):
#   Breakpoint-VERSION-windows-x64.zip   that zip, signed with the same key
#   update-feed-windows.json             what the Windows app reads (minimum Windows 10 2004)
#   install.ps1                          the Windows one-line installer (scripts/windows/install.ps1)
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
WINDOWS_ZIP="${5:-}"
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
SUMMED=("Breakpoint-$VERSION.zip" update-feed.json install.sh)

if [[ -n "$WINDOWS_ZIP" ]]; then
  WIN_NAME="Breakpoint-$VERSION-windows-x64.zip"
  [[ "$(basename "$WINDOWS_ZIP")" == "$WIN_NAME" ]] || { echo "error: the Windows zip must be named $WIN_NAME" >&2; exit 1; }
  # The zip says which version it holds (breakpoint-app.json, what install.ps1 and updates check).
  WIN_VERSION="$(unzip -p "$WINDOWS_ZIP" Breakpoint/breakpoint-app.json | jq -r .version)"
  [[ "$WIN_VERSION" == "$VERSION" ]] || { echo "error: the Windows zip holds $WIN_VERSION, the release says $VERSION" >&2; exit 1; }
  cp "$WINDOWS_ZIP" "$OUT/$WIN_NAME"
  WIN_SIGNATURE="$($SIGN sign "$VERSION" "$OUT/$WIN_NAME")"
  $SIGN verify "$VERSION" "$OUT/$WIN_NAME" "$WIN_SIGNATURE" "$COMMITTED" || { echo "error: the Windows signature does not verify" >&2; exit 1; }
  echo "Signed the Windows zip with the release key."
  # Windows 10 2004 (build 19041): AF_UNIX sockets and the APIs the app uses.
  MINIMUM_SYSTEM_VERSION=10.0.19041 scripts/make-update-feed.sh "$VERSION" "$NOTES" "$OUT/$WIN_NAME" "$WIN_SIGNATURE" \
    > "$OUT/update-feed-windows.json"
  cp scripts/windows/install.ps1 "$OUT/install.ps1"
  SUMMED+=("$WIN_NAME" update-feed-windows.json install.ps1)
fi
(cd "$OUT" && shasum -a 256 "${SUMMED[@]}" > SHA256SUMS)

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
  if [[ -n "$WINDOWS_ZIP" ]]; then
    echo
    echo "**Windows 10 (2004) or 11, 64-bit** (PowerShell; no administrator):"
    echo
    echo '```powershell'
    echo "irm $REPO_URL/releases/latest/download/install.ps1 | iex"
    echo '```'
    echo
    echo "Breakpoint for Windows updates itself the same way (Settings → About → Update). The installer"
    echo "checks the download against this release's checksum. The app is not code-signed, so a browser"
    echo "download of the zip may be flagged by SmartScreen; the installer above avoids that."
  fi
} > "$OUT/release-notes.md"

ls -1 "$OUT"
