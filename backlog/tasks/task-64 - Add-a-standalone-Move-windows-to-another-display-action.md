---
id: TASK-64
title: Add a standalone Move windows to another display action
status: In Progress
assignee:
  - '@pi'
created_date: '2026-10-07 22:44'
updated_date: '2026-10-08 03:52'
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
- [x] #1 Users can save and run a Move windows step alone or in one ordered Action with Hide/Show of the same source. Hide never moves windows and Move never changes hide state. Existing saved Actions migrate unchanged.
- [x] #2 Destination is a specific display or Automatic: the main display when eligible, otherwise a documented stable order. Eligible excludes the source and blacked-out, removed, asleep, offline and mirrored-member displays. An unavailable explicit destination refuses with no fallback.
- [x] #3 Identity, topology and recovery gates are revalidated at execution. No eligible destination gives an actionable refusal with no moves. Display IDs are never guessed and recovery is never bypassed.
- [x] #4 Windows are attributed by the TASK-63 rule and moved preserving size and relative position within the destination visible frame, resizing only when larger than it. Tests cover negative origins, mixed scale, spanning, oversized and minimum-size windows. Apps are not activated and Spaces are not switched.
- [x] #5 Accessibility is requested only from an explicit in-app user interaction; CLI, app-control and background runs report missing or stale permission without prompting. Fullscreen, minimized, other-Space, vanished and nonmovable windows are skipped with reason codes; PanelCtl and system surfaces are excluded. A hung app times out as failed without blocking other moves. Results report moved/skipped/failed counts, never blanket success, and no titles by default.
- [x] #6 Action editor, run-action CLI and status expose the step and partial results consistently. A run installs no watcher and nothing is restored on Show. Re-running leaves windows already off the source untouched.
- [x] #7 Fake-backed tests cover selection, geometry, migration, same-display composition, permission denial/revocation, hung apps, topology changes and partial failures; docs state limits and the permission requirement. Native window moving needs separate explicit user approval and narrow gated tests; no DDC or private display writes are authorized.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Implement the approved docs/window-relocation.md one-shot contract: v3 lossless Action migration/composition, typed results, strict destination/geometry selection, app-only bounded AX worker and explicit permission interaction. 2. Integrate Action editor, app-control/CLI/status and execution gates without changing Hide or adding watchers. 3. Run focused fake-backed migration, selection, geometry, cancellation/permission/timeout and partial-result tests; update user documentation. 4. Perform one independent acceptance/safety verification, fix concrete scoped findings, refresh provider/repository state, commit on main and record delivery. No native window movement or hardware writes; native tests require separate approval.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented one-shot Move windows, v3 Action storage and stable step IDs, same-source composition, strict selection/gates, bounded app-only AX worker, explicit permission interaction and typed CLI/status/UI results. No watcher or Show restoration. One independent acceptance/safety verification passed AC2–6 and found one AC1/7 defect: Double decoding rounded unsupported payload integers above 2^53. Fixed by decoding signed/unsigned 64-bit integers before floating point; regression saves a valid sibling and checks exact positive/negative >2^53 and Int64/UInt64 boundary values plus unsupported identity/raw retention. No second general review was run. Parent reran swift test --disable-sandbox --filter WindowRelocationTests|DisplayActionAppTests|AppControlTests: 19 + 56 + 17 = 92 passed. Worker also built panelctl and PanelCtlApp successfully. git diff --check passes. LSP diagnostics were unknown (no version-matched report), not claimed clean. AC1/6 additionally verified with owner-approved native editor-only test: SettingsWindowTests.testMoveWindowsEditorShowsDestinationAndSavesWithoutRunning passes, preserves ID/destination, saves without running or prompting; visual snapshot .build/task64-ui/move-windows-editor.png confirms Move and Automatic controls. Two initial harness probes failed to expose SwiftUI pickers through NSPopUpButton/in-process accessibility, then switched to rendered snapshot plus established Save interaction; no focus-sensitive rerun loop. Native AX permission grant and real window moving remain unverified and require separate explicit approval; no permission prompt, real window move, DDC/private display write or TASK-65 watcher was performed. No worktree created. Implementation commit follows, then release claim and record delivery.
<!-- SECTION:NOTES:END -->
