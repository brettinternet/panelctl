---
id: TASK-8
title: Complete offline acceptance and independent safety review before a live trial
status: In Progress
assignee:
  - pi
created_date: '2026-10-04 05:03'
updated_date: '2026-10-04 08:20'
labels:
  - display-disable
  - offline
  - qualification
dependencies:
  - TASK-7
references:
  - Tests/PanelCtlCoreTests
  - scripts/test-display-recovery.swift
  - docs/recovery-validation.md
  - docs/development.md
  - Package.swift
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: high
type: task
ordinal: 8
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Green fake tests and a READY helper are necessary but not hardware qualification. Independently verify the complete command-to-writer chain, transaction lifetime, identity refusal, write-ahead ordering and crash/race behavior. Reuse existing focused tests and no-write subprocess rehearsals; do not add an alternate recovery framework. Branch historical test counts and origin-trial evidence are not current acceptance. Standard tests on this repo may create blackout windows: audit opt-in hardware tests and keep state-changing private/display-restoration trials disabled.

Direction: docs/display-disable-implementation-plan.md is canonical; docs/display-disable-tool-survey.md supplies evidence, not hardware qualification. Initial scope is one non-main external display, no mirroring, Apple Silicon, session-only transactions and explicit consent. Use injected/fake display writers for routine work; no live private setter, DDC write, display change, or disruptive recovery is authorized by this task. Preserve unresolved journals and fail closed on unknown identity. Record any real external blocker and the exact evidence or human approval needed; never weaken a guard to mark the task done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Current focused suites, full swift test, debug/release CLI/app builds and release-version checks are recorded with commands/results; universal compatibility is checked including x86_64 build while private disable stays unavailable there.
- [ ] #2 The fake-writer matrix includes every mutation-boundary failure, journal persistence crash window, completion-consumed error, identity reuse/replacement, topology collapse, sleep/wake and concurrent recovery; regressions are fixed without weakening assertions.
- [ ] #3 No-write subprocess checks demonstrate deadline and parent/helper death behavior using capture/verify/rehearse only. Environment-dependent checks not run are explicit gaps, not passes.
- [ ] #4 An independent reviewer traces all production private-call entry points and the journal/lease protocol. Validated safety findings are resolved or explicitly block the trial.
- [ ] #5 A pre-trial evidence checklist distinguishes offline acceptance, actual target identity eligibility and still-unproven hardware behavior. A refusal-only provider cannot pass the real-target gate; no private setter or disruptive fallback is invoked.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit hardware-test opt-ins and existing failure matrix; run fresh offline suites and platform builds.
2. Run capture/verify/rehearse subprocess checks only and record environment gaps.
3. Obtain one independent safety review of production entry points and lease/journal races; fix confirmed defects with focused regressions.
4. Publish a pre-trial evidence checklist, finalize task evidence and commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Fresh TASK-8 validation on 26A434/Swift 6.4: full suite 215 tests, 0 failures, 2 explicit skips (live blackout and optional retained ICC); focused recovery 77 tests, 0 failures, 1 skip. Debug/release CLI/app and x86_64 release products built; universal outputs verified as x86_64 arm64. Intel SwiftPM discovery failed architecture loading; direct Rosetta xctest ran 15 binding/eligibility/production-refusal tests successfully. Debug and release capture/verify/rehearse subprocess matrices passed (deadline, parent INT/TERM/KILL/EOF, helper KILL, locks, stale boot); no display writes. Changed live blackout geometry test to require explicit PANELCTL_TEST_LIVE_BLACKOUT=1. Fresh evidence/checklist drafted in docs/display-disable-offline-acceptance.md. Independent read-only Codex gpt-6-sol review running; initial Claude authentication and unsupported Codex model attempts did not review code. Logs retained in .build/task8. No worktree created, no push, no live-trial authorization.

Independent review completed (Codex gpt-6-sol, high, read-only; .build/task8/review-sol.txt): two validated authority defects. Reproduced both before correction (two tests/six failing assertions). Fixed shared-engine retirement on retained-ID reappearance with persistent verify-only behavior, and added disableCommitStarted after final validation so canceled/legacy staging cannot authorize enable. Failed commit-intent save revokes in-memory authority as well. Expanded lease revocation, legacy/persistence and transaction-callback regressions; no assertions weakened. Final reruns: full swift test 217 tests (163 core, 54 app), 0 failures/2 skips; focused 79 core recovery tests, 0 failures/1 skip; Rosetta 18 tests, 0 failures; debug/release CLI/app and Intel release builds, version script, both no-write subprocess runs and universal architecture checks all passed. LSP reports were clean where available; some bounded reports unknown, compiler/tests passed. Changed production files: DisplayRecovery.swift, RecoveryCLI.swift, RecoveryDisable.swift, RecoveryJournal.swift, RecoveryReenable.swift; tests: BlackoutGeometryTests, RecoveryCLITests, RecoveryDisplayBindingTests, RecoveryLeaseTests, RecoveryReenableTests; docs: development, display-recovery, display-transaction-backend, recovery-private-lease, recovery-validation and new display-disable-offline-acceptance. No second general review or hardware writes. Full evidence, commands, retained artifacts, review trace and pre-trial checklist are in docs/display-disable-offline-acceptance.md. TASK-9 still requires qualified real identity/physical/lifecycle providers and explicit scoped human approval; refusal-only providers are not qualification.
<!-- SECTION:NOTES:END -->
