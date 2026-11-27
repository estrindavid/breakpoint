# Releasing Breakpoint

How a new version gets from `main` to everyone's Mac, with no Apple account. The app's behaviour
is in [SPEC.md §2.11](SPEC.md).

## Once, before the first release

1. **Create the release key:** `scripts/release-keygen.sh`. It needs the GitHub CLI signed in
   (`gh auth login`) and takes a few seconds:
   - makes an Ed25519 key pair with CryptoKit (part of macOS);
   - sends the private half straight to the repository secret `UPDATE_SIGNING_KEY` with
     `gh secret set`. It is never printed and never written to disk, and you never see it;
   - writes the public half into `Sources/BreakpointCore/Updates/UpdateKey.swift`.
2. **Commit the public key:** `git add Sources/BreakpointCore/Updates/UpdateKey.swift && git commit -m "Release key" && git push`.
3. If `main` requires pull requests, let your account push to it, or merge version changes through
   a pull request and push only the tag (below).

Steps 1 and 2 are required: without the secret and the committed public key there is no release.
`scripts/release.sh` refuses to tag while `UpdateKey.swift` still holds `nil`, and the release
workflow fails at once if either half is missing, with a message to run `scripts/release-keygen.sh`
and commit the key first (a dry run signs with a throwaway key and needs neither). A release
without the key would be unsigned, and copies of it could never update themselves.

## Ship a release (every time)

```sh
git switch main && git pull
scripts/release.sh 0.3.0 "Breaks now wait for Codex too."      # add --dry-run to only check
```

The script checks that the release key's public half is committed, that you are on `main`, with
nothing uncommitted, level with GitHub, that no tag `v0.3.0` exists, and that 0.3.0 is strictly
higher than the version in `Sources/BreakpointCore/Models/Version.swift` (the one place the version
lives); sets `BreakpointVersion.current` there; commits "Release 0.3.0"; tags `v0.3.0` with your
line; and pushes both.

The tag starts [.github/workflows/release.yml](../.github/workflows/release.yml) (about 10 to 15
minutes; watch the **Actions** tab). It runs the tests, builds `Breakpoint.app` (one universal app
for Apple silicon and Intel: `BREAKPOINT_ARCHS="arm64 x86_64" scripts/build-app.sh`), zips it, signs the
zip with `UPDATE_SIGNING_KEY` (and checks the signature against the public key in that version's
`UpdateKey.swift`, so a release can never be signed with a key its app ignores), and publishes the
release "Breakpoint 0.3.0" with four files: `Breakpoint-0.3.0.zip`, `update-feed.json`,
`install.sh` and `SHA256SUMS`.

Within a day every copy with automatic checks on (the default) shows, at a quiet moment:

> **Breakpoint 0.3.0 is ready** · Breaks now wait for Codex too. · [Later] [Update]

Update downloads the zip, checks it, replaces the app and reopens it: "Breakpoint is now 0.3.0".
People who turned on **Install updates automatically** get it without the question.

The line is shown in a small card: one sentence, at most 120 characters, plain verbs, no "!".

## How people install

```sh
curl -fsSL https://github.com/estrindavid/breakpoint/releases/latest/download/install.sh | bash
```

It downloads the latest zip, checks its size and SHA-256 against the release's feed and that the
app has code for this Mac's processor, and puts
Breakpoint in /Applications (or ~/Applications when /Applications is not writable). It opens
nothing and asks for no password. Files downloaded with `curl` carry no quarantine flag, so macOS
opens the app without the "unidentified developer" dialog.

The installer does not check the Ed25519 signature: macOS has no tool for it without a compiler
(its `openssl` is LibreSSL 3.3, without Ed25519), and a key inside `install.sh` would come from the
same release as the zip anyway. Its SHA-256 check catches a broken or cut-short download, not a
tampered release; whoever can publish a release here can change `install.sh` too. The script is one
`{ … }` block, so a download cut short runs nothing.

Someone who downloads the zip in a browser gets the quarantine flag: macOS refuses the first open,
and they go to System Settings → Privacy & Security → **Open Anyway** once. After that, in-place
updates arrive without the flag.

## What an unsigned app costs

Breakpoint is ad-hoc signed, not signed by Apple. Developer ID signing and notarization could be
added later without changing anything here; until then:

| | Effect |
|---|---|
| Browser download | blocked on first open; System Settings → Privacy & Security → Open Anyway, once |
| `curl` install and in-place updates | no dialog: our downloads are not quarantined (the app does not set `LSFileQuarantineEnabled`, and curl never quarantines) |
| Open at login | each new ad hoc build may be a new app to macOS; the new copy registers the login item again, which can show macOS's "Login item added" notice once per update |
| AirPods Motion access (optional) | tied to the exact build for ad-hoc apps, so macOS may ask again after an update |
| App Translocation | a copy opened where a browser downloaded it runs from a temporary read-only place; it cannot update itself and says so (move it to Applications) |
| Homebrew | not offered: Homebrew quarantines cask downloads and has deprecated `--no-quarantine` and unsigned casks, so an ad-hoc app would be blocked |

## Who can ship an update

Two things are needed together: the release key (only in the `UPDATE_SIGNING_KEY` secret) and
the ability to publish a release in this repository (the app reads the feed only from
`github.com/estrindavid/breakpoint`). Keep two-factor authentication on, and consider a tag
ruleset (Settings → Rules → Rulesets → target tags `v*`, restrict creation to you).

A repository secret is available to any workflow run started by someone who can push: a changed
workflow on any branch could use the key. While you are the only one with write access that is
the same person; before adding collaborators, move the key to an environment (Settings →
Environments → `release`, deployment limited to tags `v*`, required reviewer: you) and name that
environment in the release job.

An update is installed only if: the archive's size and SHA-256 match the feed; its Ed25519
signature over the version, size and SHA-256 verifies with the public key compiled into the
running copy; the version is newer than the running one (no downgrades or replays); and the
unpacked app has our bundle identifier and that version. Nothing from the download runs before
those checks. If the new copy does not start within 30 seconds, the old one is put back.

## If the key is lost or leaks

- **Lost** (the secret was deleted): run `scripts/release-keygen.sh --replace`, commit the new
  public key, ship a release. Copies with the old key cannot verify it, so they show "Couldn't
  install" with **Open download page**: those people install that one release by hand (the
  `curl` line). After that, updates are automatic again.
- **Leaked**: do the same at once. Someone holding the old key still needs to publish a release in
  this repository to reach anyone, so also check the repository's access and tokens. Copies that
  installed the new release no longer trust the old key.

## Other situations

- **A pre-release** (testers only): set `Version.swift` to `0.3.0-beta.1`, commit, then
  `git tag -a v0.3.0-beta.1 -m "…" && git push origin v0.3.0-beta.1`. It is marked pre-release,
  and `releases/latest` skips pre-releases, so no one is prompted.
- **A bad release**: edit it on GitHub and tick "Set as a pre-release" (the feed falls back to the
  previous release at once), then ship a fixed higher version.
- **Build a tag again** (a failed run, a new secret): Actions → Release → Run workflow, with the tag.
- **Costs**: none. GitHub Actions minutes are free for a public repository; no Apple account.
