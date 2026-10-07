---
id: TASK-67
title: Diagnose and fix Escape focus for persistent blackout
status: Done
assignee:
  - '@pi'
created_date: '2026-10-07 23:26'
updated_date: '2026-10-07 23:28'
labels: []
dependencies: []
ordinal: 55010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OLED blackout Action leaves displays hidden and Escape does not restore the display under the pointer. Installed build 3fb2a55 has the existing focus controller. Read-only status shows completed Action and hidden displays; 15 fake-backed focus tests pass. User approved narrow native focus tests, not monitor input or hardware writes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A native focus regression demonstrates the failure mechanism and verifies Escape restoration after the fix
- [x] #2 Pointer reentry and focus transitions retain Escape restoration without changing display hardware settings
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce actual AppKit key-window routing with an opt-in native test, including Settings already open. 2. Apply only a small demonstrated focus/restoration fix. 3. Run focused model and approved native checks; record remaining live-app uncertainty.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Native AppKit reproduction: initial Escape reached proxy, but making another same-app window key then polling left that window key and restoration count at 1 instead of 2. After reasserting proxy key focus during pointer polling, native test passed. Native show is a no-op when already key. User-approved interactive suite: 16 passed. Final noninteractive focused run: 18 passed, native test skipped as intended; includes Hide/Show/Escape and disabled persistent one-shot integration. Swift compilation and git diff --check pass; test LSP clean, source diagnostic report initially unknown. Initial native harness needed NSApplication event draining (existing DisplayHideAppTests pattern) rather than only XCTest run-loop waits. No real covers removed, hardware writes, installed-app replacement, commits, or pushes. Exact cause of the already-running installed app state remains unconfirmed; the demonstrated focus defect is fixed in source.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Recover the Escape proxy key window on pointer polling even when PanelCtl remains active. Added native responder-chain and fake-backed focus regression coverage; focused tests pass. Installed application unchanged.
<!-- SECTION:FINAL_SUMMARY:END -->
