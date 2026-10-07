---
id: TASK-60
title: Allow Run now with verified hidden displays
status: Done
assignee:
  - '@pi'
created_date: '2026-10-07 20:19'
updated_date: '2026-10-07 20:28'
labels: []
dependencies: []
ordinal: 49010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Run now rejects successful Hide journals as recovery while timed automation safely covers the verified remaining mirror source.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Run now safely covers verified remaining sources without changing saved preferences or hidden displays.
- [x] #2 Unverified recovery and identity mismatches still refuse without launching helpers; timer scheduling remains intact.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Reuse hidden mirror argument validation for one-shot execution; add fake-backed acceptance and refusal tests; run focused suites and independent safety review; commit, merge main and clean owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented one-shot removal-session overlays using existing verified source and remaining-display selection. Focused suites passed: 195 tests, 10 interactive tests skipped, 0 failures (185 executed without skip). Fake helper verifies timer rearming, disabled and snoozed behavior, bounded Restore replacing Sleep/dimming, until-activity cap, recovery and identity refusal. No live hardware/UI actions. LSP diagnostic status unknown; Swift compilation passed. Independent safety review pending before commit/merge.

Independent review found and prompted fixes for two lifecycle gaps: removal-session one-shots now revalidate authorization on every cycle tick, and effective one-shot mode is tracked with coordinator ownership for Escape focus even for disabled/snoozed Dim rules. Actual-cycle fake-coverage revocation test and fake-focus Escape tests pass. Final focused checks: 232 tests total, 10 interactive skipped, 0 failures (222 passed); all five changed source files have clean LSP diagnostics. Review follow-up pending.

Follow-up independent safety review PASS; both findings resolved with no validated new defects. Committed fix as 76aded2. Integrated concurrent main commit 927e79a in the worktree and reran all nine focused suites: 222 passed, 10 interactive skipped, 0 failures. Merged locally to main; no push, hardware writes or native UI trials.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Run now uses verified hidden-display overlays, preserves timer/preferences, revalidates ongoing authorization, and keeps Escape focus for converted Dim rules. Verified with nine focused Swift suites (222 passed, 10 interactive skipped), clean source diagnostics, and independent safety review. Fix commit 76aded2 merged locally to main.
<!-- SECTION:FINAL_SUMMARY:END -->
