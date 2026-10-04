---
id: TASK-2
title: Reconcile existing recovery groundwork into the disable foundation
status: Done
assignee: []
created_date: '2026-10-04 05:03'
updated_date: '2026-10-04 05:40'
labels:
  - display-disable
  - offline
  - integration
dependencies: []
references:
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - Sources/PanelCtlCore/RecoveryJournal.swift
  - Sources/PanelCtlCore/RecoveryWatchdog.swift
  - Tests/PanelCtlCoreTests/DisplayRecoveryTests.swift
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: high
type: task
ordinal: 2
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Main already contains journal, public restore and helper code; do not duplicate it. The existing recovery-enable branch was inspected at 418fa33a4289f3da4787844be209fbb5d2647cbb and is retained at .worktrees/recovery-enable. It adds RecoveryReenable.swift/tests, ICC-date-aware comparison, observer/identity evidence, origin trials and unrelated blackout changes. Inspect git diff main...recovery-enable and branch docs/recovery-reenable.md, recovery-integration-review.md, recovery-identity-contract.md, recovery-identity-binary.md and recovery-firmware-consumers.md. Reuse relevant tested groundwork with provenance, not an indiscriminate merge. This task grants no ownership of that worktree, merge/push authority over another agent's work, or live trial permission. ABI verification is the recommended first action, but this source reconciliation is independently ready.

Direction: docs/display-disable-implementation-plan.md is canonical; docs/display-disable-tool-survey.md supplies evidence, not hardware qualification. Initial scope is one non-main external display, no mirroring, Apple Silicon, session-only transactions and explicit consent. Use injected/fake display writers for routine work; no live private setter, DDC write, display change, or disruptive recovery is authorized by this task. Preserve unresolved journals and fail closed on unknown identity. Record any real external blocker and the exact evidence or human approval needed; never weaken a guard to mark the task done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A reconciliation record identifies adopted commits/components and deferred unrelated work with rationale; relevant source and evidence are available from the implementation baseline without relying on an ephemeral worktree.
- [x] #2 Existing public restoration, v1 journals, unresolved-journal blocking, permissions, locks and verify-only rehearsal retain their safety behavior; added private transport remains unreachable from production until later gates.
- [x] #3 Tests and docs distinguish current results from historical branch results, including the separate Mission Control/geometry history and opt-in origin-trial handler; no old test count is represented as a fresh run.
- [x] #4 The current plan supersedes the old universal-identity research stop only for offline development; unknown sink identity still forbids private writes. No duplicate journal/helper subsystem is introduced.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Inspect pinned recovery-enable changes and historical evidence against main. 2. Adopt only bounded reusable recovery components/tests, preserving production private-write refusal; record provenance and deferred work. 3. Run offline checks and one independent safety review, record fresh results, finalize and commit only TASK-2 changes on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Adopted selected 42a3bd0/2dcacce components from recovery-enable at 418fa33: ICC date-only comparison and tests, injected missing-display policy/transaction ordering, one-shot journal intent and fake-writer tests. Deliberately omitted live transport (default throws), origin-trial payload/production handler, observer product and unrelated blackout changes. docs/recovery-reconciliation.md preserves provenance and identity limits. Fresh offline suite: 176 tests, 175 passed, one optional ICC-artifact skip, zero failures; live-window geometry test explicitly excluded. Both products build with warnings-as-errors; release-version checks pass. Independent safety verification pending. TASK-1 edits remain untouched.

Resumed on main with explicit user authorization to adopt in-progress backlog work and commit its existing changes. Rechecking offline evidence and completing the pending independent safety verification; no hardware-write authorization.

Resumed existing TASK-2 changes on main under explicit handoff. Independent verifier dda1dbe9-1d60-4452-b06e-ad972c7378c2 checking acceptance and safety; rerunning offline tests/builds before commit.

Delivered on main in e39dae2 (Reconcile recovery foundation for TASK-2). Changed DisplayRecovery.swift, RecoveryJournal.swift, added RecoveryColorProfile.swift and RecoveryReenable.swift with corresponding tests, extended DisplayRecoveryTests.swift, updated docs/display-recovery.md and added docs/recovery-reconciliation.md. Fresh parent verification: swift test --disable-sandbox --skip BlackoutGeometryTests.testWindowPlacementOnConnectedExternalScreens: 176 tests, 175 passed, one optional ICC-artifact skip, zero failures. Both panelctl and PanelCtlApp builds passed with -Xswiftc -warnings-as-errors; scripts/test-release-version.sh and git diff --check passed. Independent verifier dda1dbe9-1d60-4452-b06e-ad972c7378c2 passed all four criteria with no concrete scoped defects; separately ran 23 DisplayRecovery tests and 16 re-enable/color tests (15 passed, one skip). This supersedes earlier pending-review notes. No live display writes, subprocess rehearsal or hardware qualification performed. Private transport remains unreachable; production identity/backend and full disable lifecycle remain later gates. No TASK-2 blocker remains. Next step is TASK-3 bounded identity/refusal implementation. No worktree created or adopted; unrelated .worktrees/recovery-enable retained untouched. Claim released.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Selectively adopted ICC creation-date comparison, injected re-enable policy/transaction ordering and one-shot journal intent without exposing a production private writer. Committed implementation as e39dae2 on main. All acceptance criteria independently verified; 175 offline tests passed, one optional artifact skip, both warnings-as-errors builds and release checks passed. Provenance, deferred work and historical-versus-fresh evidence documented in docs/recovery-reconciliation.md. No hardware qualification claimed.
<!-- SECTION:FINAL_SUMMARY:END -->
