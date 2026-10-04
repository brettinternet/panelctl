---
id: TASK-20
title: Gate experimental private disconnect controls on qualified recovery
status: To Do
assignee: []
created_date: '2026-10-04 17:13'
updated_date: '2026-10-04 18:15'
labels:
  - display-hide
  - app
dependencies:
  - TASK-17
  - TASK-12
  - TASK-9
references:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-trial.md
  - docs/display-recovery.md
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlCore/DisplayRecovery.swift
priority: low
type: feature
ordinal: 10010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mirror hide does not drop the Mac display signal. Users seeking signal removal need an honest, separately gated experimental disconnect path rather than a misleading hide label or silent backend fallback. This task is blocked on TASK-12 production providers, TASK-9 qualified trial evidence and the app recovery flow; their completion alone is not blanket hardware or automation approval. Keep mirror hide/handoff independently deliverable. Offline design, implementation and fake/no-write validation only. This task does not authorize live mirror/unmirror, DDC or private setter writes. Any hardware validation needs fresh scoped human approval; record untested behavior honestly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Expose experimental disconnect only for configurations supported by recorded qualification evidence, with explicit unavailable reasons otherwise. Clearly distinguish it from mirror hide, blackout, sleep and DDC input selection; never switch methods silently.
- [ ] #2 Each disconnect requires explicit scoped consent and the existing bounded lease, eligible remaining physical screen, qualified identity/lifecycle preflight, journal and watchdog. The app does not weaken backend refusals or promise indefinite disconnect.
- [ ] #3 Journal-driven reconnect/status remains available for non-enumerable displays and app restart. Identity ambiguity, expired leases, helper failures and unresolved restoration show actionable recovery without guessed IDs or discarded evidence.
- [ ] #4 Private disconnect is excluded from idle/empty-display automation, startup, wake and automatic re-disconnect. Any future unattended support requires a separate scoped decision and qualification task; panic/global restoration remains separately warned and explicitly approved.
- [ ] #5 Fake UI/core integration tests cover unavailable qualification, lease progress, refusal, watchdog recovery, relaunch and failed reconnect. Native UI verification uses synthetic states; any live trial is separately approved and recorded with exact scope and limitations.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Parked 2026-10-04 with TASK-12/TASK-9 (user decision: mirroring is the first hide route). App dependency is now TASK-17, which owns app journal recovery after the TASK-17/18 re-slice. Resume only if those tasks are resumed and qualified.
<!-- SECTION:NOTES:END -->
