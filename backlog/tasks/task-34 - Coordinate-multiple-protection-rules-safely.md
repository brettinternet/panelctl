---
id: TASK-34
title: Coordinate multiple protection rules safely
status: To Do
assignee: []
created_date: '2026-10-05 22:29'
labels:
  - app
  - automation
  - safety
dependencies: []
references:
  - Sources/PanelCtlApp/ProtectionPreferences.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - Sources/PanelCtlApp/AppModel.swift
  - TASK-33
  - TASK-32
documentation:
  - docs/display-hide-ux.md
  - docs/development.md
priority: medium
type: feature
ordinal: 24010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Different displays need different idle and empty-display protection without independent watchers fighting over covers, brightness or global sleep. Establish the runtime and persisted rule contract before exposing multiple rules in Settings. Preserve the existing single-configuration experience until the follow-up UI ships. Initial scope is existing blackout/dimming protection and existing global sleep follow-up, not schedules, arbitrary action chains, automatic Hide/Show, input switching, power or private disconnect. Offline implementation and fake-backed validation only; no hardware writes are authorized. TASK-31 and TASK-32 are separate topology work, not prerequisites: preserve the topology and recovery guarantees supported by the integrated build without implementing those features here.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Named rules have stable IDs, persisted enablement, explicit display selection, supported idle/empty triggers, blackout/dimming settings, end behavior and existing playback/camera exceptions. Legacy preferences migrate once into one equivalent rule without losing settings or changing enabled state or behavior; relaunch is idempotent.
- [ ] #2 Multiple nonconflicting rules can protect different displays concurrently. Conflicting enabled target selections are refused with an explanation rather than resolved by hidden priorities; dynamic All displays selections and hotplug are rechecked before treatment. Global display sleep is explicitly coordinated across rules rather than treated as a per-display action.
- [ ] #3 A shared safety decision accounts for combined active and pending treatments, manual Hides, removed displays and usable survivors. Concurrent rules cannot bypass existing all-display time limits or last-visible safeguards; strict identity, mirrored-source restrictions, operation locks and unresolved recovery blocks remain effective.
- [ ] #4 Each rule restores only its own applied treatment and saved brightness. Activity, timeout, Restore, disable, deletion and Pause All never show a manually hidden display or switch inputs. Cleanup failures retain evidence and expose the existing retry path; new conflicting treatment cannot proceed until cleanup is verified.
- [ ] #5 Empty-display triggers are debounced and do not flap; repeated observations do not repeat hardware writes. Manual Restore suppresses immediate retriggering until a documented fresh trigger condition. Sleep, wake, hotplug, missing displays, helper exit and relaunch have deterministic behavior without replaying topology, input or power operations.
- [ ] #6 Existing app enable/disable, snooze/resume, blackout-now, restore and status commands have documented compatible aggregate semantics and expose per-rule state where needed. Existing single-rule behavior remains covered; no generic action follows a mutable per-display Hide style.
- [ ] #7 Fake clocks, display inventories, helpers and writers cover simultaneous triggers, conflicting targets, aggregate all-display safety, ownership, migration, lifecycle and cleanup failure. Full offline tests and warnings-as-errors builds pass; docs describe the rule contract and exclusions without claiming new hardware qualification.
<!-- AC:END -->
