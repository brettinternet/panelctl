---
id: TASK-26
title: Add Black out as a per-display Hide style
status: Done
assignee:
  - '@pi'
created_date: '2026-10-05 06:07'
updated_date: '2026-10-05 09:34'
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
- [x] #1 Every display defaults to the Black out style. Hide covers it with an opaque overlay that stays through activity until Show (or Escape on that display), whether automation is on, paused or off.
- [x] #2 Hide refuses to black out the last display that would remain usable and explains why; otherwise several displays can be blacked out at once.
- [x] #3 Blacked-out displays coexist with idle automation without double treatment or focus problems: automation skips displays already hidden, automation restore and activity do not show them, and display reconfiguration or disconnection cleans up or re-applies the overlay predictably.
- [x] #4 Black-out hidden state is visible on the tile, detail and menu and survives closing Settings; quitting PanelCtl removes the overlays and relaunch starts with every display shown.
- [x] #5 Fake-backed tests cover hide and show, last-display refusal, coexistence with automation and display disconnection; full offline tests and warnings-as-errors builds pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Overlays live in the app, not the helper: the app runs a real NSApplication event loop (the helper's stale-transform bug came from pumping RunLoop without AppKit events), the existing focus controller gives Escape, and quitting or crashing removes them. Expose blackout's window configuration and exact-coverage check from PanelCtlCore and reuse them.
2. Model: a session-only set of displays hidden by Black out. The style is Black out unless Experimental is on and Remove from desktop is opted in. hide/show dispatch on it; black-out Hide is refused for a display without a stable ID, one that is off, asleep or mirrored by macOS, during display transitions or another operation, and when no other awake, unhidden display would remain. Removal onto a blacked-out source is refused.
3. Display changes: overlays are re-applied to their display's current frame. A disconnected display stays hidden for the session and is covered again when it reconnects. A hidden display macOS starts mirroring is shown, since the mirror would copy its cover. If no other connected display remains, every blacked-out display is shown. Either way its tile says why.
4. Automation: helper arguments skip hidden displays but count them as covered (explicit selection minus hidden; All displays becomes an explicit list while any are hidden). When every covered display is hidden it waits. Black Out Now and the hidden-mirror source overlay skip them too and count them as covered, empty-display coverage pauses while the pointer is on a hidden display, and Restore and activity never show them.
5. Focus: Escape on a hidden display shows that display; elsewhere it restores automation as before.
6. UI: a Hidden tile state with Show on tile, detail and menu; the Hide footer explains Black out; the Remove from desktop switch stays the style choice.
7. Tests (model, preferences, focus routing) and docs; full offline suite and warnings-as-errors builds.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Independent review (reviewer run e79f4d17) found three P1 safety gaps, all fixed in 962130f with regression tests: (1) empty-display coverage could black out the last usable display while the pointer sat on a hidden one; the empty policy now covers nothing then. (2) The hidden-mirror source overlay didn't count Black out displays as covered, so input could extend its deadline indefinitely; it now passes --panelctl-hidden-display (the helper accepts the combination) and the app countdown matches. (3) A hidden display macOS later mirrors kept its cover, which the mirror would copy; reconciliation now shows it and the tile says why. 6fae572 adds a test that Black out survives closing Settings.

Validation: swift test --disable-sandbox (PanelCtlCoreTests 225, PanelCtlAppTests 119, 0 failures, 4 opt-in skips); swift build --product panelctl and --product PanelCtlApp with -warnings-as-errors; scripts/test-release-version.sh passed. Displays fixture PNG (displays-blacked-out) reviewed: Hidden tile, 'Blacked out until you show it' detail, Show button and Esc note. All tests use fake overlay managers; the real app wasn't launched and no screen was covered.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Hide now blacks out a display by default with an app-owned opaque overlay that stays until Show or Esc on that display, independent of automation. Removal stays opt-in behind Experimental and the per-display switch. Hide refuses the last usable display; automation, Black Out Now and the hidden-mirror overlay skip hidden displays and count them as covered; disconnects re-cover on reconnect, and hidden displays are shown with a reason when macOS mirrors them or no other display remains. Verified with fake-backed model, preferences, helper-parser, empty-policy and Settings tests, the full offline suite and warnings-as-errors builds.
<!-- SECTION:FINAL_SUMMARY:END -->
