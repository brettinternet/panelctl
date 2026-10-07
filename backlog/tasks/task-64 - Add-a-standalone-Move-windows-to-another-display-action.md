---
id: TASK-64
title: Add a standalone Move windows to another display action
status: To Do
assignee: []
created_date: '2026-10-07 22:44'
labels: []
dependencies:
  - TASK-63
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
A black cover does not remove a monitor from the macOS desktop, so app windows can remain behind it. Users need an explicit, independently invokable way to relocate those windows without changing blackout state. Deliver the first window effect using the TASK-63 contracts; it must also work on a visible source monitor. Scope is ordinary movable windows on the current desktop, not moving entire applications, changing Spaces, or restoring historical layouts. Existing occupancy detection is read-only and is not evidence that Accessibility can move every window.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Users can save and invoke a Move windows step independently, or compose it with Hide in an ordered saved Action targeting the same source display. Blackout alone never moves windows; Move never hides or shows a display. Existing saved actions migrate without changing behavior.
- [ ] #2 The step selects a source by stable display identity and either a specific destination or Any eligible visible display. Automatic choice deterministically prefers the main display when eligible; otherwise uses a documented stable fallback. The destination excludes the source, hidden/blacked-out/asleep/unavailable displays and unsupported mirrored topology. An unavailable explicit destination never silently falls back.
- [ ] #3 Revalidate identities, topology, actual destination usability and existing recovery/safety gates before movement. No eligible destination causes an actionable no-move outcome. Do not guess display identities or bypass recovery to relocate windows.
- [ ] #4 Move individual ordinary windows attributed to the source by a documented deterministic overlap rule, preserving size and relative placement where feasible and keeping them within the destination usable frame without unnecessary resizing. Cover negative coordinates, differing resolutions/scales, spanning windows and oversized/minimum-size windows. Do not activate apps or switch Spaces.
- [ ] #5 Accessibility permission is requested only through an explicit user interaction and absence/revocation produces actionable status without a prompt loop. Unsupported, fullscreen, minimized, other-Space, vanished and nonmovable windows are handled explicitly; no blanket success if moves fail. Exclude PanelCtl blackout/system surfaces and report moved, skipped and failed counts/reasons without exposing window titles by default.
- [ ] #6 Existing action UI, run-action CLI and status expose the effect, configuration and partial results consistently. A one-shot run installs no watcher, performs no automatic repeat and never restores windows on Show. Re-running does not perturb windows already off the source.
- [ ] #7 Focused fake-backed tests cover selection, geometry, migration, same-monitor step composition, permission denial/revocation, topology changes and partial failures; user documentation states limits and permission requirements. Native desktop/window-moving validation requires separate explicit user approval and narrow gated tests; no DDC or private display writes are authorized.
<!-- AC:END -->
