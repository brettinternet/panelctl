---
id: TASK-41
title: Preserve hidden display intent through sleep and expose guarded recovery
status: Done
assignee:
  - '@agent'
created_date: '2026-10-06 06:33'
updated_date: '2026-10-06 13:45'
labels: []
dependencies: []
ordinal: 31010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Display or system sleep leaves public-mirror hidden displays needing recovery with only Check Again in Settings. Users need safe continuity and in-app recovery rather than CLI-only guidance; disclosure labels must be clickable.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Sleep and wake preserve or safely reconcile public-mirror hide intent without relaxing identity checks or invoking private disconnect
- [x] #2 Settings offers guarded restoration for recoverable removal failures and actionable fallback guidance
- [x] #3 Disclosure labels and carets both toggle accessibly
- [x] #4 Fake-backed regression tests and documentation cover sleep, recovery and disclosure behavior
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Investigate public-mirror session reconciliation across display/system sleep, preserving strict identity and avoiding any private setter or automatic DDC writes. 2. Preserve in-process hidden intent across lifecycle transitions with guarded, bounded wake reconciliation; expose explicit safe recovery through existing Show/backend paths and manual fallback when refused. 3. Make all native disclosure labels keyboard-accessible full-row controls using a shared style if needed. 4. Add fake-backed core/model regressions and native Settings fixtures, update docs, run focused/full checks and independent safety review. 5. Commit only task changes and integrate without disturbing TASK-35.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation committed as 20366cc on sleep-hide-recovery; retained isolated checkout .worktrees/sleep-hide-recovery because primary main has concurrent overlapping AppModel/ExperimentalDisconnect edits. Creation receipt: .git/worktrees/sleep-hide-recovery/agent-creation.json. Review passed after fixing volatile timestamp fingerprints, sleep-during-settlement and locked writer-boundary expectations. 84 focused core/app tests pass; both products build. Parent ran full swift test excluding the reproducibly failing existing consent-key-window test; app suite passed 189 tests with 3 skips. Synthetic wake-reset screenshot shows Restore. No hardware writes or real app launch. AC3 remains unchecked: full-row native Button implemented, but mouse/keyboard test skips because AppKit fixture cannot become key/expose SwiftUI accessibility. Resume condition: native label/caret/keyboard interaction verification in working GUI test environment. Integration into main also pending reconciliation of concurrent edits; git apply --check passed without modifying main.

Integrated into main as a316c01 at user request, applying only this patch to index/worktree. Compared before/after unrelated diffs: only index hashes and hunk line offsets changed; unrelated work preserved. Integrated focused checks (DisplayHideTests, DisplayHideAppTests, DisplayDisconnectIntegrationTests) pass, including 74 app tests. Native disclosure verification remains outstanding, so TASK-41 stays In Progress. Isolated checkout retained: Herdr workbench layout inspection failed because enabled plugin was not found; no workspace or checkout cleanup attempted without pane inspection.

User confirmed the outstanding native GUI verification: "I verified, it looks good." This closes the remaining disclosure-interaction acceptance gate; prior automated test-environment limitations remain recorded above.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Delivered guarded session-only public-mirror sleep/wake resume, in-app Restore and manual recovery guidance, and full-row accessible disclosures in a316c01. Focused fake-backed tests, product builds and independent safety review passed; user manual GUI verification closes the final criterion. No agent-run live display writes. Retained isolated worktree because Herdr pane inspection was unavailable.
<!-- SECTION:FINAL_SUMMARY:END -->
