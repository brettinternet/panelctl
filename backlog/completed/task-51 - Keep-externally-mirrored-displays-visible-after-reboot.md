---
id: TASK-51
title: Keep externally mirrored displays visible after reboot
status: Done
assignee:
  - '@agent'
created_date: '2026-10-06 23:01'
updated_date: '2026-10-06 23:13'
labels: []
dependencies: []
type: bug
ordinal: 41010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
AW3425DW returned mirrored after reboot despite a verified restored journal before reboot, and disappeared from PanelCtl until manually unmirrored in System Settings. Investigate retained evidence without display writes and repair the app visibility and guidance defect; preserve session-only writes and strict recovery ownership.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An online inactive external mirror follower remains visible with mirrored status and safe actionable guidance, without a PanelCtl recovery journal.
- [x] #2 Regression tests cover external mirror visibility, return to a separate desktop, and preserve owned recovery behavior.
- [x] #3 Record reboot investigation evidence and limits without changing permanent display configuration or performing hardware writes.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Inspect journal, startup paths and available macOS configuration evidence. 2. Reproduce inactive external mirror omission in fake-backed app tests. 3. Fix tile inclusion/status using existing mirrored safety policy and guidance. 4. Run focused and full offline tests, document evidence, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Reproduced missing tile with inactive online mirror follower and no unresolved recovery. Regression failed before fix (XCTUnwrap nil), passes after fix for absent and restored journals, with mirrored status, blocked Hide guidance, script status, and return to separate desktop. Existing owned recovery cases pass. Read-only WindowServer logs show mirroring at 16:53:28 and 16:53:33 before PanelCtl creation at 16:53:35.494; current plist was overwritten after manual correction, so original persistence cause remains unproven. Documented in docs/display-recovery.md. No hardware writes or permanent configuration changes.

Validation: core 286 tests (2 skipped) and app 267 tests (5 skipped), zero failures with three native interaction tests excluded. Those three plus new regression passed in isolated run. Initial full run had native focus/sheet failures; baseline full suite also exhibited a different timing failure, while baseline isolated native tests passed. Do not claim clean single-run full suite. App and CLI builds and git diff --check pass. LSP diagnostics unknown (bounded wait expired). User requested no further repeated interactive tests. Baseline archive retained at /tmp/panelctl-task51-baseline-20261006; no worktree created.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed externally mirrored inactive followers disappearing from display tiles and fallback script status. Existing System Settings guidance now takes precedence over misleading wake guidance; active-display automation eligibility and recovery ownership remain unchanged. Regression proves absent/restored journal paths and unmirror refresh. Offline model checks and builds pass; native interaction tests passed separately but were flaky in the full suite. Reboot evidence shows mirroring preceded app launch; its original persistence cause is not established.
<!-- SECTION:FINAL_SUMMARY:END -->
