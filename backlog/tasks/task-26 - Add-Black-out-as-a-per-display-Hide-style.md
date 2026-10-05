---
id: TASK-26
title: Add Black out as a per-display Hide style
status: To Do
assignee: []
created_date: '2026-10-05 06:07'
labels:
  - app
  - display-hide
  - protection
dependencies:
  - TASK-25
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - Sources/PanelCtlApp/BlackoutFocusController.swift
  - Sources/PanelCtlCore/Blackout.swift
priority: medium
type: feature
ordinal: 16010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After the redesign, Hide is the single verb for making any display go away, and each display has a style. The user treats blackout as one kind of hide and asked that Hide simply black out when experimental removal is off (approved 2026-10-05). Today blackout only exists inside idle automation and Blackout Now for its selection; there is no way to keep one chosen display black until Show, for example a side monitor during a film or from a Stream Deck button.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every display defaults to the Black out style. Hide covers it with an opaque overlay that stays through activity until Show (or Escape on that display), whether automation is on, paused or off.
- [ ] #2 Hide refuses to black out the last display that would remain usable and explains why; otherwise several displays can be blacked out at once.
- [ ] #3 Blacked-out displays coexist with idle automation without double treatment or focus problems: automation skips displays already hidden, automation restore and activity do not show them, and display reconfiguration or disconnection cleans up or re-applies the overlay predictably.
- [ ] #4 Black-out hidden state is visible on the tile, detail and menu and survives closing Settings; quitting PanelCtl removes the overlays and relaunch starts with every display shown.
- [ ] #5 Fake-backed tests cover hide and show, last-display refusal, coexistence with automation and display disconnection; full offline tests and warnings-as-errors builds pass.
<!-- AC:END -->
