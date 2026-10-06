---
id: TASK-47
title: Continue safe blackout on remaining displays
status: Done
assignee:
  - '@pi'
created_date: '2026-10-06 20:12'
updated_date: '2026-10-06 21:25'
labels:
  - reviewed
dependencies: []
ordinal: 37010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A rule containing an intentionally removed or unavailable monitor currently pauses protection on its other monitors. Continue independent safe blackout without weakening identity or recovery safety; do not require users to split rules.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Safe blackout continues on eligible remaining targets, with skipped displays explained and returning targets revalidated
- [x] #2 Ambiguous recovery, Full disconnect, failed cleanup and unsafe topology-changing operations remain blocked
- [x] #3 Unsafe sleep follow-up is suppressed independently of safe blackout, with truthful status and timers
- [x] #4 Offline regression tests and relevant build checks pass; changes committed and merged to main
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend existing verified hidden-mirror overlay eligibility to safe remaining targets without relaxing recovery guards. 2. Skip unavailable targets and expose partial execution; keep unsafe sleep separate and truthful. 3. Add offline regression tests, obtain safety review, run build/tests, commit and integrate while preserving main work. 4. Record delivery and clean up owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented partial safe blackout using the existing bounded overlay path. Added a removal-session marker and whole-session helper revalidation after independent review found that ordinary-only overlays also need journal monitoring. Mirror-source identity checks, recovery/Full-disconnect/cleanup gates preserved. Sleep is replaced by finite overlay restoration during verified removal; rule status/timers explain it. Full offline suite and both product builds pass; release-version checks pass. Native automation fixtures rendered and inspected at 440 and 680 points; no live hardware writes. Independent reviewer passed corrected implementation. Delivery integration pending.

Delivered code commit 6e19b07 by fast-forward merge into main. Final offline suite: 285 core tests and 237 app tests, 7 expected skips, 0 failures; both product builds and release-version script passed. Review correction independently accepted in run 7c5d3a77-42e2-40e3-a5cf-6ff471909cab. Owned worktree .worktrees/automation-remaining-displays (creation receipt session 01a112d5-f4be-704e-95f6-2de35357a302, base d0de5fd) and branch removed by Worktrunk after verifying receipt and clean merged checkout. Herdr workspace w2S contained only its idle shell and was closed by post-remove hook; workspace_not_found verified. Unrelated TASK-46 backlog edits and multi-step-actions worktree preserved. No push or live hardware trial.

Review: fixed skipped-display count for All displays rules with stale saved selections (regression case added), duplicate --panelctl-removal-session-overlay now rejected, doc paragraph split. Commit 1fd22b4; full warnings-as-errors suite (285 core, 237 app), both builds and release-version check passed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Safe blackout continues on eligible remaining monitors and reports skipped targets. Verified removal sessions use bounded window-only overlays; unsafe sleep restores the overlay instead. Exact identities, whole-session journal revalidation, recovery and Full-disconnect/cleanup blocks remain enforced. Offline tests, builds, native UI fixtures and independent safety review passed. Code merged to main as 6e19b07; task worktree, branch and workspace cleaned up.
<!-- SECTION:FINAL_SUMMARY:END -->
