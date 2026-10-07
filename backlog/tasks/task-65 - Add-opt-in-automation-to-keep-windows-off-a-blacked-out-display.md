---
id: TASK-65
title: Add opt-in automation to keep windows off a blacked-out display
status: To Do
assignee: []
created_date: '2026-10-07 22:45'
labels: []
dependencies:
  - TASK-63
  - TASK-64
references:
  - Sources/PanelCtlApp/ProtectionCoordinator.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlCore/Blackout.swift
  - Sources/PanelCtlCore/EmptyDisplayMonitor.swift
type: feature
ordinal: 54010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A one-time move is insufficient when applications later create windows or reopen them on a blacked-out monitor. Users need a separately configured automation that reuses the standalone Move windows effect while the selected display is actually blacked out. It must not be bundled into Hide, automatically enabled by blackout, or implemented as an unowned background side effect of a completed one-shot step. Follow the TASK-63 lifecycle contracts and reuse TASK-64 movement semantics. This scope covers PanelCtl-observed blackout, not guessing that an externally powered-off monitor is hidden.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Users can independently create, enable, disable and stop a Keep windows off display automation with a source and the same destination choices as Move windows. It is opt-in and migrates disabled/absent for existing users. Blackout works unchanged without it; the one-shot Move action remains independently usable.
- [ ] #2 When enabled and the selected source is actually blacked out, reconcile existing eligible windows and continue moving newly created or returning windows. Support both explicit Hide black-out and Automation blackout lifetimes through observed actual state, not requested state alone. Becoming armed is distinguishable from actively enforcing.
- [ ] #3 Enforcement ceases immediately when blackout ends, the rule is disabled, Automation is snoozed/disabled, or the app quits. Cancel stale pending work, release observers/timers and never move windows back automatically. Show/restore retains its existing scope. Resume and restart behavior is documented and reevaluates current eligibility rather than replaying stale moves or creating blackout.
- [ ] #4 No eligible destination, ambiguous identity, recovery, permission loss or topology change produces a visible paused/refused state with no unsafe move. A safe condition becoming valid may resume under the documented rule lifecycle; reconnection never guesses identities or overrides a specifically selected destination.
- [ ] #5 Overlapping rules and manual actions have deterministic ownership/conflict behavior with no duplicate watchers, cycles or window ping-pong. Repeated events, application refusal and actively dragged windows do not cause tight retry loops or excessive churn; responsiveness and reconciliation cadence have documented bounds verified with a fake clock/event source.
- [ ] #6 Keep-window automation never starts blackout, implicitly enables empty-display treatment or treats its own window moves as user activity. Tests demonstrate no self-sustaining hide/move feedback and no inappropriate rearming between empty-display blackout, input restoration and relocation.
- [ ] #7 UI and app status/status stream expose rule identity, armed/running/paused state, destination, stop control and actionable reasons/partial failures. Documentation explains that ongoing enforcement moves returning windows, its supported-window limits, and the difference from a one-shot action; background work never repeatedly prompts for permission.
- [ ] #8 Focused fake-backed tests cover blackout entry/exit, app launch/window creation/movement, missed-event reconciliation, sleep/wake, disconnect/reconnect, permission changes, overlapping rules, snooze, quit/restart and cancellation races. Native window movement requires separate explicit user approval with narrow gated checks; no hardware writes are authorized.
<!-- AC:END -->
