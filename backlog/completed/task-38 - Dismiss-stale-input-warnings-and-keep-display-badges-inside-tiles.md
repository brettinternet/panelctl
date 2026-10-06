---
id: TASK-38
title: Dismiss stale input warnings and keep display badges inside tiles
status: Done
assignee:
  - pi
created_date: '2026-10-05 23:14'
updated_date: '2026-10-05 23:20'
labels: []
dependencies: []
type: bug
ordinal: 28010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After a successful desktop Show with a failed DDC step, the retained warning has no acknowledgement action. Its orange badge is clipped above the monitor tile. User approved Dismiss for input warnings only, with no display commands or implication that the input was repaired; genuine recovery warnings remain non-dismissible.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Dismiss removes a completed input warning and badge without hardware actions, discarding input evidence, or clearing unresolved recovery warnings.
- [x] #2 Attention badge is fully visible within portrait and landscape display tiles; model tests and native rendered fixtures cover the changes.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add presentation-only dismissal to existing operation results with recovery/busy guards. 2. Add inline Dismiss and inset the existing badge. 3. Exercise model regressions and synthetic native Settings fixtures; run tests/builds and commit owned changes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Added presentation-only acknowledgement to DisplayOperationResult. Dismiss hides input warning, menu line, undo presentation and attention badge while preserving inputOutcome and partial script status. Model guards reject dismissal during operations or recovery and for failed desktop operations. Tests prove zero extra Show/Hide calls, unchanged evidence, case-insensitive acknowledgement, refresh persistence and recovery refusal. Native fake-backed screenshots visually checked at 680pt and 440pt, portrait and landscape, before/after dismissal: /tmp/panelctl-task38-fixtures and /tmp/panelctl-task38-narrow. Both warnings-as-errors builds and git diff --check pass; AppModel and preferences LSP clean, view diagnostics unknown. Full suite hit existing testNativeMenuArrowEventsReachShowAction popup/focus failures twice while concurrent TASK-39 activation-policy work landed; no third identical retry. Full run excluding that one native keyboard test passed (247 core + 151 app tests, four expected skips). Focused new native fixture passed at both widths. No hardware writes, no worktree, no changes to TASK-32/TASK-39.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added Dismiss for completed input warnings without hardware actions or evidence loss; recovery warnings stay non-dismissible. Inset the attention badge so portrait/landscape tiles no longer clip it. Model regressions and rendered native fixtures pass, both builds pass. Validation caveat: the existing native keyboard-menu test failed on popup/focus; the rest of the suite passes with that test explicitly excluded.
<!-- SECTION:FINAL_SUMMARY:END -->
