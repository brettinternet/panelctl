---
id: TASK-4
title: Add the verified dynamic session-scoped display transaction backend
status: To Do
assignee: []
created_date: '2026-10-04 05:03'
labels:
  - display-disable
  - offline
  - backend
dependencies:
  - TASK-1
  - TASK-3
references:
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - Sources/PanelCtlCore/Probe.swift
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: high
type: feature
ordinal: 4
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Provide the narrow private transaction primitive needed by the existing recovery pipeline, extending the integrated true-only RecoveryReenable transport rather than creating a competing writer. Binding must use TASK-1 evidence and TASK-3 preconditions: CoreGraphics CGS symbol first, SkyLight SLS fallback, dynamic resolution and exact C ABI. The application must still start when unavailable. The low-level implementation can stage disable and enable for the later orchestrator, but no standalone unguarded CLI or production path is exposed here. Keep the transaction boundary small and reuse existing closure-based test seams.

Direction: docs/display-disable-implementation-plan.md is canonical; docs/display-disable-tool-survey.md supplies evidence, not hardware qualification. Initial scope is one non-main external display, no mirroring, Apple Silicon, session-only transactions and explicit consent. Use injected/fake display writers for routine work; no live private setter, DDC write, display change, or disruptive recovery is authorized by this task. Preserve unresolved journals and fail closed on unknown identity. Record any real external blocker and the exact evidence or human approval needed; never weaken a guard to mark the task done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Resolver tests cover preferred symbol, qualified fallback, missing framework/symbol and unsupported architecture/ABI; unavailable returns a specific diagnostic and makes no display write.
- [ ] #2 Function pointer uses the verified C convention and widths, not a Swift @_silgen_name call or pointer-sized Int return; no strong private symbol import is introduced.
- [ ] #3 Fake transaction tests prove begin/stage/complete order, retained target ID, false/true arguments and session scope only. Begin/staging/precommit identity errors do not commit; pre-completion errors cancel exactly once.
- [ ] #4 Completion success and failure consume the transaction; no cancellation or reuse follows complete, and errors preserve recovery evidence rather than reporting restored.
- [ ] #5 Revalidation occurs at mutation boundaries; unsupported platform and failed identity cannot reach the setter. No production activation or actual API invocation occurs in this task.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->
