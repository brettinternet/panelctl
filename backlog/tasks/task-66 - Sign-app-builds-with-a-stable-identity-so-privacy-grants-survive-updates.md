---
id: TASK-66
title: Sign app builds with a stable identity so privacy grants survive updates
status: In Progress
assignee:
  - '@pi'
created_date: '2026-10-07 22:51'
updated_date: '2026-10-08 01:46'
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
- [x] #4 docs/development.md records identity creation, secret setup and rotation, and that rotation (or the first upgrade from an ad-hoc build) requires users to re-grant privacy permissions once.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Implement shared certificate-pinned signing, fail-closed release CI import, fake-tool checks and setup/rotation docs. 2. Provision the local identity and GitHub secrets under explicit owner authorization (completed). 3. Commit implementation on main, package and compare real signatures across two commits; verify helper and noninteractive installer. 4. Obtain scoped native login/install approval, record remaining CI/native evidence, finalize only satisfied criteria and release claim.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Human gate: an agent can change the packaging scripts and the CI workflow offline, but the owner must create the signing certificate and private key (Keychain) and add the CI secrets (exported .p12 plus password) with `gh secret set`. The agent should hand over exact commands, not generate or handle the private key itself. Resume condition: the secrets exist in the repository and the local identity appears in `security find-identity -v -p codesigning`.

Owner explicitly superseded the original key-generation gate in this session: authorized this agent to generate the signing identity, import it into the login Keychain with code-signing trust, and upload the three GitHub Actions secrets to brettinternet/PanelCtl. No private key/password may enter the checkout, logs or commits; no push or publication is authorized. Native install/login interaction remains separately gated.

Offline implementation complete. Eleven fake-tool tests pass, including real csreq compilation of the literal certificate-pinned requirement; actionlint 1.7.12, ShellCheck 0.11.0, bash syntax, release-version checks and diff checks pass. One independent verifier found no concrete defects; it correctly left real signatures/native behavior unverified. Parent fixed the requirement literal prefix and workflow runner-context placement, then reran checks. Python language server exited; no clean LSP result claimed. Under explicit owner authorization, generated a 3072-bit RSA self-signed code-signing identity valid 3650 days; imported into login Keychain with code-signing-only user trust. Public SHA-1 D5A5619A224539EE0DF351817AC95525587D5E5D. security find-identity now reports one valid identity; gh secret list confirms PANELCTL_SIGNING_IDENTITY, PANELCTL_SIGNING_P12_BASE64 and PANELCTL_SIGNING_P12_PASSWORD. Private artifacts existed only in an OS temporary directory removed on exit. No key/password in checkout/logs. Real signing and native acceptance next.
<!-- SECTION:NOTES:END -->
