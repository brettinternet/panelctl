---
id: TASK-17
title: Add per-display hide and handoff settings without changing protection defaults
status: To Do
assignee: []
created_date: '2026-10-04 17:13'
labels:
  - display-hide
  - app
dependencies:
  - TASK-16
references:
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlApp/ProtectionPreferences.swift
  - Sources/PanelCtlApp/AppModel.swift
  - docs/display-mirroring.md
  - docs/ddc-input.md
priority: medium
type: feature
ordinal: 7010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Users need to configure a monitor once for temporary desktop removal or handoff, without changing which displays receive OLED protection. Follow the approved interaction contract and extend existing preferences/UI conventions. Configuration must remain separate from executing an operation, with manual input switching a first-class supported choice. Offline design, implementation and fake/no-write validation only. This task does not authorize live mirror/unmirror, DDC or private setter writes. Any hardware validation needs fresh scoped human approval; record untested behavior honestly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Expose the approved per-display settings in existing navigation, with separate protection selection and hide/handoff configuration; show target identity, an explicit eligible mirror source and optional away/return input codes with clear Mac/other-computer labels.
- [ ] #2 DDC is opt-in and capability-dependent. Unknown, unavailable and failed capability states explain manual monitor-button switching; no input code, source display or target identity is guessed. Do not require DDC to save a hide-only configuration.
- [ ] #3 Saving, editing, loading or migrating settings performs no topology or DDC write. Existing installations retain their protection behavior, and launch at login never implies hide, handoff or private disable.
- [ ] #4 Missing displays retain intelligible saved configuration but cannot silently bind to a different display; ambiguous identity, invalid inputs, ineligible sources and unsupported targets produce actionable validation before execution.
- [ ] #5 Persistence and migration tests cover legacy preferences, per-display independence, unavailable/reconnected displays and invalid values. Verify the actual native Settings UI with fixtures for layout, keyboard navigation, accessible labels and conditional controls.
<!-- AC:END -->
