---
id: TASK-11
title: Qualify production display identity and preflight providers offline
status: To Do
assignee: []
created_date: '2026-10-04 14:49'
updated_date: '2026-10-04 16:14'
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
- [x] #1 Document a bounded evidence matrix for fresh retained-ID identity online and offline, target and survivor physical classification, driver exclusion, awake/lid and lifecycle state; distinguish independently established facts from cached or synthetic observations and name unsupported cases.
- [ ] #2 Where independently supportable, integrate production observations through the existing provider seams; unknown, stale, ambiguous, replaced, recycled-ID or unsupported evidence refuses before writer construction and at every mutation boundary. Never promote syntheticPhysicalFixture to production qualification.
- [x] #3 Fake-writer tests cover provider freshness and invalidation, identity reuse/replacement, unsupported hardware/OS, survivor loss, driver and lifecycle uncertainty; relevant compiler and focused recovery checks pass without display writes.
- [x] #4 One independent safety review traces production observation provenance and the command-to-writer gates; concrete findings are resolved or retained as explicit blockers. Publish either target-specific offline qualification evidence or an exact blocked verdict; refusal is not hardware qualification and unresolved provider criteria remain unchecked.
- [x] #5 Update TASK-9 with the precise technical gate result and next resumable step; no live trial is authorized by completion, and offline-inaccessible evidence requires a new scoped human decision, not guard relaxation.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Evaluate existing identity research and production gates; build a bounded provenance matrix.
2. Integrate only independently supported observations and exercise existing fake-writer gates; stop unsupported seams with exact evidence gaps.
3. Obtain one independent safety review, record qualification or blocked verdict, update TASK-9, and commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Bounded evidence assessment: docs/display-provider-qualification.md records unsupported fresh physical acquisition, unique retained-ID association and replacement/context invalidation. No complete production observation contract can be qualified from existing evidence; preserving all production refusals. Added isolated fake-writer refusal tests for unknown environment/initial lifecycle and fresh-timestamp production provenance attempting synthetic binding. No display writes or target selection. Independent review pending.

Resumed on main with user-authorized takeover. Fresh verification: 81 core recovery tests (one optional retained-ICC skip), one app recovery test, zero failures; panelctl and PanelCtlApp warnings-as-errors builds passed; git diff --check passed. Independent reviewer de8a264b-8a87-498a-9f79-660b665cd174 found no validated defects and confirmed blocked verdict/provenance and writer gates. AC2 remains unchecked: production observation contract is unqualified, including recovery-boundary environment refresh. Updated TASK-9 technical gate. User chose preparation of a scoped investigation proposal; docs/display-provider-qualification.md now proposes one static DCP BUND reconstruction and operation-7 producer/invalidation trace, not execution. Exact next input: approve that proposal or defer; no live-write consent requested or granted. Claim released; To Do means externally blocked, not eligible for repeated research. No worktree created or adopted.

Delivery: 95010c3 on main commits refusal regressions, bounded qualification evidence, independent review outcome, TASK-9 gate update and the requested investigation proposal. No push. AC2 remains blocked; proposal execution still needs explicit approval.

2026-10-04 user decision: firmware/operation-7 static investigation proposal not approved as the TASK-9 path; retained only as possible later identical-display hardening. The fresh-sink/unique-absent-mapping bar exceeded the canonical plan (section 2 defers the full offline identity contract). AC2 provider integration moves to TASK-12 under the plan's capture-evidence matching contract; TASK-9 now depends on TASK-12. This task's assessment deliverables stand; AC2 stays unchecked here.

Taken over 2026-10-04 by @pi after the prior agent was paused (user-authorized). No worktree or in-flight code; delivered work is on main (95010c3, a1f38af, ff9da2b). Archived rather than Done: AC1/3/4/5 delivered, AC2 not met here and superseded by TASK-12 under the plan's capture-evidence matching contract.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Delivered the bounded provider evidence matrix, refusal regressions, independent safety review and blocked verdict (docs/display-provider-qualification.md). Validation: 81 core recovery tests plus app recovery test, warnings-as-errors builds, git diff --check. AC2 (production provider integration) was not met under this task's stricter bar; user reverted to the canonical plan's contract and moved that work to TASK-12. Firmware investigation proposal declined. Archived as superseded, not completed.
<!-- SECTION:FINAL_SUMMARY:END -->
