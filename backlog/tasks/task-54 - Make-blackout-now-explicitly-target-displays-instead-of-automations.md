---
id: TASK-54
title: Retire broadcast blackout-now and let Hide force black-out style
status: To Do
assignee: []
created_date: '2026-10-07 00:50'
updated_date: '2026-10-07 01:01'
labels: []
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
- [ ] #1 panelctl app blackout-now (with or without arguments) exits 2 with migration guidance naming app hide --display, run-action and run-rule; it sends nothing to the app and never launches it.
- [ ] #2 The app control socket refuses a blackout-now request from older CLIs with the same guidance and no side effects: no blackout, no snooze cancellation, no Automation enablement, no preference edits.
- [ ] #3 The broadcast code path (AppModel.blackoutNow, coordinator pending blackout-now delivery and the menu item) is removed; no remaining caller can trigger every enabled rule at once. Per-rule menu invocation from TASK-56 is the only menu replacement.
- [ ] #4 app hide and toggle-hide accept --style black-out, which covers the display with the Black out style regardless of its configured Hide style; omitting --style keeps current behavior. Invalid values are usage errors. Show and Escape reverse it as for any black-out Hide.
- [ ] #5 Displays → Scripts copy commands and Action steps are unchanged unless they already expose a style; app restore still ends only automation blackouts.
- [ ] #6 CLI help, docs/usage.md, docs/display-hide-ux.md and the changelog/release notes describe the break and replacements. Focused fake-backed tests cover CLI refusal, socket refusal with unchanged automation state, and --style black-out on a display configured for Remove from desktop. Native UI validation requires separate user approval.
<!-- AC:END -->
