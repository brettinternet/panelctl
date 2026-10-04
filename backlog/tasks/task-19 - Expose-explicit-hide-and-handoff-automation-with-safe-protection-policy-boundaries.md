---
id: TASK-19
title: >-
  Expose explicit hide and handoff automation with safe protection-policy
  boundaries
status: To Do
assignee: []
created_date: '2026-10-04 17:13'
labels:
  - display-hide
  - app
dependencies:
  - TASK-18
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
Scripts and Shortcuts already control saved app settings through panelctl app, while the Automation page runs idle and empty-display protection. Extend those existing surfaces without conflating explicit monitor handoff with unattended OLED protection. Follow the approved UX behavior matrix; do not build a new generic rules engine or repurpose existing app disable/toggle commands. Offline design, implementation and fake/no-write validation only. This task does not authorize live mirror/unmirror, DDC or private setter writes. Any hardware validation needs fresh scoped human approval; record untested behavior honestly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Provide documented explicit app automation actions for hide/show and away/back using the same settings, identity guards, consent policy and journal ownership as the UI. Headless calls needing consent fail actionably rather than hang on a dialog or bypass a gate.
- [ ] #2 Existing app enable/disable/toggle, blackout-now, restore, snooze/resume and sleep-now retain their documented meaning, except any explicitly approved and documented Restore extension. Status JSON exposes per-display observed state, operation progress, recovery-needed and partial/skipped outcomes without presenting saved intent as observed state.
- [ ] #3 Requests are serialized with UI and CLI mutations; repeated hide/show/away/back requests do not toggle unexpectedly or repeat DDC writes. Tests cover already-completed requests, conflicting actions, missing/stale targets and lost responses.
- [ ] #4 The Automation page clearly states which actions are supported by idle/empty-display triggers. Existing triggers stay overlay-only by default; no automatic handoff, DDC switch or private disconnect, no empty-display hide feedback loop, and no startup/wake re-hide is introduced. Any proposed unattended mirror-hide policy requires a separately approved safety scope before enabling it.
- [ ] #5 Scripts receive documented machine-readable errors/outcomes for refusal, app availability, consent required, partial completion and recovery-needed; return/show remains possible independently of protection enablement or snooze.
- [ ] #6 Add script/Shortcuts examples and fake end-to-end control-protocol tests for manual automation, duplicate/concurrent requests, protection interaction and failures. Pass relevant tests and builds without hardware writes.
<!-- AC:END -->
