---
id: TASK-19
title: Expose app hide and show to scripts without unattended hiding
status: To Do
assignee: []
created_date: '2026-10-04 17:13'
updated_date: '2026-10-04 18:15'
labels:
  - display-hide
  - app
dependencies:
  - TASK-17
references:
  - Sources/PanelCtlApp/AppControlServer.swift
  - Sources/PanelCtlApp/AppDelegate.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - Sources/PanelCtlCore/CLIParser.swift
  - docs/usage.md
priority: medium
type: feature
ordinal: 9010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Scripts and Shortcuts control the app through panelctl app, while the Automation page runs unattended idle and empty-display protection. Direct panelctl mirror/away/back already serve scripts that pass UUIDs and journals; app actions add invocation by saved per-display configuration and serialization with app state. Add explicit hide/show app actions using the TASK-17 configuration (including TASK-18 inputs once present) without conflating them with unattended OLED protection. Do not build a rules engine or repurpose existing app enable/disable/toggle. Offline implementation and fake/no-write validation only; any live mirror/unmirror or DDC write needs fresh scoped human approval.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Documented panelctl app actions hide and show a configured display using the same settings, identity guards, confirmation policy and journal ownership as the UI. Headless calls that would need confirmation fail actionably instead of hanging on a dialog or bypassing the gate.
- [ ] #2 Existing app enable/disable/toggle, blackout-now, restore, snooze/resume and sleep-now keep their documented meaning, except any Restore extension approved in TASK-16. Status JSON adds per-display observed hide state, operation progress, recovery-needed and skipped/partial input outcomes without presenting saved configuration as observed state.
- [ ] #3 Requests serialize with UI and CLI mutations. Repeating hide or show on an already hidden or shown display is a reported no-op, never a toggle or a repeated DDC write; conflicting, stale-target and lost-response cases are tested.
- [ ] #4 Idle and empty-display triggers stay overlay-only: no automatic hide, input switch or private disconnect, no empty-display hide feedback loop and no startup/wake re-hide. Any unattended hide policy needs a separately approved task.
- [ ] #5 Scripts get documented exit codes and machine-readable outcomes for refusal, app unavailable, confirmation required, partial completion and recovery-needed; show works regardless of protection enablement or snooze.
- [ ] #6 docs/usage.md gains script/Shortcuts examples, and fake end-to-end control-protocol tests cover success, duplicate/concurrent requests, protection interaction and failures; relevant tests and builds pass without hardware writes.
<!-- AC:END -->
