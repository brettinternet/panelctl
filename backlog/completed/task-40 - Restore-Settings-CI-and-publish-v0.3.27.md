---
id: TASK-40
title: Restore Settings CI and publish v0.4.0
status: Done
assignee:
  - '@agent'
created_date: '2026-10-06 03:48'
updated_date: '2026-10-06 17:34'
labels:
  - reviewed
dependencies: []
ordinal: 30010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Main CI fails in native Settings fixtures on macOS 15, blocking the requested release. Keep hardware untouched and preserve active TASK-34 changes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Settings tests and main CI pass without weakening consent coverage
- [x] #2 v0.4.0 release publishes universal app and CLI archives with checksums
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Diagnose macOS 15 Settings fixture failures and fix native-control lookup/presentation synchronization. 2. Run focused and full offline checks; bump version to 0.4.0 as requested. 3. Commit only release-owned changes, push main, wait for green CI, push release tag and verify assets.

4. Consolidate competing parent/child SwiftUI alerts into one Settings presenter for macOS 15, preserving notice identity and cancellation; native tests also exercise ordinary notice dismissal.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Local warnings-as-errors build, full offline Swift suite, CLI/app builds and release-version policy pass. Native fixtures now wait for the General controls and selected Displays binding instead of reading after fixed delays. Remote macOS 15 validation remains required; no hardware writes.

The tag run exposed an intermittent macOS 15 consent failure despite green main CI. Diagnostics showed pending consent with no key window. Activation alone also failed; reusing the existing DisplayHideAppTests AppKit event-dispatch pattern makes the fixture key and drives sheets without promoting XCTest into the Dock. Local focused/full suites and warnings-as-errors build pass. User approved moving the unpublished v0.4.0 tag after corrected CI passes.

Event dispatch yielded a key window on remote macOS 15 but consent still remained pending, isolating the competing SwiftUI alert presenters rather than activation as the remaining issue. Consolidated the production presenter. Local full suite passed (an unrelated native-menu test first failed, then passed in focused and full reruns).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Published v0.4.0 with universal app/CLI archives and SHA-256 files. Main CI 37412445721 and release CI 37412649619 passed on macOS 15; downloaded assets passed checksum and ZIP integrity validation. Local warnings-as-errors build, full suite and product/version checks passed. Consolidated Settings consent and notices into one presenter and synchronized native fixtures. Existing TASK-34 edits remain untouched.
<!-- SECTION:FINAL_SUMMARY:END -->
