---
id: TASK-59
title: Fix status stream CI failure
status: In Progress
assignee:
  - '@pi'
created_date: '2026-10-07 14:18'
updated_date: '2026-10-07 14:20'
labels: []
dependencies: []
ordinal: 48010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Main CI runs 37569782035 and 37569744499 fail after status streaming landed. Diagnose and fix the control response failure before the requested patch release.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Concurrent status watchers do not prevent one-shot status commands from completing, with regression coverage.
- [ ] #2 Main CI passes with the fix.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce cooperative-pool starvation with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1. 2. Move blocking socket test clients to DispatchQueue via async continuations, preserving all assertions. 3. Run focused normal and strict-pool tests and compiler checks; push and verify main CI before patch release.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause: Task.detached uses the cooperative executor; blocking long-lived socket clients starve server tasks on constrained runners. Original focused test passed normally but hung beyond 20 seconds with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1; its owned hung XCTest process was terminated. After dispatch-backed continuations, all six AppStatusStreamTests pass both normally and with the strict pool. Warnings-as-errors build and release-version script pass. LSP returned unknown; compiler validation is clean. Awaiting main CI.
<!-- SECTION:NOTES:END -->
