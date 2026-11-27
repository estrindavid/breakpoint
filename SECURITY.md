# Security policy

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue, pull request or discussion.

1. Open the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe the problem, the version you tested, and the steps to reproduce it.

This uses GitHub's private vulnerability reporting: only you and the maintainer see the report,
and the fix can be prepared in a private advisory before anything is published. You will get a
reply there. Please give the maintainer reasonable time to release a fix before you disclose the
problem elsewhere.

## Supported versions

Only the **latest release** receives security fixes. Breakpoint updates itself (Settings → About),
so a fix reaches people through a new release, not through patches to older versions.

## In scope

Breakpoint runs on your Mac with your user's rights and edits other tools' configuration files,
so these parts matter most:

- **The update path.** The daily feed check, the download, and the checks before an update is
  installed: size, SHA-256, the Ed25519 signature with the project's release key, the refusal of
  older versions, the bundle checks and the swap of the old and new app (SPEC.md §2.11); the
  one-line installer `scripts/install.sh`; and the release workflow that builds and signs releases
  (`.github/workflows/release.yml`).
- **The installers that edit coding agents' config files.** Install and Remove for Claude Code,
  Cursor, Codex CLI, Copilot CLI and Gemini CLI, the shell snippets and the marked blocks in shell
  startup files, the backups, and the copy of the CLI in `~/.breakpoint/bin/`, which those hooks run.
- **The local socket.** The Unix domain socket the `breakpoint` tool writes events to (mode 0600 in
  a 0700 folder, peers with another user id are refused), and how the app parses what arrives on it.

Anything that makes Breakpoint send data about you, read something SPEC.md says it never reads
(screen contents, keystrokes, window titles), or trigger a permission prompt for a core feature is
also worth reporting.

## Known and documented

- Breakpoint is **not signed by Apple** (no Developer ID, not notarized); it is signed ad hoc, and
  updates are trusted through the project's own release key instead. This is described in the
  README and in [docs/RELEASING.md](docs/RELEASING.md).
- Code already running as your user can change your files, including the hooks and the CLI copy.
  Breakpoint does not try to defend against that.
