---
id: TASK-28
title: Update docs and screenshot for the redesigned app
status: Done
assignee: []
created_date: '2026-10-05 06:07'
updated_date: '2026-10-05 20:50'
labels:
  - docs
  - app
  - display-hide
dependencies:
  - TASK-24
  - TASK-25
  - TASK-26
  - TASK-27
references:
  - docs/display-hide-ux.md
  - docs/usage.md
  - README.md
  - docs/settings.png
priority: low
type: docs
ordinal: 18010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
docs/display-hide-ux.md describes the superseded flows: per-operation confirmations, the old Displays page layout and headless confirmation-required behavior. README and docs/usage.md show the old sidebar window and OLED wording. After the Settings redesign tasks the documentation must describe the shipped app so users and future agents are not misled.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 docs/display-hide-ux.md is rewritten as the current contract for Hide styles, the Experimental flag and consent, inline results, recovery presentation, scripting and the remaining safety boundaries, keeping still-valid coexistence and recovery rules.
- [x] #2 README and docs/usage.md describe the Displays, Automation and General tabs, Hide styles, the Experimental flag and Stream Deck or CLI usage; docs/settings.png shows the new Settings window.
- [x] #3 In-app Learn more links point at the updated documentation sections.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reconcile the UX contract, README and usage against shipped Settings, Hide/Show, scripting and recovery behavior. 2. Regenerate docs/settings.png using existing fake-backed native Settings fixtures; inspect the rendered tabs. 3. Point Learn more at the current experimental section, run focused app tests/build and local link checks, and perform one scoped review. 4. Commit implementation in task-28-docs, merge to main, record delivery evidence and release the claim, then remove the owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered as 965ae2a (Update app documentation and Settings screenshot), fast-forward merged to main. Reconciled the current per-display switch, Experimental consent/fallback, Black out lifecycle, removal recovery, inline results, automation coexistence and scripting. README and usage now describe all three tabs and Stream Deck commands without swallowing exit status. Learn more targets #experimental-features; the private qualification link remains valid. docs/settings.png is the existing native displays-setup fake fixture, explicitly captioned as synthetic, not hardware evidence.

Verification on 2026-10-05: 61 focused SettingsWindowTests/BlackoutHideTests/DisplayHideAppTests passed, including both snapshot generators. Visually inspected native Displays, Automation and General PNGs. Full swift test --disable-sandbox passed: 230 core and 142 app tests, four expected opt-in skips total. swift build --disable-sandbox --product PanelCtlApp -Xswiftc -warnings-as-errors passed. All 33 local links/fragments in the three edited docs and app documentation URLs resolved; git diff --check passed. LSP diagnostics were unknown (bounded report timeout); compiler checks passed. One direct scoped review against shipped controls and fake-backed behavior found no remaining item-scoped defects. No live display writes or app launches.

Cleanup: verified session receipt for task-28-docs (session 01a10dcf-45f3-7226-b088-b7b3eda9a1d6), clean worktree at merged commit, and its single idle shell pane. Worktrunk removed the worktree and branch; verified its Herdr workspace w25 disappeared. Existing recovery-enable worktree was not owned by this task and remains untouched. No blocker or next resumable implementation step; claim released. No push.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Updated the current Hide/Show contract, README, usage, native Settings screenshot and experimental Learn more anchor. Verified with native fake fixtures, 61 focused tests, the full 372-test offline suite (4 expected skips), warnings-as-errors app build and 33 local link checks. Implementation 965ae2a merged to main; owned worktree, branch and workspace removed.
<!-- SECTION:FINAL_SUMMARY:END -->
