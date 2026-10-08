---
id: TASK-73
title: Polish recent window and automation UI
status: Done
assignee: []
created_date: '2026-10-08 06:02'
updated_date: '2026-10-08 06:09'
labels: []
dependencies: []
type: enhancement
ordinal: 61010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Review recent Move windows, keep-windows-off and Run now surfaces against existing Settings/menu conventions. Current copy exposes implementation details, and Displays has no direct Accessibility permission control for its keep-off option.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Recent Settings descriptions are concise, preserve key limits, and use consistent action and destination wording.
- [x] #2 Keep-off users can reach the explicit Accessibility permission action from Displays without automatic prompts; the existing Actions control stays consistent.
- [x] #3 Approved fake-backed native UI checks and focused regression tests pass; rendered layouts are reviewed and fixes committed.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Inspect recent UI and existing fixtures. 2. Tighten copy and reuse the existing permission control in Displays; preserve all execution behavior. 3. Validate narrow fake-backed Settings/editor/menu flows and review screenshots, run affected model tests/build, then commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered in 9966224 on main. Reviewed recent Move windows, keep-off, Run now/menu and rule command surfaces. Shortened descriptions, unified Move to labels, renamed the Windows section, reused the existing explicit Accessibility action beside enabled keep-off, and updated docs. Execution behavior is unchanged. User approved fake-backed native UI-only tests; no real permission prompt, AX window move or display write occurred.

Verification: five narrow SettingsWindowTests passed (Move editor save, keep-off toggle/destination/menu status, shared permission fixture, Run menu and automation snapshots); refreshed the permission fixture again after final copy changes. Visually reviewed .build/ui-pass-after PNGs at 440/680 widths, missing/stale/granted permission, Automatic/specific destination, and rule command/active-rule layouts. SwiftUI does not expose this button as NSButton: test validates rendered snapshots and invokes the bound model action with a counting fake provider, not a native click. Initial snapshot-directory and NSButton harness failures were corrected. Focused WindowRelocationTests (36) and ProtectionRuleRunOnceTests (21) passed; swift build --disable-sandbox and git diff --check passed. A regression caught existing text-based refusal classification; final concise copy preserves its keywords and the test now covers both missing and stale permission. LSP was clean where reported; DisplaySettingsView returned unknown, so compiler/tests are the validation evidence. No worktree, push or PR.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Committed UI polish as 9966224: concise descriptions, consistent destination labels, and Accessibility setup beside keep-off in Displays. Five native UI tests with reviewed snapshots, 57 focused regressions, and build pass; no hardware or real window changes.
<!-- SECTION:FINAL_SUMMARY:END -->
