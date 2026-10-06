---
id: TASK-50
title: Continue Actions across their own display changes
status: Done
assignee:
  - '@agent'
created_date: '2026-10-06 22:38'
updated_date: '2026-10-06 22:47'
labels: []
dependencies: []
type: bug
ordinal: 40010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Remove and Show can trigger screen-parameter notifications that abort their own Action after a successful step. Successful input details also incorrectly show warning icons.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Verified Remove and Show steps continue through expected configuration notifications; real lifecycle interruptions and unsafe fresh state still stop execution without rollback.
- [x] #2 Successful steps and verified input details are not warnings; interruptions explain why execution stopped.
- [x] #3 Fake-backed regression tests and native result fixtures pass without hardware writes.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Reproduce notifications in fake Remove/Show tests; separate expected operation notifications from lifecycle cancellation while retaining fresh safety checks. Correct step warning classification and interruption summaries. Run offline checks and native fixtures, obtain focused safety review, then commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Reproduced original failure with injected screen-parameter notifications: successful Hide and Show returned [done, notRun] before the fix. Scoped notification deferral to the Action-owned topology writer; late notifications matching the latest observed inventory are harmless, while changed inventory and sleep/wake/session lifecycle still interrupt. Existing per-step identity/recovery validation and stop-on-failure remain. Fixed interruption summary and final-step success consistency. Independent safety review 40233959-aaac-487c-bf42-bffbbdd92257 found an omitted-input warning styling case, corrected and regression-tested; its delayed-notification concern is covered by matching-inventory and changed-inventory regressions. Full warnings-as-errors suite: 286 core + 269 app tests, 7 expected skips, zero failures. App warnings-as-errors build passed. 44 focused Action tests passed; native Action fixtures rendered and success PNGs inspected at 440/680 points in /tmp/panelctl-task50-fixtures. Evidence logs: /tmp/panelctl-task50-{repro,focused,full,fixtures,build}.log. LSP diagnostics unknown (bounded timeout); compiler/tests authoritative. No live topology, DDC or private API writes; actual hardware notification timing remains unqualified.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Actions continue after their own verified display changes; genuine failures and interruptions still stop later steps without rollback. Successful input details no longer display warnings, omitted-input warnings remain, and interruption messages explain the stop. Verified with 555 offline tests (7 skips), native 440/680 fixtures, warnings-as-errors app build and focused safety review.
<!-- SECTION:FINAL_SUMMARY:END -->
