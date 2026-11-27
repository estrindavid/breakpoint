#!/bin/bash
# Creates the release key, once (docs/RELEASING.md, SPEC §2.11):
#
#   scripts/release-keygen.sh            # needs `gh` signed in to the repository
#   scripts/release-keygen.sh --replace  # a new key (the old one was lost or leaked; read RELEASING.md first)
#
# 1. Makes a new Ed25519 key pair with CryptoKit (scripts/update-signing.swift).
# 2. Sends the private key straight to the repository secret UPDATE_SIGNING_KEY with `gh secret set`.
#    It is never printed, never written to disk, and never leaves this pipe except to GitHub.
# 3. Writes the public key into Sources/BreakpointCore/Updates/UpdateKey.swift, the one place
#    it lives. Commit that file: every build from then on installs only updates signed with the key.
set -euo pipefail

cd "$(dirname "$0")/.."
KEY_FILE="Sources/BreakpointCore/Updates/UpdateKey.swift"
REPLACE=0
[[ "${1:-}" == "--replace" ]] && REPLACE=1

die() { echo "error: $*" >&2; exit 1; }

command -v gh >/dev/null || die "install the GitHub CLI (brew install gh) and run 'gh auth login' first"
gh auth status >/dev/null 2>&1 || die "run 'gh auth login' first"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || die "run this inside the repository"
if grep -q 'publicKeyBase64: String? = "' "$KEY_FILE" && [[ $REPLACE == 0 ]]; then
  die "$KEY_FILE already holds a key. To replace it (lost or leaked), read docs/RELEASING.md, then run with --replace"
fi

echo "This creates the key that signs every Breakpoint update for $REPO."
echo "The private half goes only to the repository secret UPDATE_SIGNING_KEY; you never see it."
[[ $REPLACE == 1 ]] && echo "Replacing: copies with the old key will need one update installed by hand."
read -r -p "Continue? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "Nothing changed."; exit 0; }

PUBLIC_OUT="$(mktemp -t breakpoint-public-key)"
trap 'rm -f "$PUBLIC_OUT"' EXIT
swift scripts/update-signing.swift keygen "$PUBLIC_OUT" | gh secret set UPDATE_SIGNING_KEY --repo "$REPO"
PUBLIC_KEY="$(tr -d '[:space:]' < "$PUBLIC_OUT")"
[[ ${#PUBLIC_KEY} -eq 44 ]] || die "the public key looks wrong; the secret may have been set, run again with --replace"

sed -i '' -E "s#publicKeyBase64: String\\? = (nil|\"[^\"]*\")#publicKeyBase64: String? = \"$PUBLIC_KEY\"#" "$KEY_FILE"
grep -q "\"$PUBLIC_KEY\"" "$KEY_FILE" || die "could not write the public key into $KEY_FILE"

echo
echo "Done."
echo "  Private key: saved as the secret UPDATE_SIGNING_KEY in $REPO (Settings → Secrets and variables → Actions)."
echo "  Public key:  $PUBLIC_KEY, written into $KEY_FILE."
echo
echo "Now commit the public key:"
echo "  git add $KEY_FILE && git commit -m 'Release key' && git push"
