---
id: TASK-62
title: Skip safely unavailable display Action steps
status: Done
assignee:
  - '@agent'
created_date: '2026-10-07 22:18'
updated_date: '2026-10-07 22:25'
labels: []
dependencies: []
ordinal: 51010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OLED blackout is disabled when a target is already removed from the desktop, preventing work on available displays. User approved resilient ordered actions without bypassing identity or recovery safety.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Verified hidden and disconnected targets skip with visible reasons; available steps execute in order
- [x] #2 Ambiguous identity, unresolved recovery and unsafe operations still block; unexpected failures stop execution
- [x] #3 All skipped actions report Nothing to do; regression tests and documentation cover behavior
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Share safe skip classification across readiness and preflight, retaining global and identity gates. 2. Freeze skips, report per-step reasons and nothing-to-do results without writes. 3. Add focused fake-backed regressions, update UI/help, independently review safety, and commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented shared safe-skip classification for readiness/preflight and frozen per-step skip results. Verified removal and actual blackout coverage are required; identity ambiguity, recovery, stale setup and last-visible guards remain. Independent safety review found recovery discovered after preflight was mislabeled; corrected to recovery-needed with preserved reason and a regression. Final validation: swift test --disable-sandbox --filter DisplayActionAppTests|AppControlTests|AppControlServerTests (quoted filter at execution), 80 tests passed; git diff --check clean; affected source/test LSP diagnostics clean. Fake writers only; no hardware writes or native desktop interaction. UI skip labels compiled but not visually exercised.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Actions now continue on available displays and visibly report safely skipped targets; no eligible work reports Nothing to do. Added skip, coverage loss, reconnect, recovery and safety regressions; 80 focused tests pass. Updated UI and CLI/documentation. Independent review finding fixed.
<!-- SECTION:FINAL_SUMMARY:END -->
