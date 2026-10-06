---
id: TASK-39
title: Show the Dock icon while Settings is open
status: Done
assignee:
  - '@pi'
created_date: '2026-10-05 23:15'
updated_date: '2026-10-05 23:21'
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

Fix test-host Dock pollution: inject Settings presentation callbacks, wire real activation only at the executable entry point, and verify lifecycle requests without changing XCTest activation policy.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Native SettingsWindowTests passed (9 tests, 2 opt-in snapshots skipped), including regular/accessory transitions, minimize/reopen, close action, Command-W menu binding, and retained blackout state. App suite ran 152 tests with 5 assertion failures confined to testNativeMenuArrowEventsReachShowAction; isolated rerun crashed in existing DisplayHideAppTests setup at line 28 (NSApp nil). Quit-while-hidden recovery test passed in the app suite. No hardware writes. Unrelated concurrent working-tree changes excluded from this commit.

User screenshots show generic exec/xctest Dock entries and an unresponsive test host after validation. The new controller unconditionally changed process-wide activation policy; the prior lifecycle test demonstrated XCTest becoming regular. Reopened to isolate this effect from native fixtures.

Follow-up fix: Settings controllers report presentation through an injected callback. Only main.swift wires it to NSApplication activation policy and focus, so direct and AppDelegate-backed fixtures cannot promote XCTest. Replaced real-policy lifecycle testing with recorded presentation events and added default-fixture/delegate-forwarding regression tests asserting the host policy is unchanged. Fresh validation: swift test --disable-sandbox --filter PanelCtlAppTests passed all 154 tests (2 opt-in snapshot skips), including the previously failing native menu-arrow test; swift build --product PanelCtlApp passed; git diff --check passed. No xctest or PanelCtl process remained afterward. No hardware writes. Follow-up changes left uncommitted.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Settings retains Dock visibility while open and returns to menu-bar-only mode on close. Process-wide Dock/focus effects are now wired only in the real executable, not native test fixtures. Native app suite passes: 154 tests, 2 opt-in skips; app build passes. The earlier native-menu failure no longer reproduces in the full app suite.
<!-- SECTION:FINAL_SUMMARY:END -->
