---
id: TASK-75
title: Fix keep-windows-off Settings CI interactions for v0.7.0
status: In Progress
assignee:
  - '@agent'
created_date: '2026-10-08 20:06'
updated_date: '2026-10-08 20:39'
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
Use NSSwitch.performClick and current-control rendering waits; select the target display before presenting Settings. Validate the two tests locally with scoped approval and fake-backed suites, then push main, tag v0.7.0 after main CI succeeds, and verify release CI/assets.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Main CI 37837084104 proves hidden-display pause/resume now passes with performClick and rendering waits. Remaining unhidden-display test clicks the prior display control before SwiftUI selection updates; select switches by their existing display-specific accessibility label rather than count.

CI 37837757000 showed native NSSwitch accessibility labels are nil. User approved exactly the two affected local UI tests, with fake displays and no real window movement or hardware writes. Direct inspection confirmed nil labels; selecting the target before presenting Settings removes the stale first-display control race. Both affected tests now pass locally (2 tests, 0 failures), retaining all behavior assertions; diagnostic prints removed.

Main CI 37838933066 still exposes initial-page rendering on macOS 15 even after preselecting before present. Changed approach: enable keep-off on the initial main display, leave target off, and wait for off before clicking, so stale controls are observably distinct. Added regression assertion that target clicks leave the initial display preference unchanged. Both scoped local UI tests pass again (2/2); no production behavior or existing assertions weakened.

Main CI 37839544849 passed. Tagged v0.7.0 at d64ed1c; release CI 37840035917 passed all tests and secret import, but signing failed with item not found in keychain; no release exists. User approved safe existing-secret CI diagnostics and moving the unpublished tag to the verified repair. Added early identity availability/validity checks and a manual dedicated-runner import/sign probe (no key export or disclosure).
<!-- SECTION:NOTES:END -->
