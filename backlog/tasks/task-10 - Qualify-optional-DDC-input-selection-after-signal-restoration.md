---
id: TASK-10
title: Qualify optional DDC input selection after signal restoration
status: To Do
assignee: []
created_date: '2026-10-04 05:03'
labels:
  - display-disable
  - follow-up
  - ddc
  - human-gated
dependencies:
  - TASK-9
references:
  - Sources/PanelCtlCore/DDC.swift
  - Tests/PanelCtlCoreTests/DDCTests.swift
  - docs/feasibility.md
  - docs/display-disable-tool-survey.md
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: low
type: spike
ordinal: 10
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Conditional follow-up, not part of the initial disable gate. The monitor may stay on HDMI after the Mac restores DP. Use TASK-9 observations to decide whether VCP 0x60 input-select is actually needed. Reuse existing IOAV/DDC transport and safety conventions; luminance success on another monitor is not qualification of input writes here. Bound scope to this monitor/connection and an explicit skippable action after successful re-enable, or document that no input action is needed. Input-switching as a standalone alternative can be documented, not silently substituted for successful disable. DDC 0xD6 power remains excluded.

Direction: docs/display-disable-implementation-plan.md is canonical. This task is approval-gated; task creation and dependency completion do not grant live-write permission. Preserve unresolved journals and report exact blockers. No DDC power, blind IDs, permanent writes or automatic disruptive fallback.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A decision cites actual trial input-return behavior: unnecessary means a documented no-code outcome; otherwise target input values, transport addressability and verification limitations are explicit.
- [ ] #2 Any implementation is explicit/opt-in, narrowly targeted and independently testable; failed/skipped input selection never misreports topology recovery or initiates power/link control.
- [ ] #3 Fake protocol tests cover encoding, unsupported feature, transport loss, ambiguous target and readback mismatch without firmware writes. No assumption that DDC reaches a logically disabled monitor is made.
- [ ] #4 Real VCP 0x60 writes require fresh scoped human approval and a monitor-specific qualification record; untested hardware behavior remains unsupported. No power command, blind input cycling or automatic firmware-write fallback exists.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->
