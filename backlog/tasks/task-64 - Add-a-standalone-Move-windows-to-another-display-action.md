---
id: TASK-64
title: Add a standalone Move windows to another display action
status: To Do
assignee: []
created_date: '2026-10-07 22:44'
updated_date: '2026-10-07 22:52'
labels: []
dependencies:
  - TASK-63
  - TASK-66
references:
  - Sources/PanelCtlApp/DisplayActions.swift
  - Sources/PanelCtlApp/AutomationSettingsView.swift
  - Sources/PanelCtlCore/EmptyDisplayMonitor.swift
  - Sources/PanelCtlCore/AppControl.swift
type: feature
ordinal: 53010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A black cover leaves the monitor in the macOS desktop, so windows stay (and open) behind it. Users need an explicit way to move those windows without changing blackout state; it also works on a visible source, e.g. consolidating before unplugging. Remove from desktop already makes macOS relocate windows, so this mainly serves Black out. This is the first window effect and PanelCtl’s first Accessibility use; follow docs/window-relocation.md (TASK-63). Scope: ordinary movable windows on the current Space, not whole apps, Spaces, or layout restore. Existing occupancy detection is read-only and does not prove Accessibility can move a window.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Users can save and run a Move windows step alone or in one ordered Action with Hide/Show of the same source. Hide never moves windows and Move never changes hide state. Existing saved Actions migrate unchanged.
- [ ] #2 Destination is a specific display or Automatic: the main display when eligible, otherwise a documented stable order. Eligible excludes the source and blacked-out, removed, asleep, offline and mirrored-member displays. An unavailable explicit destination refuses with no fallback.
- [ ] #3 Identity, topology and recovery gates are revalidated at execution. No eligible destination gives an actionable refusal with no moves. Display IDs are never guessed and recovery is never bypassed.
- [ ] #4 Windows are attributed by the TASK-63 rule and moved preserving size and relative position within the destination visible frame, resizing only when larger than it. Tests cover negative origins, mixed scale, spanning, oversized and minimum-size windows. Apps are not activated and Spaces are not switched.
- [ ] #5 Accessibility is requested only from an explicit in-app user interaction; CLI, app-control and background runs report missing or stale permission without prompting. Fullscreen, minimized, other-Space, vanished and nonmovable windows are skipped with reason codes; PanelCtl and system surfaces are excluded. A hung app times out as failed without blocking other moves. Results report moved/skipped/failed counts, never blanket success, and no titles by default.
- [ ] #6 Action editor, run-action CLI and status expose the step and partial results consistently. A run installs no watcher and nothing is restored on Show. Re-running leaves windows already off the source untouched.
- [ ] #7 Fake-backed tests cover selection, geometry, migration, same-display composition, permission denial/revocation, hung apps, topology changes and partial failures; docs state limits and the permission requirement. Native window moving needs separate explicit user approval and narrow gated tests; no DDC or private display writes are authorized.
<!-- AC:END -->
