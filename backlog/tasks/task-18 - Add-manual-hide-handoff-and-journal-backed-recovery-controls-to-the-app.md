---
id: TASK-18
title: Add optional DDC input switching to app hide and show
status: To Do
assignee: []
created_date: '2026-10-04 17:13'
updated_date: '2026-10-04 18:15'
labels:
  - display-hide
  - app
dependencies:
  - TASK-17
  - TASK-15
references:
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlCore/DisplayHandoff.swift
  - Sources/PanelCtlCore/DDC.swift
  - docs/ddc-input.md
  - docs/display-handoff.md
priority: medium
type: feature
ordinal: 8010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Handing a monitor to another computer from the app means hide plus an input switch, which TASK-15 sequences in the backend (switch then hide; show then switch) with DDC strictly optional. Extend the TASK-17 hide/show action with per-display input configuration rather than adding a second handoff action. Many monitors lack DDC or ignore writes, so manual monitor-button switching must remain a first-class, clearly explained outcome. Waits on TASK-15 because its supervised round trip may still change the combined behavior. Offline implementation and fake/no-write validation only; any live DDC or topology write needs fresh scoped human approval.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Per-display configuration adds optional away (other computer) and return (Mac) input codes with clear labels, using the existing ddc-input names and codes. Input switching is opt-in; unknown, unavailable or failed DDC capability explains manual monitor-button switching, and hide-only configuration never requires DDC. Saving or loading performs no DDC write or read beyond an explicit, user-initiated capability check.
- [ ] #2 Hide/show with inputs follows the TASK-15 order and confirmation shows the input change before consent. A skipped or failed DDC step never blocks showing; skipped, unverified and failed input outcomes are shown distinctly from desktop hide/show success.
- [ ] #3 Recovery messages distinguish returning the desktop from returning the monitor input, show the reported input recovery command or monitor-button fallback, and do not claim the input changed when readback was unavailable.
- [ ] #4 Invalid input codes, a DDC target whose identity changed since capture and stale saved inputs produce actionable validation; nothing is guessed or retried.
- [ ] #5 Fake tests cover DDC-capable, no-DDC, unverified, DDC failure before hiding and after showing, and stale configuration. Native Settings conditional controls are verified with synthetic states; relevant tests and warnings-as-errors builds pass.
<!-- AC:END -->
