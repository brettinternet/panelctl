---
id: TASK-37
title: Return to the Mac input when the current DDC input is unreadable
status: Done
assignee:
  - pi
created_date: '2026-10-05 23:05'
updated_date: '2026-10-05 23:11'
labels: []
dependencies: []
type: bug
ordinal: 27010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
DELL S2721DGF Show restored topology after Hide selected empty HDMI 1, but a malformed Get VCP reply caused PanelCtl to skip Set VCP entirely. A known return input should not depend on reading the inactive input. Hardware responsiveness remains unqualified; offline tests only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Show/back attempts at most one known return-input write after a failed current-input read, without weakening identity or topology checks; Hide and standalone selection still require a readable original.
- [x] #2 Fake tests cover return success, unavailable readback, failed write, and unchanged safety refusals; docs distinguish hardware limitations from the pre-read gate.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce the malformed pre-read with fake channels. 2. Permit unknown original input only for explicit Show/back, preserving strict Hide/standalone behavior, exact identity validation, one write and bounded readback. 3. Add regressions and document limitations; run offline tests/builds and commit only owned changes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Reproduced screenshot mechanism offline: testShowAttemptsKnownReturnInputWhenPreReadIsMalformed failed before patch (skipped, restore/read only, zero writes) and passes after patch. Show/back now permits unknown original after failed pre-read; optional original avoids inventing recovery input. Zero input and unavailable channel still skip. Hide/standalone read-first and identity checks unchanged. Focused 46 tests passed. Full warnings-as-errors suite passed: 247 core + 150 app tests, four expected skips. Both panelctl and PanelCtlApp warnings-as-errors builds and git diff --check passed. LSP DisplayHandoff clean; DDC diagnostic unknown, compiler evidence used. Independent verifier a8f68638-eab2-415b-a578-76387e9c586b pending. No hardware writes or live trials. User requested commit; unrelated dirty TASK-32 must remain untouched.

Independent verifier passed: 15 DDC tests and 19 mirroring tests, identity/topology guards, one-write behavior, honest unknown-original outcomes, and unchanged Hide/standalone read-first behavior. Hardware acceptance remains unqualified. Delivery is the scoped commit containing this task and its source/tests/docs; no worktree created.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Removed the failed-pre-read gate only for explicit journal-backed Show/back. A known return input is attempted once after restoration and identity checks; no previous input is guessed. Regression reproduced before fix, 397 tests completed with four expected skips and no failures, both warnings-as-errors builds passed, and independent verification passed. No live hardware writes or qualification.
<!-- SECTION:FINAL_SUMMARY:END -->
