---
id: TASK-8
title: Complete offline acceptance and independent safety review before a live trial
status: To Do
assignee: []
created_date: '2026-10-04 05:03'
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
