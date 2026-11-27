# Maintaining Breakpoint

The maintainer's side of [CONTRIBUTING.md](../CONTRIBUTING.md): how to review and merge a pull
request, and the repository settings that make outside contributions safe. Releases are in
[RELEASING.md](RELEASING.md).

## Reviewing a pull request

1. **Read the diff before CI runs it.** Once the setting below is on, a pull request from someone
   outside the repository waits for you to approve its workflow run (the pull request shows an
   approval button). The run gets a read-only token and no secrets, but it still executes their
   code on a GitHub runner, so look first. Read changes to `.github/`, `scripts/` and
   `Package.swift` most carefully: after a merge, `scripts/` and the workflow run inside the release
   job, which holds the release signing key.
2. **Check it against the rules** in CONTRIBUTING.md, "What a reviewer checks", and for screens
   against SPEC.md §11. Behaviour changes need SPEC.md changes in the same pull request. UI changes
   need snapshot pictures.
3. **Wait for the check "Build and test"** (`.github/workflows/ci.yml`): a build with zero
   warnings, `scripts/test.sh` and `scripts/e2e.sh`, on the same `macos-26` runner the release
   uses.
4. **Fix the title if needed.** It should be one plain sentence a user understands: the release
   workflow publishes with `--generate-notes`, which lists the titles of the pull requests merged
   since the last release.
5. **Approve, then merge** with **Squash and merge**, so `main` gets one commit per pull request
   with the title as its subject.

Your own pull requests cannot be approved by you: GitHub does not let authors approve their own
pull requests. Because the protection below does not apply to administrators, you can still merge
them; from a terminal that is `gh pr merge NUMBER --squash --admin`.

## Settings to turn on once

Run these once the repository exists, from any folder, with the GitHub CLI signed in as the
repository's owner. Each command was checked against GitHub's REST documentation (API version
2022-11-28) in November 2026.

### 1. Protect `main`

Requires a pull request with one approving review from a code owner (`.github/CODEOWNERS` names
you for every file), requires the CI check to pass, dismisses an approval when new commits arrive,
and blocks force pushes and deletion of `main`.

```sh
gh api -X PUT repos/estrindavid/breakpoint/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": {
    "strict": false,
    "checks": [{ "context": "Build and test", "app_id": 15368 }]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

- `"enforce_admins": false` is the setting that lets **you** keep releasing. In the web settings
  it is the unticked box **Do not allow bypassing the above settings**. GitHub's documentation:
  by default, the restrictions of a branch protection rule do not apply to people with admin
  permissions. `scripts/release.sh` pushes the "Release X.Y.Z" commit and its tag straight to
  `main` (`git push --atomic origin main vX.Y.Z`); as an admin, that push goes through. If you ever set `enforce_admins` to `true`, releases
  have to go through a pull request instead (RELEASING.md, step 3).
- `"context": "Build and test"` is the `name:` of the job in `ci.yml`; `15368` is the id of the
  GitHub Actions app, so only Actions can satisfy the check. If you rename the job, change this.
- `"strict": false` does not make a pull request merge the latest `main` before merging. With
  `true`, every pull request has to be updated and re-tested whenever `main` moves; the push to
  `main` runs CI again either way.
- `restrictions` must be sent and is `null`: limiting who may push applies only to repositories
  owned by an organization.

Check it: `gh api repos/estrindavid/breakpoint/branches/main/protection`.

### 2. Approve workflow runs for every outside contributor

By default GitHub asks for approval only for some first-time contributors. This asks for every
contributor who is not a member or owner of the repository (in the web settings: Settings →
Actions → General → **Require approval for all external contributors**):

```sh
gh api -X PUT repos/estrindavid/breakpoint/actions/permissions/fork-pr-contributor-approval \
  -f approval_policy=all_external_contributors
```

Check it: `gh api repos/estrindavid/breakpoint/actions/permissions/fork-pr-contributor-approval`.

### 3. Read-only workflow token by default, and pinned actions

New repositories default to this; check it with
`gh api repos/estrindavid/breakpoint/actions/permissions/workflow`. Any workflow without its own
`permissions` block then gets a read-only token, and workflows cannot approve pull requests. To set
it explicitly:

```sh
gh api -X PUT repos/estrindavid/breakpoint/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
```

Every action in `.github/workflows/` is pinned to a full commit hash, so you can also make that a
rule (Settings → Actions → General → **Require actions to be pinned to a full-length commit
SHA**). `enabled` and `allowed_actions` are sent with the values a new repository has:

```sh
gh api -X PUT repos/estrindavid/breakpoint/actions/permissions \
  -F enabled=true -f allowed_actions=all -F sha_pinning_required=true
```

Check both: `gh api repos/estrindavid/breakpoint/actions/permissions/workflow` and
`gh api repos/estrindavid/breakpoint/actions/permissions`.

### 4. Private vulnerability reporting

SECURITY.md and CODE_OF_CONDUCT.md send people to Security → **Report a vulnerability**. That
button exists only once this is on (Settings → Security → **Private vulnerability reporting**):

```sh
gh api -X PUT repos/estrindavid/breakpoint/private-vulnerability-reporting
```

Check it: `gh api repos/estrindavid/breakpoint/private-vulnerability-reporting` says whether it is
enabled.

### 5. Discussions: on or off

Discussions are off by default. Issues are enough for a small project; the issue forms
already route bug reports and feature requests. Turn Discussions on when questions and ideas
start crowding the issues:

```sh
gh repo edit estrindavid/breakpoint --enable-discussions          # on
gh repo edit estrindavid/breakpoint --enable-discussions=false    # off
```

(The REST "Update a repository" endpoint does not document a field for this, so this uses the
GitHub CLI, whose `gh repo edit --help` lists the flag.)

### 6. Optional: squash merges only

Makes **Squash and merge** the only button, uses the pull request's title and description for the
commit, and deletes merged branches:

```sh
gh repo edit estrindavid/breakpoint --enable-squash-merge --enable-merge-commit=false \
  --enable-rebase-merge=false --squash-merge-commit-message pr-title-description --delete-branch-on-merge
```

## Not covered here

- A tag ruleset so only you can create `v*` tags: see RELEASING.md, "Who can ship an update".
- The licence is the PolyForm Shield License 1.0.0 (LICENSE.md, with the copyright line in NOTICE).
  NOTICE names the GitHub account as the licensor.
