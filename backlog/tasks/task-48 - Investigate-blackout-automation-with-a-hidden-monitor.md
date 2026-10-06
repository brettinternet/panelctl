---
id: TASK-48
title: Investigate blackout automation with a hidden monitor
status: Done
assignee:
  - '@pi'
created_date: '2026-10-06 21:03'
updated_date: '2026-10-06 21:16'
labels: []
dependencies: []
ordinal: 38010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
User reports the remaining monitor does not black out after TASK-47 while another selected monitor is hidden. Diagnose using read-only runtime evidence and offline reproduction; preserve live display state.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Record runtime evidence and user verification of the reported idle blackout behavior
- [x] #2 If a defect is reproduced, cover and commit a focused fix; otherwise document the no-change outcome
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Inspect live configuration, helper arguments and countdown without changing displays; observe user idle reproduction and record the outcome. Apply a fix only if a defect is reproduced.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Read-only inspection found OLED protection running against the remaining Dell AW3423DW, with the hidden selected target excluded. Rule idle threshold is 300 seconds; app status decreased from 300 to 286 to 252. User left the Mac idle and explicitly confirmed: "ok it works". No failing mechanism established, no source edits, no tests needed for code changes, and no fix to commit. Read-only watch cancelled after confirmation. Unrelated TASK-46 changes preserved.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
No defect reproduced. Read-only inspection verified the running remaining-display helper and decreasing five-minute idle timer; user confirmed blackout works after leaving the Mac idle. No source changes or fix commit. Observation watch stopped.
<!-- SECTION:FINAL_SUMMARY:END -->
