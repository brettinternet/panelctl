---
id: TASK-49
title: Include hidden displays in Automation editors
status: Done
assignee:
  - '@pi'
created_date: '2026-10-06 21:45'
updated_date: '2026-10-06 21:49'
labels: []
dependencies: []
ordinal: 39010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Users cannot configure future actions or rules for monitors removed from the desktop because editors only list active displays. Selection must not show a hidden monitor or weaken execution safety.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Action and rule editors include hidden monitors after visible monitors and label them Hidden.
- [x] #2 Saving hidden monitor selections preserves their UUIDs without showing them; existing runtime safety remains unchanged.
- [x] #3 Focused regression tests and app build pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Use a shared editor-only display inventory including hidden display records, ordered after visible displays and labeled Hidden. Update action defaults and unavailable-rule selections to use it. Leave runtime eligibility unchanged. Add fake-backed selection/save and native editor regression tests; run tests and build, then commit.
<!-- SECTION:PLAN:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Both Automation editors now use existing display tiles, include hidden monitors last with a Hidden label, and retain journaled targets even when absent from inventory. UUID-backed drafts and saves do not show monitors; runtime eligibility is unchanged. Verified with fake-backed inactive/disconnected/blackout regressions, native Action and Rule editor Cancel/Save tests, full swift test --disable-sandbox (zero failures; opt-in/accessibility skips), swift build --product PanelCtlApp, and git diff --check. No hardware writes performed.
<!-- SECTION:FINAL_SUMMARY:END -->
