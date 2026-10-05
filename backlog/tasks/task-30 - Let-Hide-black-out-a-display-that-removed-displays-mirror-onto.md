---
id: TASK-30
title: Let Hide black out a display that removed displays mirror onto
status: To Do
assignee: []
created_date: '2026-10-05 19:42'
labels:
  - app
  - display-hide
  - mirror
dependencies: []
references:
  - Sources/PanelCtlApp/AppModel.swift
  - TASK-26
  - TASK-21
documentation:
  - docs/display-hide-ux.md
priority: medium
type: feature
ordinal: 20010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
While a display is removed from the desktop, Hide refuses to black out the display it's mirrored onto ('PanelCtl is mirroring … onto this display. Show it first.'). On the recorded setup that source is the main Dell AW3423DW, an OLED, so with the DELL S2721DGF removed the user can't black out the AW3423DW even though the K272HUL would stay visible. The user wants every other display's Hide to stay available while one is hidden, refusing only what would leave no visible display. The refusal dates from TASK-26: a cover on a display in a mirror set is copied to every display in the set, and CGDisplayIsInMirrorSet is true for the source too, so the source is treated like a display macOS mirrors (reconciliation also shows a blacked-out display that macOS starts mirroring). For the source of a PanelCtl removal the copy only reaches displays that are already removed. Automation can already overlay this source while hidden (TASK-21), but a person can't hide it until Show.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 While PanelCtl has removed displays onto a source, Hide can black out that source whenever another display stays visible. Removed displays still on the Mac's input mirror the cover, and the source's tile, menu item and script result show Hidden with Show available.
- [ ] #2 Black out still refuses, and reconciliation still shows, displays that macOS mirrors outside a PanelCtl removal. Removing a display onto a blacked-out source is still refused.
- [ ] #3 Showing a removed display leaves its blacked-out source covered, and showing the source removes only its cover and leaves the removal intact. Display changes, sleep and wake, disconnection, quit and relaunch keep both consistent; relaunch starts with the source shown and the removal kept.
- [ ] #4 Removed displays and a blacked-out source never count as visible for the last-visible rule, and automation's source overlay never double-covers, or shows, a source that Hide blacked out.
- [ ] #5 Fake-backed tests cover AC1–AC4, display-hide-ux.md states the rule, and the full offline suite and warnings-as-errors builds pass. With the user's approval, one check on their displays confirms the AW3423DW cover while the S2721DGF is removed onto it, then Show of each.
<!-- AC:END -->
