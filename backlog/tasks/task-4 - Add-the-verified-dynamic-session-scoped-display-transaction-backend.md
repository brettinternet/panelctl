---
id: TASK-4
title: Add the verified dynamic session-scoped display transaction backend
status: Done
assignee: []
created_date: '2026-10-04 05:03'
updated_date: '2026-10-04 06:06'
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
- [x] #1 Resolver tests cover preferred symbol, qualified fallback, missing framework/symbol and unsupported architecture/ABI; unavailable returns a specific diagnostic and makes no display write.
- [x] #2 Function pointer uses the verified C convention and widths, not a Swift @_silgen_name call or pointer-sized Int return; no strong private symbol import is introduced.
- [x] #3 Fake transaction tests prove begin/stage/complete order, retained target ID, false/true arguments and session scope only. Begin/staging/precommit identity errors do not commit; pre-completion errors cancel exactly once.
- [x] #4 Completion success and failure consume the transaction; no cancellation or reuse follows complete, and errors preserve recovery evidence rather than reporting restored.
- [x] #5 Revalidation occurs at mutation boundaries; unsupported platform and failed identity cannot reach the setter. No production activation or actual API invocation occurs in this task.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend the existing injected enable transaction to stage either Boolean value, with session-only completion and boundary revalidation. 2. Add an internal dynamic binding gated by the TASK-1 architecture/build/image UUID evidence; retain library lifetime and leave default recovery transport unavailable. 3. Exercise resolver and transaction failures with fake loaders/writers, including durable recovery evidence. 4. Run focused/full checks, one independent safety review, document limits, and commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete pending independent acceptance review. Changed RecoveryDisplayBinding.swift (internal dynamic exact-C-ABI resolver with build/image gates and owned handle), RecoveryReenable.swift (both Boolean values, session-only completion), DisplayRecovery.swift (shared host-string reader), fake-loader/transaction/recovery tests, and backend/recovery documentation. Fresh swift test --disable-sandbox: 188 tests, one opt-in skip, zero failures. Both CLI/app product builds, release-version checks and diff check passed. nm -u on both debug products found no strong private setter import. LSP clean except RecoveryReenable.swift report unknown; compiler/tests passed. No live setter, display transaction, DDC or recovery trial executed. Default production transport remains unavailable; next step is consume independent review, fix concrete findings if any, and commit.

Resumed on main with explicit user handoff of existing uncommitted implementation. Revalidating offline checks and completing the pending independent acceptance review before commit.

Delivered on main in commit 409205a (Add verified offline display transaction backend). Fresh resumed validation: swift test --disable-sandbox passed 188 tests (one opt-in skip), both product builds passed, scripts/test-release-version.sh and git diff --check passed, xcrun nm -u on both debug products found no strong private setter imports. Independent verifier run 9f3d70ee-8cca-4e49-82d8-f69287adcdbf passed all five criteria with no concrete defects; independently reran 7 binding and 15 re-enable tests, import and diff checks. No corrections required. Claim released. No TASK-4 blocker remains; next handoff is TASK-5 crash-safe journal/watchdog integration. Residual limits: build 26A434/arm64 and recorded image UUIDs only; production identity provider remains unqualified and binding disconnected. No live resolver, setter, transaction, DDC or hardware qualification was performed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented and committed offline-only dynamic exact-C-ABI binding and session-scoped enable/disable transaction primitive (409205a). Fake tests prove resolver refusal/fallback, identity boundaries, cancellation/consumption, retained IDs and durable no-replay recovery evidence. Full tests/builds and independent acceptance review passed. Production activation and hardware trials remain gated.
<!-- SECTION:FINAL_SUMMARY:END -->
