---
id: TASK-68
title: Allow guarded input return to inactive online displays
status: Done
assignee:
  - '@pi'
created_date: '2026-10-07 23:42'
updated_date: '2026-10-07 23:44'
labels: []
dependencies: []
type: bug
ordinal: 56010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hide makes mirror followers inactive. Show opens DDC before restoring topology, but the active-only DDC resolver rejects them before communication. User observed skipped input return on AW3425DW and DELL S2721DGF. Offline validation only; no hardware writes authorized.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Explicit input return accepts an identity-verified online inactive target while ordinary DDC operations still refuse it.
- [x] #2 Missing, offline, builtin, duplicate and changed identities remain refused; regression coverage exercises the production resolver from handoff.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Thread a return-only inactive-target allowance through the existing DDC opener. 2. Add resolver safety tests and a handoff regression using the real resolver with fake transport. 3. Run focused core tests and commit only task-owned files.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Input return alone passes allowInactive to the shared resolver; online, unique UUID/ID, external-target, captured identity and connector checks remain intact. Ordinary input/luminance/power callers retain the active-only default. Updated handoff fixtures exercise the production resolver rather than bypassing it. Verification: swift test --disable-sandbox --filter DDCPowerTests|DisplayMirroringTests|DisplayHideTests (quoted filter): 64 tests passed. Build succeeded and git diff --check passed. LSP clean for five affected Swift files; DisplayHandoff diagnostic report timed out, compiler succeeded. No live monitor writes or native UI tests; hardware acceptance on another input remains unqualified.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed guarded Show/Back input return being rejected solely because a connected mirror follower is inactive. Regression coverage verifies input-before-unmirror ordering and preserved safety refusals; 64 focused core tests passed. No deployment or hardware trial performed.
<!-- SECTION:FINAL_SUMMARY:END -->
