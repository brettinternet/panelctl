---
id: TASK-26
title: Add Black out as a per-display Hide style
status: In Progress
assignee:
  - '@pi'
created_date: '2026-10-05 06:07'
updated_date: '2026-10-05 08:37'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Overlays live in the app, not the helper: the app runs a real NSApplication event loop (the helper's stale-transform bug came from pumping RunLoop without AppKit events), the existing focus controller gives Escape, and quitting or crashing removes them. Expose blackout's window configuration and exact-coverage check from PanelCtlCore and reuse them.
2. Model: a session-only set of displays hidden by Black out. The style is Black out unless Experimental is on and Remove from desktop is opted in. hide/show dispatch on it; black-out Hide is refused for a display without a stable ID, one that is off, asleep or mirrored by macOS, during display transitions or another operation, and when no other awake, unhidden display would remain. Removal onto a blacked-out source is refused.
3. Display changes: overlays are re-applied to their display's current frame. A disconnected display stays hidden for the session and is covered again when it reconnects. If no other connected display remains, every blacked-out display is shown and its tile says why.
4. Automation: helper arguments skip hidden displays (explicit selection minus hidden; All displays becomes an explicit list while any are hidden). When every covered display is hidden it waits. Black Out Now and the hidden-mirror source overlay skip them too, and Restore and activity never show them.
5. Focus: Escape on a hidden display shows that display; elsewhere it restores automation as before.
6. UI: a Hidden tile state with Show on tile, detail and menu; the Hide footer explains Black out; the Remove from desktop switch stays the style choice.
7. Tests (model, preferences, focus routing) and docs; full offline suite and warnings-as-errors builds.
<!-- SECTION:PLAN:END -->
