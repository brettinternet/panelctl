---
id: TASK-54
title: Retire broadcast blackout-now and let Hide force black-out style
status: Done
assignee: []
created_date: '2026-10-07 00:50'
updated_date: '2026-10-08 05:53'
labels:
  - reviewed
dependencies:
  - TASK-55
  - TASK-56
references:
  - Sources/PanelCtlCore/CLIParser.swift
  - Sources/PanelCtlCore/CLIHelp.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/AppDelegate.swift
documentation:
  - docs/usage.md
ordinal: 43010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The legacy `app blackout-now` (CLI, control socket and menu item) broadcasts to every enabled automation, and also clears snooze and silently turns Automation back on, so its targets and side effects change as rules are added. Explicit replacements already exist or are planned: `app hide --display` (one display, until Show), saved Actions (1–8 ordered display steps) and `app run-rule` (TASK-55, one saved automation). A separate manual-blackout feature would duplicate those, so the broadcast is removed rather than re-targeted. This is an intentional compatibility break; do not keep a hidden broadcast path. Decided with the user 2026-10-07. Scripts that need a cover regardless of a display's configured Hide style need a way to request black-out explicitly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 panelctl app blackout-now (with or without arguments) exits 2 with migration guidance naming app hide --display, run-action and run-rule; it sends nothing to the app and never launches it.
- [x] #2 The app control socket refuses a blackout-now request from older CLIs with the same guidance and no side effects: no blackout, no snooze cancellation, no Automation enablement, no preference edits.
- [x] #3 The broadcast code path (AppModel.blackoutNow, coordinator pending blackout-now delivery and the menu item) is removed; no remaining caller can trigger every enabled rule at once. Per-rule menu invocation from TASK-56 is the only menu replacement.
- [x] #4 app hide and toggle-hide accept --style black-out, which covers the display with the Black out style regardless of its configured Hide style; omitting --style keeps current behavior. Invalid values are usage errors. Show and Escape reverse it as for any black-out Hide.
- [x] #5 Displays → Scripts copy commands and Action steps are unchanged unless they already expose a style; app restore still ends only automation blackouts.
- [x] #6 CLI help, docs/usage.md, docs/display-hide-ux.md and the changelog/release notes describe the break and replacements. Focused fake-backed tests cover CLI refusal, socket refusal with unchanged automation state, and --style black-out on a display configured for Remove from desktop. Native UI validation requires separate user approval.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Refuse the retired CLI/socket command with shared migration guidance and remove broadcast coordinator/model/menu behavior. 2. Thread an optional black-out style through Hide and toggle-hide without changing saved preferences, Actions or Scripts. 3. Update focused fake-backed regression tests and user documentation. 4. Run focused checks and one independent review; commit on main and record delivery evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered on main in commit 42c66a0. Removed model/coordinator broadcast and obsolete menu helpers; legacy CLI/socket requests refuse with shared migration guidance. Added request-scoped black-out Hide/Toggle style, preserving Scripts, Actions, saved preferences and automation-only Restore. One independent review found two concrete defects, both corrected: styled requests now use protocol 2 so older apps refuse instead of silently removing a display, and forced black-out uses black-out readiness rather than incomplete removal setup. Protocol 1 ordinary requests/responses remain compatible. Final parent checks: AppControlTests 15 passed; CLIParserTests 24 passed; AppControlServerTests 7 passed; DisplayHideAppTests 73 executed, 10 native tests skipped, zero failures. New regressions cover legacy protocol refusal, missing mirror source, no removal calls, unchanged preferences, Show/Escape and side-effect-free socket refusal. Executor also passed ProtectionPreferencesTests (40), AutomationRulesTests (15), BlackoutFocusControllerTests (15), targeted hidden-display Restore and safety tests; CLI smoke returned exit 2. git diff --check passed; core LSP diagnostics clean, initial AppModel LSP result unknown (compiler/tests passed). Native UI and hardware writes were not performed or authorized. No remaining blocker or implementation step; optional native validation requires separate scoped approval. No worktrees created; provider claim released by Done and clearing assignee.

Post-delivery review 2026-10-08: no runtime or safety defects. AC6 doc gap (docs/display-hide-ux.md lacked the blackout-now retirement and replacements) fixed in 95d961d.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Retired app blackout-now and added safe --style black-out for Hide/Toggle Hide. Delivered in 42c66a0 with migration docs/release notes. Focused parser, socket, model and automation tests pass; two review defects fixed and relevant checks rerun. Native UI tests intentionally skipped.
<!-- SECTION:FINAL_SUMMARY:END -->
