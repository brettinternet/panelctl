---
id: TASK-52
title: Resolve saved display references across numeric ID changes
status: Done
assignee:
  - '@pi'
created_date: '2026-10-06 23:11'
updated_date: '2026-10-08 05:53'
labels:
  - reviewed
dependencies: []
ordinal: 42010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Saved Actions and Hide configurations retain numeric IDs from a previous connection/session, blocking the same monitors after IDs change. Live evidence: AW3425DW 2→1, S2721DGF 1→4, mirror source AW3423DW 5→2; UUID/vendor/model/serial unchanged. Separate durable settings identity from strict session transaction identity. Offline only; Secure Input is out of scope.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Existing saved Actions and Hide target/source configurations resolve uniquely matching stable identities despite numeric ID changes, preserving settings and action IDs.
- [x] #2 Missing, ambiguous or changed identities refuse with useful reasons; no writes occur on unsafe matches or post-capture connection changes.
- [x] #3 Recovery journals, pending requests, active removals and wake transactions retain strict session identity checks and are not rebound.
- [x] #4 Offline regression tests cover migration, exact reported ID remapping, current request IDs, refusal cases and transaction safety; documentation describes behavior.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Separate persisted references from live snapshots; resolve fresh target/source snapshots for new operations, preserving strict revalidation and recovery. Add focused fake-provider/writer tests, run project checks, independent safety review, commit and merge without touching TASK-51.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in session-owned worktree fix/saved-display-identity, receipt session 01a11375-64d5-7685-868e-debfdcee34a3, created from b50fe02. Independent reviewer found a no-op-to-write source rebind and an unnecessary nonzero serial restriction; reproduced both as failing fake-writer tests and corrected them. Matching remains unique UUID plus exact hardware fields; pending requests and recovery retain numeric IDs. Exact reported 2→1, 1→4, 5→2 fixture passes. Integrated current main including TASK-51, with unrelated working edits preserved exactly by merge autostash and diff comparison. Validation: 181 focused app/core tests passed after integration; both CLI/app builds passed. Final main check: 120 tests, 10 native UI skips, zero failures. LSP diagnostics unknown; compiler/test checks used. No hardware writes. Implementation 754a221, documentation 904bd0d; merged to main. No push.

Cleanup verified: Worktrunk removed the session-owned checkout and branch; post-remove hook closed the exact Herdr workspace w15. Only primary main remains. No retained task worktree/workspace.

Post-delivery review 2026-10-08 (independent reviewer, source inspection): no defects; AC1-4 verified against current sources, noting TASK-62's intentional skip of safely disconnected Action targets.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Saved Actions and Hide configurations now follow exact stable monitor identity across numeric ID changes; each operation captures current IDs and refuses mid-run rebinding. Legacy settings preserved, useful identity refusals added, and recovery journals unchanged. Independent safety findings fixed with red-to-green tests; exact user remap, migration, refusal and transaction regressions pass.
<!-- SECTION:FINAL_SUMMARY:END -->
