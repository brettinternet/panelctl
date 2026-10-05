---
id: TASK-24
title: 'Restructure Settings into Displays, Automation and General tabs'
status: In Progress
assignee: []
created_date: '2026-10-05 06:06'
updated_date: '2026-10-05 06:08'
labels:
  - app
  - ui
  - display-hide
dependencies: []
references:
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlApp/SettingsWindowController.swift
  - Sources/PanelCtlApp/AppDelegate.swift
documentation:
  - docs/display-hide-ux.md
priority: medium
type: feature
ordinal: 14010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Settings window uses a sidebar (Automation / Displays / Startup) and mixes concerns. The Displays page carries the idle-automation display checklist labelled "OLED protection displays", the experimental hide cards, a recovery card and an always-disabled private-disconnect preview, while the header calls the idle watcher "OLED Protection". The user found it convoluted and approved a redesign on 2026-10-05.

Approved direction: native toolbar tabs instead of the sidebar (the standard Mac Settings pattern for a few panes, drawn in the Liquid Glass toolbar on macOS 26+); Automation owns everything about idle and empty-display treatment, including which displays it covers; General holds startup options and a single Experimental flag; "OLED" naming goes away because blackout is just one way to hide a display. The same approval amended the TASK-16/TASK-19 hide contract: no per-operation Hide/Show confirmations after one consent when Experimental is turned on, CLI-triggered Hide/Show, the main display as default mirror source with automatic read-only input detection, Black out as a per-display Hide style, and removal of the disabled disconnect preview.

This task covers the window shell plus the Automation and General content. The Displays tab rebuild is a follow-up task; until then the existing hide/recovery UI may live in the Displays tab unchanged apart from flag gating.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Settings presents native toolbar tabs Displays, Automation and General instead of the sidebar; Startup options, Quit, version and the GitHub link move to General, and keyboard and VoiceOver navigation reach every tab.
- [ ] #2 The Automation tab owns the automation on/off switch with live status, idle delay, Black out or Dim treatment (with darkness), the idle display checklist (All displays, per-display rows and unavailable saved selections), afterward behavior, empty-display blackout, pause conditions and the advanced hardware brightness and display-sleep options, in grouped form sections with concise copy. Saved preference keys, defaults and validation are unchanged.
- [ ] #3 Settings and menu copy use Automation terminology instead of "OLED" or "Protection" (for example Pause Automation), without renaming persisted keys or CLI commands.
- [ ] #4 General has a persisted Experimental toggle, off by default, that asks for one consent when turned on and links to documentation. With it off the hide configuration UI is hidden, while hidden-desktop status, Show and recovery stay visible whenever a journal or inspection failure exists.
- [ ] #5 The always-disabled private-disconnect section is removed from production Settings; its presentation types and tests remain for TASK-20.
- [ ] #6 docs/display-hide-ux.md records the user-approved 2026-10-05 amendment; full offline tests and warnings-as-errors builds pass.
<!-- AC:END -->
