#!/bin/bash
# Ships a new version of Breakpoint, in one command (docs/RELEASING.md):
#
#   scripts/release.sh 0.3.0 "Breaks now wait for Codex too."
#   scripts/release.sh 0.3.0 "…" --dry-run     # checks and shows what it would do; changes nothing
#
# 1. Checks: the release key's public half is committed (UpdateKey.swift is not nil; a dry run only
#    warns), on main, nothing uncommitted, level with origin/main, no tag for the version yet, and
#    the version strictly higher than the current one in Version.swift.
# 2. Sets BreakpointVersion.current (Sources/BreakpointCore/Models/Version.swift, the one place the
#    version lives) and commits "Release 0.3.0".
# 3. Tags v0.3.0 with the line as the tag message, and pushes main and the tag together.
# The tag starts .github/workflows/release.yml on GitHub, which builds, signs the zip with the
# release key, and publishes the release with update-feed.json and install.sh; within a day every
# copy with automatic checks on offers "Breakpoint 0.3.0 is ready" with Update.
# Without the release key there is no release: run scripts/release-keygen.sh and commit the public
# key first (docs/RELEASING.md).
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-}"
NOTES="${2:-}"
DRY_RUN=0
[[ "${3:-}" == "--dry-run" ]] && DRY_RUN=1
BRANCH="${RELEASE_BRANCH:-main}"
REMOTE="${RELEASE_REMOTE:-origin}"
VERSION_FILE="Sources/BreakpointCore/Models/Version.swift"
KEY_FILE="Sources/BreakpointCore/Updates/UpdateKey.swift"

die() { echo "error: $*" >&2; exit 1; }

[[ -n "$VERSION" && -n "$NOTES" ]] || die 'usage: scripts/release.sh X.Y.Z "One line of what'"'"'s new" [--dry-run]'
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$VERSION' is not X.Y.Z (pre-releases: tag them by hand, see docs/RELEASING.md)"
[[ "$NOTES" != *$'\n'* ]] || die "the notes are one line (the app shows them in a small card)"
[[ ${#NOTES} -le 120 ]] || die "the notes are ${#NOTES} characters; keep them to 120 (the app cuts the rest)"

CURRENT="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$VERSION_FILE")"
[[ -n "$CURRENT" ]] || die "could not read the version from $VERSION_FILE"
NO_KEY="$KEY_FILE still holds nil, so this release could never update itself: run scripts/release-keygen.sh and commit the public key it writes first (docs/RELEASING.md)"
if ! grep -q 'publicKeyBase64: String? = "' "$KEY_FILE"; then
  [[ $DRY_RUN == 1 ]] || die "$NO_KEY"
  echo "warning: $NO_KEY" >&2
fi
HIGHEST="$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
if [[ "$VERSION" == "$CURRENT" || "$HIGHEST" != "$VERSION" ]]; then
  die "$VERSION is not higher than the current $CURRENT (in $VERSION_FILE); give a higher version"
fi
[[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || die "switch to $BRANCH first"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "commit or stash your changes first"
git fetch --quiet --tags "$REMOTE" "$BRANCH"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$REMOTE/$BRANCH")" ]] || die "$BRANCH is not level with $REMOTE/$BRANCH; pull or push first"
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "v$VERSION already exists"

echo "Releasing Breakpoint $VERSION (now $CURRENT): $NOTES"
if [[ $DRY_RUN == 1 ]]; then
  echo "  would set $VERSION_FILE to $VERSION and commit \"Release $VERSION\""
  echo "  would tag v$VERSION and push $BRANCH and v$VERSION to $REMOTE"
  echo "Dry run: nothing changed."
  exit 0
fi

sed -i '' "s/static let current = \"$CURRENT\"/static let current = \"$VERSION\"/" "$VERSION_FILE"
grep -q "static let current = \"$VERSION\"" "$VERSION_FILE" || die "could not set the version in $VERSION_FILE"
git add "$VERSION_FILE"
git commit --quiet -m "Release $VERSION" -m "$NOTES"
git tag -a "v$VERSION" -m "$NOTES"
if ! git push --atomic "$REMOTE" "$BRANCH" "v$VERSION"; then
  echo "The push failed; nothing was published. To undo locally:" >&2
  echo "  git tag -d v$VERSION && git reset --hard $REMOTE/$BRANCH" >&2
  exit 1
fi

URL="$(git remote get-url "$REMOTE" | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')"
echo
echo "Pushed v$VERSION. GitHub is building it now (about 10 minutes):"
echo "  $URL/actions"
echo "  $URL/releases/tag/v$VERSION"
