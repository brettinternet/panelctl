---
id: TASK-66
title: Sign app builds with a stable identity so privacy grants survive updates
status: Done
assignee: []
created_date: '2026-10-07 22:51'
updated_date: '2026-10-08 01:56'
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
- [x] #1 Release and local app packaging sign the helper and app with one configured stable identity; `codesign -d -r-` shows a designated requirement without a cdhash that is identical for builds from two different commits.
- [x] #2 Release CI reads the identity from a repository secret and fails rather than silently falling back to ad-hoc; PR/local builds without the identity may sign ad-hoc with a visible warning. No private key material is committed.
- [x] #3 Launch at login, helper execution, install-release.swift and the README Gatekeeper guidance keep working with the new signature.
- [x] #4 docs/development.md records identity creation, secret setup and rotation, and that rotation (or the first upgrade from an ad-hoc build) requires users to re-grant privacy permissions once.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Completed shared certificate-pinned signing, fail-closed release CI import, fake-tool checks and setup/rotation docs. 2. Completed owner-authorized local identity and GitHub-secret provisioning. 3. Committed implementation and packaged two main commits; verified identical designated requirements despite changed app hashes on both architectures, helper execution and installer copying. 4. Completed approved native install/update and Launch at Login checks, restored prior settings, recorded evidence and released claim.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Human gate: an agent can change the packaging scripts and the CI workflow offline, but the owner must create the signing certificate and private key (Keychain) and add the CI secrets (exported .p12 plus password) with `gh secret set`. The agent should hand over exact commands, not generate or handle the private key itself. Resume condition: the secrets exist in the repository and the local identity appears in `security find-identity -v -p codesigning`.

Owner explicitly superseded the original key-generation gate in this session: authorized this agent to generate the signing identity, import it into the login Keychain with code-signing trust, and upload the three GitHub Actions secrets to brettinternet/PanelCtl. No private key/password may enter the checkout, logs or commits; no push or publication is authorized. Native install/login interaction remains separately gated.

Offline implementation complete. Eleven fake-tool tests pass, including real csreq compilation of the literal certificate-pinned requirement; actionlint 1.7.12, ShellCheck 0.11.0, bash syntax, release-version checks and diff checks pass. One independent verifier found no concrete defects; it correctly left real signatures/native behavior unverified. Parent fixed the requirement literal prefix and workflow runner-context placement, then reran checks. Python language server exited; no clean LSP result claimed. Under explicit owner authorization, generated a 3072-bit RSA self-signed code-signing identity valid 3650 days; imported into login Keychain with code-signing-only user trust. Public SHA-1 D5A5619A224539EE0DF351817AC95525587D5E5D. security find-identity now reports one valid identity; gh secret list confirms PANELCTL_SIGNING_IDENTITY, PANELCTL_SIGNING_P12_BASE64 and PANELCTL_SIGNING_P12_PASSWORD. Private artifacts existed only in an OS temporary directory removed on exit. No key/password in checkout/logs. Real signing and native acceptance next.

Implementation committed as bab006f on main. Real universal release packaging passed with required identity: PANELCTL_SIGNING_IDENTITY=D5A5619A224539EE0DF351817AC95525587D5E5D PANELCTL_REQUIRE_SIGNING=1 scripts/package-release.sh v0.6.2 .build/task66-bab006f. App/helper/standalone CLI requirements pin their fixed identifiers to the certificate and contain no cdhash; strict app verification and bundled helper help pass. Owner explicitly approved installing/updating /Applications/PanelCtl.app and native Launch at Login toggles, restoring the prior setting. Installed bab006f with scripts/install-release.swift, opened it and verified displayed version 0.6.2 (bab006f). Launch at Login was initially enabled; toggled off/on and verified both UI values and sfltool disabled/enabled dispositions. Automation was temporarily snoozed during these checks, with all displays separate/idle and no recovery pending; it will be resumed after validation. Production CI importer also passed a real isolated-keychain rehearsal with a disposable untrusted test certificate: import, scoped key access, actual signing and strict verification all passed without modifying user trust/search list. Temporary test keychain/keys removed. GitHub secrets are present; no remote release run/push was performed. Next: package the following evidence commit, compare designated requirements, validate the signed update and restore UI/automation state.

Final acceptance: packaged main commits bab006f and 463f7e4 with the same identity. .build/task66-verify-builds.py asserted each bundle version matches its commit; app CDHashes differ, while corresponding app/helper/CLI designated requirements are identical, certificate-pinned and cdhash-free for both arm64 and x86_64. Strict signatures pass for all artifacts; helper and standalone CLI help execute. Local evidence retained at .build/task66-signature-evidence.json and .build/task66-{bab006f,463f7e4}/. Installed both builds in sequence using scripts/install-release.swift; the installed signature verifies, UI shows 0.6.2 (463f7e4), and Launch at Login remained enabled across the update. On each signed build, off/on toggles matched sfltool disabled/enabled dispositions. Restored originally enabled login setting, closed Settings, and resumed original automation; final status is waiting for inactivity with all four displays separate/idle and no recovery. No display-action, DDC or private-setter tests. Final 11 signing checks, release-version tests, actionlint, ShellCheck and diff checks pass. One independent verification pass completed with no concrete findings; its former owner/native blockers were subsequently resolved by explicit authorization and the real checks above. No push, PR, release publication or remote CI run performed. No worktree created. No TASK-66 blocker remains; TASK-64 is now dependency-ready, but was not started. Future Accessibility grant-retention checks belong to TASK-64 when permission use exists.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Stable signing delivered in bab006f, with signed-build evidence recorded in 463f7e4 and this completion record. Configured the owner-approved login Keychain identity and three GitHub secrets without committing private material. Real two-commit universal builds retain identical certificate-pinned designated requirements; installer, helper and native Launch at Login/update checks pass. Eleven focused tests and shell/workflow checks pass; real isolated CI-keychain rehearsal passes. All four criteria satisfied; settings restored and claim released. No push or release publication.
<!-- SECTION:FINAL_SUMMARY:END -->
