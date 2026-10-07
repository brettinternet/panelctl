---
id: TASK-59
title: Fix status stream CI failure
status: Done
assignee:
  - '@pi'
created_date: '2026-10-07 14:18'
updated_date: '2026-10-07 14:41'
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
- [x] #2 Main CI passes with the fix.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce cooperative-pool starvation with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1. 2. Move blocking socket test clients to DispatchQueue via async continuations, preserving all assertions. 3. Run focused normal and strict-pool tests and compiler checks; push and verify main CI before patch release.

4. CI exposed a second test race: a synchronous main-actor read after a 5ms sleep can block the publisher. Await the healthy-client read on the blocking-I/O queue instead, with a 20ms coalescing interval to exercise the removed timing assumption.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause: Task.detached uses the cooperative executor; blocking long-lived socket clients starve server tasks on constrained runners. Original focused test passed normally but hung beyond 20 seconds with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1; its owned hung XCTest process was terminated. After dispatch-backed continuations, all six AppStatusStreamTests pass both normally and with the strict pool. Warnings-as-errors build and release-version script pass. LSP returned unknown; compiler validation is clean. Awaiting main CI.

Run 37635923659 passed the original regression but failed the slow-consumer test with two read timeouts. Removed the sleep-before-blocking-read race; all six strict-pool tests and warnings-as-errors build pass locally.

Main CI passed for release commit b9ff4446450e2cd1a67e3d1332ccce2f80ca40c6: https://github.com/brettinternet/panelctl/actions/runs/37636659334 . Local stream tests passed with strict cooperative pool; compiler warnings-as-errors, 25 CLI parser tests, release version policy and diff checks passed. Source LSP diagnostics clean after final edits.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed status-stream test cooperative-pool starvation and a main-actor blocking-read race without changing production behavior. Preserved stream assertions and exercised a longer coalescing interval. Verified focused tests, strict-pool tests and green main CI run 37636659334; fixes and v0.6.2 bump pushed.
<!-- SECTION:FINAL_SUMMARY:END -->
