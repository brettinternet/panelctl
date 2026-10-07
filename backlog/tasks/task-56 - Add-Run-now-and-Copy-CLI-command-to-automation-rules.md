---
id: TASK-56
title: 'Add Run now, Copy CLI command and a menu Run submenu for automation rules'
status: Done
assignee: []
created_date: '2026-10-07 00:50'
updated_date: '2026-10-07 02:24'
labels: []
dependencies:
  - TASK-55
references:
  - Sources/PanelCtlApp/AutomationSettingsView.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/AppDelegate.swift
ordinal: 45010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Automation rules need the same discoverable manual invocation as saved Actions, so users never need internal UUIDs or guess what a broadcast does. The menu bar Blackout Now item currently broadcasts to every enabled rule; with the user decision of 2026-10-07 it is replaced by per-rule invocation (TASK-54 then removes the broadcast). Expose the TASK-55 one-shot contract in Settings and the menu without a separate UI-only execution path.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each saved automation in Settings → Automations exposes Run now and Copy CLI command; the copied command is panelctl app run-rule --rule <UUID> using the rule's stable ID, unaffected by renaming or reordering, shell-quoted like Action commands.
- [x] #2 The status menu replaces the Blackout Now item with a Run rule submenu listing every saved rule by name (disabled ones included and marked); choosing one dispatches the same one-shot request as run-rule. With no saved rules the item is disabled with a hint to create one.
- [x] #3 Run now and the menu follow the CLI one-shot semantics, including disabled and snoozed rules, unchanged preferences, configured effects and restoration, and identical safety/conflict checks.
- [x] #4 The UI shows selected-rule execution state and actionable busy/refusal/failure feedback; an active rule cannot be restarted by repeated clicks and no other rule is implicitly invoked.
- [x] #5 User-facing text distinguishes running once from enabling an automatic trigger, and automation runs from Hide and Actions.
- [x] #6 Focused model/view tests verify command copying, rule identity, menu contents and dispatch, and refusal presentation. Native interactive validation is narrowly scoped and requires explicit user approval before presenting desktop UI; record any blocked visual validation rather than claiming it passed.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reuse the run-rule model handler for Settings and menu invocation, with per-rule feedback and command copying. 2. Replace the broadcast menu item with saved-rule entries, including disabled and empty states. 3. Add focused fake-backed model/menu tests and update affected expectations and usage docs. 4. Run focused checks and one independent review; record native visual validation as blocked unless approved; commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered on main in c3d6be3 (Add per-rule run controls and menu). Settings Run now and menu entries call the existing run-rule handler; stable command generation uses the Action shell-quoting helper. Disabled rules are listed and marked, empty menus explain creation, and run/refusal feedback is per rule. docs/usage.md explains manual invocation versus automatic triggers, Hide, and Actions. CLI/socket broadcast removal remains TASK-54 scope.
Verification: swift test --disable-sandbox --filter "ProtectionRuleRunOnceTests|SettingsWindowTests.testRunRuleMenuIncludesDisabledRulesAndExplainsEmptyRules|SettingsWindowTests.testMenuUsesAutomationWording|AppControlTests.testRunRule|DisplayHideAppTests.testHiddenOverlayIsSourceOnlyRestoreOnlyAndQuiescedBeforeShow" passed 20 tests (16 one-shot, 2 menu, 1 overlay integration, 1 shell-safe command). New tests cover stable identity after rename/reorder, disabled/snoozed menu dispatch, unchanged preferences, selected-only launch, restart refusal, working-mode run text, retained-failure labeling and current-blocker precedence. git diff --check passed; LSP diagnostics clean for changed source files and new tests.
One independent review completed (ccd89ec1-3709-4132-ba19-34bc3f3232cb): corrected unconditional Escape guidance for dimming and stale refusal precedence; affected checks rerun green. No second general review.
Native visual validation BLOCKED by withheld desktop-UI approval: user explicitly chose Skip desktop UI. No native Settings window, interactive clipboard click, hardware writes or visual fixture run claimed. Model/menu behavior and command text were verified without presenting UI. Optional next validation: obtain scoped permission, then run SettingsWindowTests.testAutomationFixtureSnapshots with the interactive flag and inspect screenshots. No remaining implementation blocker; claim released.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added per-rule Run now and Copy CLI command in Automations, replacing the broadcast menu item with Run rule. Delivered c3d6be3 on main; 20 focused tests pass and both independent review findings fixed. Native visual validation intentionally skipped by user; limitation recorded.
<!-- SECTION:FINAL_SUMMARY:END -->
