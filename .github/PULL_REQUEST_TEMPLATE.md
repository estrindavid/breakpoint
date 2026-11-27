<!--
Title: one plain sentence a user would understand, e.g. "Breaks now wait for Gemini CLI too."
Release notes are generated from pull request titles. See CONTRIBUTING.md.
-->

## What and why

<!-- What changes for someone using Breakpoint, and why. Link the issue if there is one ("Closes #123"). -->

## How I tested it

<!-- Commands you ran and what you checked by hand. For UI changes, attach before and after
pictures from scripts/snapshots.sh. -->

## Checklist

- [ ] `swift build` finishes with zero warnings
- [ ] `scripts/test.sh` passes
- [ ] `scripts/e2e.sh` passes
- [ ] `docs/SPEC.md` is updated if behaviour, a screen or a sentence changed (or nothing changed)
- [ ] For UI changes: snapshots are added or updated, and pictures are attached above
- [ ] No new dependency, no SwiftPM resource, and no API that triggers a permission prompt
- [ ] Words people read follow SPEC.md §3.11 (no "should", no "!", no medical claims, no scores)
- [ ] Tests use a temporary home and never touch the real one
- [ ] I agree to the terms in CONTRIBUTING.md, "Licensing of contributions"
