---
id: TASK-31
title: Remove the main display from the desktop
status: To Do
assignee: []
created_date: '2026-10-05 19:42'
labels:
  - app
  - cli
  - display-hide
  - mirror
  - human-gated
dependencies: []
references:
  - Sources/PanelCtlCore/DisplayMirroring.swift
  - Sources/PanelCtlCore/RecoveryJournal.swift
  - Sources/PanelCtlCore/DisplayHide.swift
  - Sources/PanelCtlApp/AppModel.swift
  - TASK-13
documentation:
  - docs/display-hide-ux.md
  - docs/display-mirroring.md
  - docs/display-handoff.md
  - docs/display-recovery.md
priority: medium
type: feature
ordinal: 21010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user wants to remove whichever display is main from the desktop, for example to hand the main Dell AW3423DW to another computer while the Mac keeps working on its other displays. Remove from desktop refuses the main display by design (TASK-13): mirror capture, journal validation and post-mirror verification all require a non-main target and an unchanged main display, and the app says 'The main display can't be removed from the desktop.' Black out of the main display already works, and the workaround is to make another display main in System Settings → Displays first. macOS decides the outcome, not PanelCtl: the menu bar, Dock, windows, Spaces and the (0, 0) origin every other display is positioned from may move. Apple's CGGetActiveDisplayList documentation says that while mirroring the main display is 'the largest drawable display in the mirror set, or, if all displays are the same size, the one with the deepest pixel depth', so CGMainDisplayID may even keep reporting the removed display; observe the result rather than assume it. Recovering by hand means turning off mirroring and dragging the menu bar back in System Settings → Displays. The main display is also today's default and only hardware-qualified mirror source, so a main target has no qualified default. Several-at-once removal builds on this so it can design for a moving main display.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With Experimental features on, the current main display can use Remove from desktop from tiles, the menu and scripts when it's an otherwise eligible external display. Built-in displays and displays without a stable ID stay ineligible.
- [ ] #2 A main display's setup never defaults to mirroring onto itself; Hide shows a reason until the user chooses a source. The setup explains that macOS decides where the menu bar, Dock, windows and Spaces go. Existing configurations and other displays' default source don't change.
- [ ] #3 Hide succeeds when the target is verified mirrored onto its source and every other captured property still matches, whichever display macOS then reports as main. That layout counts as hidden by PanelCtl, not recovery-needed, in the app, scripts, CLI mirror and away, and recovery status.
- [ ] #4 Show from the app, scripts, CLI back or unmirror, and recovery restore makes the original display main again with the captured arrangement and modes, and verifies it. On mismatch it keeps recovery and gives the manual steps (turn off mirroring, drag the menu bar back in System Settings → Displays) without reporting success.
- [ ] #5 Fake-topology tests cover main moving to the source, staying on the removed display or moving elsewhere; main changing again while hidden (for example across sleep and wake); Show restoring main; verification mismatch; and refusals. Full offline suite and warnings-as-errors builds pass with no real topology writes.
- [ ] #6 Docs describe the main-display behavior as observed and what's qualified. A supervised trial, each write separately approved by the user, removes the main AW3423DW onto a display the user chooses and shows it, recording where the menu bar, Dock and (0, 0) origin went and the verified restoration. Untested combinations stay unsupported.
<!-- AC:END -->
