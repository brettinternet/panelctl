---
id: TASK-56
title: 'Add Run now, Copy CLI command and a menu Run submenu for automation rules'
status: To Do
assignee: []
created_date: '2026-10-07 00:50'
updated_date: '2026-10-07 01:02'
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
- [ ] #1 Each saved automation in Settings → Automations exposes Run now and Copy CLI command; the copied command is panelctl app run-rule --rule <UUID> using the rule's stable ID, unaffected by renaming or reordering, shell-quoted like Action commands.
- [ ] #2 The status menu replaces the Blackout Now item with a Run rule submenu listing every saved rule by name (disabled ones included and marked); choosing one dispatches the same one-shot request as run-rule. With no saved rules the item is disabled with a hint to create one.
- [ ] #3 Run now and the menu follow the CLI one-shot semantics, including disabled and snoozed rules, unchanged preferences, configured effects and restoration, and identical safety/conflict checks.
- [ ] #4 The UI shows selected-rule execution state and actionable busy/refusal/failure feedback; an active rule cannot be restarted by repeated clicks and no other rule is implicitly invoked.
- [ ] #5 User-facing text distinguishes running once from enabling an automatic trigger, and automation runs from Hide and Actions.
- [ ] #6 Focused model/view tests verify command copying, rule identity, menu contents and dispatch, and refusal presentation. Native interactive validation is narrowly scoped and requires explicit user approval before presenting desktop UI; record any blocked visual validation rather than claiming it passed.
<!-- AC:END -->
