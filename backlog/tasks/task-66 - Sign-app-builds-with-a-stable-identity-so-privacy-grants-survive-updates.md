---
id: TASK-66
title: Sign app builds with a stable identity so privacy grants survive updates
status: To Do
assignee: []
created_date: '2026-10-07 22:51'
updated_date: '2026-10-07 23:23'
labels: []
dependencies: []
references:
  - scripts/package-app.sh
  - scripts/package-release.sh
  - .github/workflows/ci.yml
  - install-release.swift
type: task
ordinal: 52510
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-64 introduces PanelCtl’s first TCC permission (Accessibility). scripts/package-app.sh and scripts/package-release.sh sign ad-hoc, so the designated requirement is the build’s cdhash: every update silently invalidates the grant while System Settings still shows PanelCtl enabled, and AXIsProcessTrusted() returns false. Background window enforcement (TASK-65) would stop after each update with no obvious cause. Developer ID/notarization was not chosen; use a stable self-signed code-signing identity.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Release and local app packaging sign the helper and app with one configured stable identity; `codesign -d -r-` shows a designated requirement without a cdhash that is identical for builds from two different commits.
- [ ] #2 Release CI reads the identity from a repository secret and fails rather than silently falling back to ad-hoc; PR/local builds without the identity may sign ad-hoc with a visible warning. No private key material is committed.
- [ ] #3 Launch at login, helper execution, install-release.swift and the README Gatekeeper guidance keep working with the new signature.
- [ ] #4 docs/development.md records identity creation, secret setup and rotation, and that rotation (or the first upgrade from an ad-hoc build) requires users to re-grant privacy permissions once.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Human gate: an agent can change the packaging scripts and the CI workflow offline, but the owner must create the signing certificate and private key (Keychain) and add the CI secrets (exported .p12 plus password) with `gh secret set`. The agent should hand over exact commands, not generate or handle the private key itself. Resume condition: the secrets exist in the repository and the local identity appears in `security find-identity -v -p codesigning`.
<!-- SECTION:NOTES:END -->
