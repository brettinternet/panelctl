---
id: TASK-11
title: Qualify production display identity and preflight providers offline
status: To Do
assignee: []
created_date: '2026-10-04 14:49'
labels:
  - display-disable
  - offline
  - qualification
dependencies:
  - TASK-8
references:
  - Sources/PanelCtlCore/RecoveryPrivateSession.swift
  - Sources/PanelCtlCore/RecoveryIdentityPolicy.swift
  - docs/recovery-identity-policy.md
  - docs/display-disable-trial.md
documentation:
  - docs/display-disable-implementation-plan.md
priority: high
type: task
ordinal: 1010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
User approved scoping this offline prerequisite after TASK-9 preparation confirmed production providers still always refuse. The complete synthetic protocol cannot qualify a real target: RecoveryPrivateSession has no qualified physical-sink inventory, its physical/driver environment is unknown, and initial awake state is false. Bound this work to the single non-main external target on the supported Apple Silicon host/OS, using existing identity research and provider seams. Evaluate existing evidence first; implement and independently qualify real observations only where evidence supports them. No universal identity research, multi-identical-display support, alternate recovery framework, synthetic production binding or guard bypass. Offline/read-only observations and fake writers only; no private setter (including online enable), public restoration, DDC writes, topology changes, sleep/crash/hotplug trials or disruptive recovery. If offline evidence cannot establish fresh retained-ID identity while absent or another required property, stop that seam with the exact missing evidence and separately scoped next decision rather than guessing or repeatedly researching. TASK-9 remains blocked until actual provider qualification and fresh scoped human approval, regardless of this task status.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Document a bounded evidence matrix for fresh retained-ID identity online and offline, target and survivor physical classification, driver exclusion, awake/lid and lifecycle state; distinguish independently established facts from cached or synthetic observations and name unsupported cases.
- [ ] #2 Where independently supportable, integrate production observations through the existing provider seams; unknown, stale, ambiguous, replaced, recycled-ID or unsupported evidence refuses before writer construction and at every mutation boundary. Never promote syntheticPhysicalFixture to production qualification.
- [ ] #3 Fake-writer tests cover provider freshness and invalidation, identity reuse/replacement, unsupported hardware/OS, survivor loss, driver and lifecycle uncertainty; relevant compiler and focused recovery checks pass without display writes.
- [ ] #4 One independent safety review traces production observation provenance and the command-to-writer gates; concrete findings are resolved or retained as explicit blockers. Publish either target-specific offline qualification evidence or an exact blocked verdict; refusal is not hardware qualification and unresolved provider criteria remain unchecked.
- [ ] #5 Update TASK-9 with the precise technical gate result and next resumable step; no live trial is authorized by completion, and offline-inaccessible evidence requires a new scoped human decision, not guard relaxation.
<!-- AC:END -->
