---
id: TASK-75
title: Fix keep-windows-off Settings CI interactions for v0.7.0
status: In Progress
assignee:
  - '@agent'
created_date: '2026-10-08 20:06'
updated_date: '2026-10-08 21:21'
labels: []
dependencies: []
type: bug
ordinal: 63010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Main CI reports seven failures in two keep-windows-off Settings tests. Release v0.7.0 is blocked until native control interactions reliably exercise the existing bindings on the dedicated runner; no local desktop interaction or hardware writes are authorized.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Both affected Settings tests pass in dedicated-runner CI without weakening their behavior assertions
- [ ] #2 Main and v0.7.0 release CI pass and signed universal assets are published
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Synchronize native Settings tests using distinct initial/target states and performClick; retain cross-display preference assertion. Verify pinned signing identity, scoped noninteractive CI trust and temporary search-list restoration using fake checks and real runner probe. After main/probe green retarget unpublished v0.7.0 with approved lease, publish and verify signed assets, then finalize task.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Main CI 37837084104 proves hidden-display pause/resume now passes with performClick and rendering waits. Remaining unhidden-display test clicks the prior display control before SwiftUI selection updates; select switches by their existing display-specific accessibility label rather than count.

CI 37837757000 showed native NSSwitch accessibility labels are nil. User approved exactly the two affected local UI tests, with fake displays and no real window movement or hardware writes. Direct inspection confirmed nil labels; selecting the target before presenting Settings removes the stale first-display control race. Both affected tests now pass locally (2 tests, 0 failures), retaining all behavior assertions; diagnostic prints removed.

Main CI 37838933066 still exposes initial-page rendering on macOS 15 even after preselecting before present. Changed approach: enable keep-off on the initial main display, leave target off, and wait for off before clicking, so stale controls are observably distinct. Added regression assertion that target clicks leave the initial display preference unchanged. Both scoped local UI tests pass again (2/2); no production behavior or existing assertions weakened.

Main CI 37839544849 passed. Tagged v0.7.0 at d64ed1c; release CI 37840035917 passed all tests and secret import, but signing failed with item not found in keychain; no release exists. User approved safe existing-secret CI diagnostics and moving the unpublished tag to the verified repair. Added early identity availability/validity checks and a manual dedicated-runner import/sign probe (no key export or disclosure).

Signing diagnosis confirmed configured identity exists but lacks runner trust. User-domain add-trusted-cert stalled on headless authorization; canceled run 37841843127 and changed to noninteractive sudo admin-domain codeSign-only trust on the disposable runner. Security commands now have 30-second bounds, manual signing step has a two-minute limit, and dispatch no longer duplicates main tests. Fourteen fake signing tests and actionlint pass.

Main CI 37845490025 green; probe 37845489718 confirms imported identity valid after scoped trust, but codesign still cannot locate it. macOS codesign man page requires signing keychain on user search list even with --keychain for certificate-chain resolution. Importer now snapshots and temporarily extends existing list; always cleanup restores exact original list before deleting keychain. Existing regression test now verifies preservation/restoration including paths with spaces. Fourteen signing tests and actionlint pass.
<!-- SECTION:NOTES:END -->
