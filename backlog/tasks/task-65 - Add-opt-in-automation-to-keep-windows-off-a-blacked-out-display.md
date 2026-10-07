---
id: TASK-65
title: Keep windows off a display while it is blacked out
status: To Do
assignee: []
created_date: '2026-10-07 22:45'
updated_date: '2026-10-07 22:52'
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
  - Sources/PanelCtlApp/DisplayHidePreferences.swift
  - Sources/PanelCtlApp/DisplaySettingsView.swift
  - docs/display-hide-ux.md
type: feature
ordinal: 54010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A one-time move is not enough: apps create or reopen windows on a blacked-out monitor, where the user cannot see them. Users want an opt-in, per-display option that keeps such windows off while that display is actually blacked out. It is configured alongside the display’s Hide settings (not an Automation rule, per TASK-63), is never enabled by Hide itself, and reuses the TASK-64 mover and destination rules. Remove from desktop does not need it because macOS relocates windows. Only PanelCtl-observed blackout counts; an externally powered-off monitor is not assumed hidden.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Displays settings offer an opt-in “Keep windows off while blacked out” option per display with Automatic or a specific destination (TASK-64 eligibility). It defaults off and existing saved configurations decode as off; with it off, Hide, Actions and Automation are unchanged.
- [ ] #2 While the option is on and the display is observed blacked out by any owner (manual Hide, Action or Automation rule), existing eligible windows are moved, then new or returning windows are moved within a documented bound. Armed (option on, display visible) is distinguishable from enforcing.
- [ ] #3 Enforcement stops immediately when blackout ends, the option is turned off or the app quits: pending work is cancelled, observers and timers released, and windows are never moved back. On relaunch it reevaluates current state only; it never replays moves or starts blackout.
- [ ] #4 No eligible destination, ambiguous identity, recovery, permission loss or topology change gives a visible paused state with a reason and no moves. It resumes without prompting once the condition clears; reconnection never guesses identities or substitutes for a specific destination.
- [ ] #5 One controller per display, so no duplicate watchers. Windows that refuse moves, keep returning or are being dragged get bounded per-window backoff with no tight loops; cadence and backoff bounds are verified with a fake clock. A manual Move step during enforcement is idempotent.
- [ ] #6 Enforcement never starts or extends blackout, and its moves do not count as user activity. Tests show no hide/move feedback loop or improper rearming with empty-display blackout and input restoration.
- [ ] #7 Displays settings, the menu and the status stream show armed/enforcing/paused state with reason and last moved/failed counts. Docs explain ongoing enforcement, supported-window limits and how it differs from the one-shot Move step; background work never prompts for permission.
- [ ] #8 Fake-backed tests cover blackout entry/exit by each owner, window creation and return, missed-event reconciliation, sleep/wake, disconnect/reconnect, permission changes, quit/relaunch and cancellation races. Native window movement needs separate explicit user approval and narrow gated tests; no hardware writes are authorized.
<!-- AC:END -->
