---
id: TASK-53
title: Make interactive native UI tests opt-in
status: Done
assignee:
  - '@agent'
created_date: '2026-10-06 23:16'
updated_date: '2026-10-06 23:18'
labels: []
dependencies: []
type: chore
ordinal: 43010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Default test runs currently open native Settings windows, menus and consent sheets, disrupting the user and causing focus-sensitive failures. Keep fake-backed model coverage default while requiring explicit opt-in for interactive fixtures, and guide agents to focused checks.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Plain Swift tests skip tests that present native windows, menus or sheets unless explicitly opted in; noninteractive model coverage still runs.
- [x] #2 Document focused test selection and explicit interactive opt-in; CI retains intended interactive coverage explicitly.
- [x] #3 Verify the default gating and relevant model coverage without presenting UI.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit visible AppKit test entry points. 2. Add a shared app-test opt-in guard using XCTSkip and apply it before UI setup. 3. Keep CI UI coverage explicit and document focused agent checks. 4. Run default-mode gating/model tests only.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Audited direct window presentation and indirect reopen/menu/modal paths. Added requireInteractiveUI guard before setup to 29 tests across five app test files; kept non-presenting Settings/model/menu-structure tests enabled. Core live-blackout test retains its separate existing opt-in. CI explicitly sets PANELCTL_TEST_INTERACTIVE_UI=1; fixture-output variables alone do not enable native UI. AGENTS.md now requires focused filtering and user approval before desktop interaction.

Validation: one filtered default-mode run selected all 29 guarded tests plus the guard unit tests and relevant noninteractive model checks: 38 selected, 29 skipped, 9 passed, zero failures. Tested explicit opt-in semantics through injected environment dictionaries without showing UI. No interactive tests or full suite run. git diff --check passes. LSP diagnostics unknown due bounded wait. TASK-52 and unrelated work left untouched.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Native window/menu/sheet tests now skip by default unless PANELCTL_TEST_INTERACTIVE_UI=1. Model tests remain default, CI retains explicit UI coverage, and agent/development instructions require the smallest relevant test selection. Verified 29 UI skips and 9 noninteractive passes without presenting UI.
<!-- SECTION:FINAL_SUMMARY:END -->
