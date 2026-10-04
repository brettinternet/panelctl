---
id: TASK-16
title: Define coherent display hide and handoff flows across the app
status: To Do
assignee: []
created_date: '2026-10-04 17:13'
labels:
  - display-hide
  - app
dependencies: []
references:
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlApp/AppDelegate.swift
  - docs/usage.md
  - docs/display-mirroring.md
  - docs/display-disable-implementation-plan.md
priority: medium
type: task
ordinal: 6010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The app currently organizes Automation, Displays and Startup around OLED protection. Adding hide as another blackout mode would confuse keeping pixels dark with removing a desktop or handing a monitor to another computer. Establish a small, user-reviewed interaction contract for the existing UI before implementing new controls; reuse existing navigation rather than invent a second settings system. TASK-13 supplies public mirror hide and TASK-15 supplies away/back. Private disconnect remains separately gated. Offline design, implementation and fake/no-write validation only. This task does not authorize live mirror/unmirror, DDC or private setter writes. Any hardware validation needs fresh scoped human approval; record untested behavior honestly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Document a use-case matrix covering OLED blackout/working dimming, temporarily removing an external desktop without input switching, handing a monitor to another computer with DDC, manual input switching without DDC, and restoring after interruption. For each show entry point, configuration, visible result and return/recovery path.
- [ ] #2 Provide annotated flows or mockups for the menu bar and existing Automation, Displays and Startup pages, including first use and repeat use. Keep protection enable/disable distinct from display hide/show and away/back; settle labels, placement and Restore scope with user review recorded before downstream UI implementation.
- [ ] #3 Specify visible states and actions for normal, busy, hidden by PanelCtl, disconnected, externally mirrored, unsupported and recovery-needed displays. Recovery remains discoverable even when the target is absent from active enumeration or the menu icon is hidden.
- [ ] #4 Explain that blackout retains the desktop, mirroring removes a separate desktop but keeps signal and may alter modes/HDR/refresh, and DDC input switching is optional. Do not promise signal loss, automatic input switching, OLED maintenance or exact window/Spaces placement.
- [ ] #5 Define a behavior matrix for manual actions versus idle/empty-display automation, activity restore, snooze, global Restore, quit/relaunch, sleep/wake and hotplug. Preserve existing protection defaults, exclude implicit startup/wake re-hide, and identify unsupported combinations rather than inheriting blackout semantics.
- [ ] #6 Review flows with synthetic single-display, multiple-display, unavailable-target, no-DDC and partial-failure scenarios; document keyboard/VoiceOver navigation and an always-reachable return/recovery action. Record user approval of the interaction contract.
<!-- AC:END -->
