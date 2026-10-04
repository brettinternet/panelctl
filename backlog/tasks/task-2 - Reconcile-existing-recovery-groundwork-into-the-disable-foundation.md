---
id: TASK-2
title: Reconcile existing recovery groundwork into the disable foundation
status: To Do
assignee: []
created_date: '2026-10-04 05:03'
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
- [ ] #1 A reconciliation record identifies adopted commits/components and deferred unrelated work with rationale; relevant source and evidence are available from the implementation baseline without relying on an ephemeral worktree.
- [ ] #2 Existing public restoration, v1 journals, unresolved-journal blocking, permissions, locks and verify-only rehearsal retain their safety behavior; added private transport remains unreachable from production until later gates.
- [ ] #3 Tests and docs distinguish current results from historical branch results, including the separate Mission Control/geometry history and opt-in origin-trial handler; no old test count is represented as a fresh run.
- [ ] #4 The current plan supersedes the old universal-identity research stop only for offline development; unknown sink identity still forbids private writes. No duplicate journal/helper subsystem is introduced.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->
