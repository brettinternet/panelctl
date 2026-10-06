---
id: TASK-46
title: Coordinate multiple display steps in one named Action
status: To Do
assignee: []
created_date: '2026-10-06 18:29'
labels:
  - app
  - automation
  - cli
  - display-hide
dependencies:
  - TASK-36
  - TASK-32
references:
  - Sources/PanelCtlApp/DisplayActions.swift
  - Sources/PanelCtlApp/AutomationSettingsView.swift
  - Sources/PanelCtlApp/AppModel.swift
  - TASK-44
documentation:
  - docs/usage.md
  - docs/display-hide-ux.md
  - docs/development.md
  - docs/display-recovery.md
priority: medium
type: feature
ordinal: 36010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Named Actions currently save one display command, offering little beyond an existing CLI script. Users want one reusable command or Run button for a workflow such as Focus mode: remove the left and right displays while keeping a usable display on the Mac. The added value is coordinated validation, execution and clear results rather than just concatenating commands. Keep Action as the user-facing name and call its contents steps. This deliberately extends the one-display scope of TASK-36 without adopting a general scripting or unattended automation system. Existing hardware setup remains in Displays. Scope is offline implementation and fake-backed validation only; this task does not authorize live topology or DDC writes or qualify new hardware combinations.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Users can create, name, edit, reorder and remove steps within one saved Action in Automations. Each step selects an exact display and one existing effect: Hide (black out), Hide (remove from desktop), or Show. The list and editor disclose step order, targets, effects and reviewed removal setup; empty Actions cannot be saved.
- [ ] #2 Existing single-display Actions retain their IDs, commands, exact effects and reviewed setup when represented as one-step Actions. Rename or step edits preserve the Action ID; deletion invalidates its command without changing display state or discarding recovery evidence.
- [ ] #3 Run and panelctl app run-action --action UUID execute the same saved workflow once in order. The command still requires the running app; existing per-display commands remain compatible. No nested Actions, arbitrary scripts, conditions, delays, new effects, schedules or automatic triggers are introduced.
- [ ] #4 Before any display or input write, the whole Action is checked for target identity, reviewed-setup drift, eligibility, recovery, experimental consent, last-visible-display safety and combined step compatibility. Detectable conflicts, including removal of a needed mirror source or unsafe intermediate states, refuse the run with the offending step identified and no writes. No fallback effect or guessed identity is allowed.
- [ ] #5 Steps execute sequentially, verifying each outcome and rechecking current readiness before proceeding. Other app display-changing operations cannot interleave with a running Action. A run uses one consistent saved definition; editing or deleting an Action cannot change steps mid-run. Existing automation cleanup and per-display desired-state/no-op semantics remain intact.
- [ ] #6 A refused, failed, partial or recovery-needed step stops the remaining steps. UI and CLI results identify completed/no-op, stopped and unattempted steps, distinguish desktop and input outcomes, and report an aggregate outcome without claiming atomic success. No automatic rollback, retry, queue, resend or inverse Action is introduced; uncertain/lost responses direct users to inspect state before acting again.
- [ ] #7 Completed steps retain their actual display state and per-display Show/recovery paths after later failure, interruption, Action edits or deletion. Show uses recorded recovery even after setup changes or Experimental features are disabled. Startup, login, wake, reconnection and protection controls neither resume the workflow nor undo its manual Hides.
- [ ] #8 Fake-backed model, app-control and CLI tests cover migration, stable IDs, multi-display Hide/Show, mixed effects, ordering, no-ops, group conflicts, missing targets, setup drift, contention, mid-run state/definition changes, later-step failures, partial input outcomes, interruption and lost replies. Native UI fixtures demonstrate multi-step editing and partial results at supported widths. Relevant full offline tests and warnings-as-errors builds pass without live display/input writes.
- [ ] #9 CLI help and usage/UX documentation explain multi-step Actions, manual invocation, ordered but non-atomic execution, stop-on-problem behavior, recovery and state inspection after uncertain results. Documentation distinguishes offline coverage from hardware-qualified combinations and retains separate explicit approval for live writes.
<!-- AC:END -->
