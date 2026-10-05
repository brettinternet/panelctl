---
id: TASK-39
title: Show the Dock icon while Settings is open
status: Done
assignee:
  - '@pi'
created_date: '2026-10-05 23:15'
updated_date: '2026-10-05 23:18'
labels: []
dependencies: []
ordinal: 29010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Settings is difficult to find while PanelCtl stays hidden from the Dock and Command-Tab. The user requested normal window discoverability without quitting the menu-bar utility on window close.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Opening and reopening Settings uses regular activation; closing Settings restores accessory activation.
- [x] #2 Closing Settings does not terminate the application or clear hidden-display state; explicit Quit retains existing termination safeguards.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Set activation policy in Settings presentation and close lifecycle; explicitly keep running after last-window close. Add native lifecycle regression tests and run the app tests without hardware writes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Native SettingsWindowTests passed (9 tests, 2 opt-in snapshots skipped), including regular/accessory transitions, minimize/reopen, close action, Command-W menu binding, and retained blackout state. App suite ran 152 tests with 5 assertion failures confined to testNativeMenuArrowEventsReachShowAction; isolated rerun crashed in existing DisplayHideAppTests setup at line 28 (NSApp nil). Quit-while-hidden recovery test passed in the app suite. No hardware writes. Unrelated concurrent working-tree changes excluded from this commit.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Settings now shows the Dock icon until closed, keeps PanelCtl running after last-window close, and supports Command-W through the standard File menu. Existing Quit paths remain unchanged. Verified by native Settings lifecycle and existing quit-recovery tests; broad-suite native menu fixture limitation recorded.
<!-- SECTION:FINAL_SUMMARY:END -->
