---
id: TASK-35
title: Manage named protection rules in the Automations tab
status: To Do
assignee: []
created_date: '2026-10-05 22:29'
labels:
  - app
  - automation
  - ui
dependencies:
  - TASK-34
references:
  - Sources/PanelCtlApp/AutomationSettingsView.swift
  - Sources/PanelCtlApp/SettingsWindowController.swift
  - Sources/PanelCtlApp/AppDelegate.swift
documentation:
  - docs/display-hide-ux.md
  - docs/usage.md
priority: medium
type: feature
ordinal: 25010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The current Automation form represents one global configuration. Users need to see which protection is configured for each display and why a rule is active or blocked without learning a workflow-builder UI. Build the user-facing multiple-rule experience on the coordinated runtime from TASK-34. Keep display hardware setup and recovery in Displays, and keep General preferences separate. Scheduled triggers, arbitrary action chains and unattended topology/input/power/private-disconnect actions are out of scope. Native UI fixture inspection and offline validation are required; no live hardware writes are authorized.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Settings labels the tab Automations and presents a list of named rules with enablement, trigger/action/target/end-behavior summary and truthful live status such as watching, active, paused or blocked with reason. The migrated existing rule appears without silently enabling or changing anything.
- [ ] #2 Users can add, edit, rename and delete rules. The editor groups When, Displays, Action, End behavior and Exceptions, exposing supported idle and empty-display behavior, blackout/dimming, existing advanced brightness options and explicitly global sleep follow-up. Unsupported combinations and conflicts are explained before enablement.
- [ ] #3 Each action names its actual effect rather than Hide using current style. Missing saved targets remain visible with reasons; stable target identities survive renaming. Displays retains hardware setup and recovery, with direct navigation from blocked rules and no duplicate recovery workflow.
- [ ] #4 Pause All, resume, per-rule enablement and Restore have clear scope in Settings and the menu. Pausing or removing a running rule verifies its automation-owned cleanup without showing manual Hides or switching inputs; cleanup failure remains visible and retryable even with all rules disabled or deleted.
- [ ] #5 Native keyboard and accessibility navigation covers the rule list, editor, validation and recovery. Rendered fixtures are inspected for migrated single-rule, multiple-rule, active, missing-target, conflicting-rule and cleanup-failure states; tests cover editing and persistence with fake services.
- [ ] #6 Full offline tests and warnings-as-errors builds pass. Update the existing UX contract, usage documentation and relevant screenshots to distinguish shipped protection rules from deferred manual actions and unavailable unattended hardware actions.
<!-- AC:END -->
