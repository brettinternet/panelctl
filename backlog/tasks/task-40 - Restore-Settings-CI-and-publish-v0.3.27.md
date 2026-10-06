---
id: TASK-40
title: Restore Settings CI and publish v0.4.0
status: In Progress
assignee:
  - '@agent'
created_date: '2026-10-06 03:48'
updated_date: '2026-10-06 03:53'
labels: []
dependencies: []
ordinal: 30010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Main CI fails in native Settings fixtures on macOS 15, blocking the requested release. Keep hardware untouched and preserve active TASK-34 changes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Settings tests and main CI pass without weakening consent coverage
- [ ] #2 v0.4.0 release publishes universal app and CLI archives with checksums
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Diagnose macOS 15 Settings fixture failures and fix native-control lookup/presentation synchronization. 2. Run focused and full offline checks; bump version to 0.4.0 as requested. 3. Commit only release-owned changes, push main, wait for green CI, push release tag and verify assets.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Local warnings-as-errors build, full offline Swift suite, CLI/app builds and release-version policy pass. Native fixtures now wait for the General controls and selected Displays binding instead of reading after fixed delays. Remote macOS 15 validation remains required; no hardware writes.
<!-- SECTION:NOTES:END -->
