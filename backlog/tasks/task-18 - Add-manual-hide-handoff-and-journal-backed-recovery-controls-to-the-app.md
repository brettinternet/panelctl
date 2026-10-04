---
id: TASK-18
title: 'Add manual hide, handoff and journal-backed recovery controls to the app'
status: To Do
assignee: []
created_date: '2026-10-04 17:13'
labels:
  - display-hide
  - app
dependencies:
  - TASK-17
  - TASK-13
  - TASK-15
references:
  - Sources/PanelCtlApp/AppDelegate.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlCore/DisplayMirroring.swift
  - Sources/PanelCtlCore/DisplayRecovery.swift
priority: medium
type: feature
ordinal: 8010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
CLI-only hide and away/back leave everyday users without a discoverable app action or a reliable way back. Deliver the approved menu-bar and Displays flows using existing core operations and journals, not a parallel recovery implementation. Hide-only must work independently of optional DDC handoff. Backend TASK-15 remains owned by its current assignee. Offline design, implementation and fake/no-write validation only. This task does not authorize live mirror/unmirror, DDC or private setter writes. Any hardware validation needs fresh scoped human approval; record untested behavior honestly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Users can perform explicit hide/show and away/back for one configured eligible non-main external display from the approved app surfaces. Show the chosen target/source and optional input changes before consent; reuse backend eligibility, ordering, locks and journal-before-write guarantees.
- [ ] #2 Render observed state separately from saved intent and protection status. Journal-owned hidden or unavailable targets stay visible with the correct return/recovery action, and busy actions cannot be submitted twice or race CLI operations.
- [ ] #3 Return/show uses the journaled target and captured topology rather than the current selection. Failed or skipped DDC never blocks unhiding; partial success, identity refusal and restoration mismatch retain the journal and show an actionable next step without reporting success.
- [ ] #4 Implement the approved coexistence and lifecycle behavior for protection, Restore, snooze, quit/relaunch, sleep/wake and hotplug. Do not fight system restoration, silently re-hide, clear unresolved journals or escalate to global reset/logout/reboot.
- [ ] #5 Return/recovery remains accessible with Settings closed and after app relaunch, including when the status icon is hidden. Recovery messages distinguish returning the desktop from returning the monitor input and describe manual input switching when needed.
- [ ] #6 Fake integration tests cover successful hide/show and away/back, no-DDC operation, stale settings, duplicate requests, backend refusal, interruption and partial failure. Verify native menu/Settings flows with synthetic states and accessibility checks; pass relevant tests and warnings-as-errors builds.
<!-- AC:END -->
