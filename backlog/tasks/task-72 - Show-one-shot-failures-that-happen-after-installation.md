---
id: TASK-72
title: Show one-shot failures that happen after installation
status: Done
assignee: []
created_date: '2026-10-08 05:44'
updated_date: '2026-10-08 05:53'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/ProtectionCoordinator.swift
type: bug
ordinal: 60010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Review of TASK-56: if a one-shot helper reports its effect installed and then exits unsuccessfully, the per-rule feedback keeps the .done installation response and says the last run started, because ProtectionCoordinator discards the one-shot completion result and disabled rules' row status hides service state.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A one-shot that fails after installation shows the failure in the rule's run feedback, including for disabled rules.
- [x] #2 A late installation acknowledgment cannot overwrite a recorded post-install failure.
- [x] #3 A fake-helper regression covers install then unsuccessful exit.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Pass one-shot completion success/message through onOneShotFinished; record a failed response for the rule when unsuccessful. In runProtectionRule clear the rule's result before dispatch and keep any failure recorded while awaiting. Add a fake-helper mode that installs then exits non-zero.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered in c3df9a2. ProtectionCoordinator passes one-shot completion success/message to onOneShotFinished; AppModel records an unsuccessful completion as the rule's failed run result (any entry point, disabled rules included). runProtectionRule clears the rule's result before dispatch and keeps a failure recorded while it awaited installation, so the .done installation response cannot overwrite it. Failure summary uses the helper message verbatim, so installation failures still match the CLI response exactly (existing testSettingsRunPresentsSameRefusalAndFailureAsCLI). New fake-helper mode crash-after-install; testSettingsRunShowsFailureAfterInstallation fails on the previous source and passes now. AC2 ordering is guaranteed by code structure; the regression exercises the common ordering. Combined verification across TASK-69..72: ProtectionRuleRunOnceTests 21 passed; AutomationRules/Cleanup/Safety, SettingsWindow, AppStatusStream, AppControlServer, DisplayHideApp, BlackoutFocusController, ProtectionPreferences, DisplayActionApp, AppControl and CLIParser suites: 255 executed, 29 native UI skipped, 0 failures. git diff --check clean. No hardware writes or desktop UI.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Run feedback now shows one-shot failures that occur after installation, for CLI, menu and Settings runs, without masking installation failures. Red-to-green fake-helper regression; affected suites green.
<!-- SECTION:FINAL_SUMMARY:END -->
