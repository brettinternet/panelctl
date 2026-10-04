---
id: TASK-17
title: Add hide and show for one configured display to the app
status: To Do
assignee: []
created_date: '2026-10-04 17:13'
updated_date: '2026-10-04 18:15'
labels:
  - display-hide
  - app
dependencies:
  - TASK-16
  - TASK-13
references:
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlApp/AppDelegate.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/ProtectionPreferences.swift
  - Sources/PanelCtlCore/DisplayMirroring.swift
  - Sources/PanelCtlCore/DisplayHandoff.swift
  - docs/display-mirroring.md
priority: medium
type: feature
ordinal: 7010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hiding an external desktop is CLI-only today, requiring UUIDs, consent flags and a remembered journal path. Deliver the first usable app slice of the approved TASK-16 contract: configure a display once (target and explicit mirror source), hide and show it from the approved surfaces, and recover from the journal, with no DDC. This replaces the earlier split between a settings-only task and a controls task, because saved configuration without an action is unverifiable dead UI. Reuse MirrorController/HandoffController, their locks and the shared recovery journal; do not build a parallel recovery path. Protection selection and defaults stay unchanged. Offline implementation and fake/no-write validation only; any live mirror/unmirror needs fresh scoped human approval and untested behavior is recorded honestly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Per-display hide configuration lives in the approved place in existing navigation, separate from protection selection: target identity and an explicit eligible mirror source. Nothing is guessed; saving, editing, loading or migrating settings performs no topology write, existing installations keep their protection behavior and launch at login never implies hide.
- [ ] #2 Users can hide and show one configured eligible non-main external display from the approved surfaces, seeing target and source before the approved confirmation. Backend eligibility, locks and journal-before-write guarantees are reused; busy actions cannot be submitted twice or race CLI operations.
- [ ] #3 Show uses the journaled target and captured topology, not the current selection. Identity refusal, restoration mismatch and partial failure keep the journal and show an actionable next step without reporting success; journals created by panelctl mirror/away are recognized.
- [ ] #4 Observed state is rendered separately from saved configuration and protection status. Journal-owned hidden or unavailable targets keep a show/recovery action that works with Settings closed, after relaunch and with the menu icon hidden; missing displays keep intelligible configuration but never bind to a different display.
- [ ] #5 The approved coexistence and lifecycle behavior for protection, Restore, snooze, quit/relaunch, sleep/wake and hotplug is implemented. The app does not fight system restoration, silently re-hide, clear unresolved journals or escalate to global reset/logout/reboot.
- [ ] #6 Tests cover legacy preference migration, per-display independence, stale/missing targets, duplicate requests, backend refusal, interruption and partial failure with fake writers. Native menu and Settings flows are verified with synthetic states for layout, keyboard navigation and accessible labels; relevant tests and warnings-as-errors builds pass.
<!-- AC:END -->
