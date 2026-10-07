---
id: TASK-55
title: Run one saved automation immediately from the CLI
status: In Progress
assignee:
  - '@pi'
created_date: '2026-10-07 00:50'
updated_date: '2026-10-07 01:08'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/ProtectionCoordinator.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - Sources/PanelCtlCore/CLIParser.swift
  - Sources/PanelCtlCore/CLIHelp.swift
documentation:
  - docs/usage.md
ordinal: 44010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Users can invoke a saved Action by UUID but cannot explicitly invoke one automation. The legacy blackout-now broadcast is not a predictable substitute. Add one-shot rule execution that shares the saved rule lifecycle without changing whether its automatic trigger is enabled. This provides the explicit replacement for using blackout-now to trigger automation; running all rules is out of scope.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 panelctl app run-rule --rule <UUID> invokes exactly one saved automation in the running app; it never launches the app, falls back to another rule, broadcasts, queues or automatically retries. Missing, malformed and unknown rule IDs fail clearly (exit 2 for usage, 3 when the app is not running).
- [ ] #2 A run is one cycle: it bypasses the idle wait and applies the rule's display selection, blackout or dimming, duration, input/restoration behavior and configured follow-up (Restore or Sleep) once, then ends without re-arming. Normal safety checks, playback/camera deferral exemption matching manual commands, and conflict validation apply.
- [ ] #3 A disabled rule or globally disabled/snoozed Automation can be run once without changing rule enablement, the master switch, snooze expiry or saved preferences. Afterwards automatic scheduling is governed by those unchanged settings.
- [ ] #4 An already active selected rule is refused without restarting timers. Competing rules on the same displays, Hide/Show, Actions, Full disconnect and recovery cannot silently take display ownership or bypass safety gates; conflicts produce actionable refusals.
- [ ] #5 The command returns once the effect is installed or refused, not when it later restores. Text/JSON use the existing outcome vocabulary and exit codes (done, no-op, refused, busy, failed, response-lost); status reports the running one-shot rule by stable UUID. A lost response never implies cancellation or makes blind retry safe.
- [ ] #6 app restore, Escape/input, quit and shutdown clean up one-shot runs, including runs started while disabled or snoozed. Automatic trigger evaluation does not cancel the one-shot early or start a duplicate run of the same rule.
- [ ] #7 Help and docs/usage.md explain one-shot semantics, UUID discovery (status --json rules[].id), safety refusals and the difference from Actions and app hide. Focused fake-backed tests cover enabled, disabled and snoozed states, isolation to one rule, already-active refusal, cleanup and failed runs; no hardware writes or desktop UI are authorized by this task.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend the existing app command protocol/parser/client with UUID-targeted run-rule and no-launch/no-retry behavior.
2. Implement one-shot rule lifecycle using existing protection helpers, preserving automation settings and enforcing display ownership/recovery gates.
3. Add focused fake-backed lifecycle, protocol and conflict tests; update help and usage documentation.
4. Run focused checks and one independent review of lifecycle/ownership risks; fix concrete findings, record evidence and commit on main.
<!-- SECTION:PLAN:END -->
