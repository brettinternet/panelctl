---
id: TASK-76
title: Preserve mirror-hide intent across wake layout drift
status: Done
assignee:
  - '@agent'
created_date: '2026-10-09 05:27'
updated_date: '2026-10-09 05:36'
labels: []
dependencies: []
ordinal: 64010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Recurrence on 0.7.0: display-only wake at 2026-10-08 22:52:46 loses two mirrors; AW3425DW returns as main at 22:52:55 and shifts other displays. Existing wake resume only accepts the exact restored baseline. TASK-58 fixed explicit Show, not wake preservation. Evidence retained in debug/wake-20261008. User requests investigation, fix and commit; no live display writes authorized.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Wake restores the previously hidden display set despite observed layout drift when exact identity and transaction checks permit it, without DDC input replay.
- [x] #2 Retain the original layout baseline and refuse changed identities, changed journals and unrelated topology; preserve recovery on failure.
- [x] #3 Focused fake-backed regressions, independent safety review and documentation establish behavior and remaining hardware limits.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce recorded lost mirrors, wrong main/layout and delayed target return with fake-backed existing app/core fixtures. 2. Retain sleep intent through a bounded readiness window; permit one atomic public-mirror resume of the captured removal set from layout drift, preserving the immutable baseline and refusing identity/journal/unrelated-mirror changes. Restore visible origins/main without selecting missing target modes or replaying DDC. 3. Extend focused regression and transaction-boundary checks, document limitations, obtain independent safety review, finalize and commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Investigation: live logs show successful two-target mirrors at 21:53, display wake 22:52:46 with AW3425DW inactive, then its active/main return at 22:52:55 with shifted desktops. No PanelCtl configuration commit at wake. App previously consumed intent after a one-second settle and required the exact restored baseline; core required saved target modes before another Hide. Implemented a bounded 15-second readiness window and one atomic public-mirror/layout transaction for the pre-sleep removal set when topology drift is otherwise safe. Original journal, baseline and removal IDs stay intact. No DDC, private setter, mode approximation or permanent configuration. Missing Show modes no longer invalidate verified hidden intent. Failed/interrupted wake transactions cannot be cleared by weaker mirror-only inspection.

Verification: swift test --disable-sandbox --filter DisplayHideTests|DisplayMirroringTests|DisplayHideAppTests passed 127 selected tests (117 runnable, 10 native-UI skipped); subsequently added deadline regression passed separately, total 118 runnable checks. Four-display app/core test models inactive target, delayed return, wrong main, shifted visible desktop and unavailable saved target mode; verifies one mirror transaction, visible origins, hidden observations, preserved baseline/removal IDs, zero DDC and no duplicate replay. Core regression covers changed identity, external mirror, visible mode, stale journal, journal-after-begin, topology-after-stage, consumed commit failure, wrong visible mode/origin after commit and interrupted verification. Existing sleep, explicit Show cancellation, baseline/ID refusal and mirror suites pass. LSP diagnostics unknown; compiler/tests provide validation. git diff --check clean.

Independent safety reviewer 9b8aacf2-fdb5-44af-a54c-19ab7c07345f found the weaker inspection postcondition issue; corrected and exercised it. Final review PASS, no remaining validated findings; artifact /Users/brett/.pi/agent/sessions/--Users-brett-dev-me-panelctl--/subagent-artifacts/outputs/9b8aacf2-fdb5-44af-a54c-19ab7c07345f/wake-safety-review.md. Evidence/logs retained ignored in debug/wake-20261008. Live monitor acceptance of the public mirror/origin transaction and 15-second window are not hardware-validated; no installation, UI presentation, live display write or push performed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Preserve verified pre-sleep mirror-hide intent through delayed wake, then repair owned mirror loss and visible layout drift atomically without DDC or restoring unavailable follower modes. Keep exact identities, original baseline, one-write budget and failed recovery evidence. 118 runnable focused checks passed, 10 interactive tests skipped; independent safety review passed. Hardware behavior remains an explicit live-validation limit.
<!-- SECTION:FINAL_SUMMARY:END -->
