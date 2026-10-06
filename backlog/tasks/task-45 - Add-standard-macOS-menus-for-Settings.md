---
id: TASK-45
title: Add standard macOS menus for Settings
status: Done
assignee:
  - '@agent'
created_date: '2026-10-06 17:27'
updated_date: '2026-10-06 17:32'
labels: []
dependencies: []
ordinal: 35010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Settings currently exposes only PanelCtl and File, leaving native editing and window commands undiscoverable.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Main menu exposes standard app and editing commands, Minimize, and GitHub under Help without unsupported Zoom.
- [x] #2 Native tests exercise editing through menu keyboard shortcuts and preserve Close Window behavior.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Extend the existing AppKit main menu using responder-chain actions; add focused native menu tests; run Swift tests; commit and merge from an isolated worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in ebc8111 and merged to main. Full swift test --disable-sandbox passed again after rebasing onto concurrent main changes. MainMenuTests checks menu structure, modifiers, nil responder-chain targets, and dispatches shortcut-selected actions to real NSTextView/NSWindow responders for select/copy/cut/undo/redo/paste/minimize. XCTest could not become the key app, so dispatch uses explicit native responders rather than claiming end-to-end keyboard-event coverage. Existing Settings lifetime/Close Window test passed. Zoom omitted because Settings disables its zoom button. No hardware writes. LSP diagnostics were unavailable (timeout); Swift compilation passed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added About and Hide commands, native Edit commands, Window > Minimize, and Help > View on GitHub. Full Swift suite and focused native menu tests pass; merged as ebc8111.
<!-- SECTION:FINAL_SUMMARY:END -->
