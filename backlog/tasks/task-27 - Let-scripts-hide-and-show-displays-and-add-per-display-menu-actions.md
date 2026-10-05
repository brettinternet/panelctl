---
id: TASK-27
title: Let scripts hide and show displays and add per-display menu actions
status: To Do
assignee: []
created_date: '2026-10-05 06:07'
labels:
  - app
  - cli
  - display-hide
dependencies:
  - TASK-25
  - TASK-26
references:
  - Sources/PanelCtlCore/AppControl.swift
  - Sources/PanelCtlCore/CLIParser.swift
  - Sources/PanelCtlCore/CLIHelp.swift
  - Sources/PanelCtlApp/AppControlServer.swift
  - Sources/PanelCtlApp/AppDelegate.swift
priority: medium
type: feature
ordinal: 17010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user wants display hiding available to third-party automation such as a Stream Deck (approved 2026-10-05). Today `panelctl app hide/show` only reports state and returns exit 4 (confirmation required) for any change; the only working path is the raw `panelctl away/back` with both UUIDs and consent flags, which bypasses the app settings and protection handling. Scripts should perform the display saved Hide style through the running app, single-button devices need a toggle, users need an easy way to get the exact command, and the menu should offer each display Hide or Show directly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The app commands hide, show and toggle-hide with --display UUID perform the display saved style through the running app (Black out, or Remove from desktop when Experimental is on and set up), report desktop and input outcomes, and are a no-op when already in the requested state. Exit codes are 0 done or no-op, 1 refused, 3 app unavailable, 5 partial input outcome and 6 recovery needed; exit 4 is no longer used.
- [ ] #2 Scripted hides never start from idle, startup, wake or reconnection, and existing refusals (unknown UUID, ineligible display, unresolved recovery, busy, last usable display) still apply.
- [ ] #3 The Displays detail offers Copy command for the selected display using the full path of the CLI bundled in the app, so it works without PATH setup.
- [ ] #4 The menu lists each display with Hide or Show and its state, alongside Black Out Now, Sleep Displays, Pause Automation, Settings and Quit.
- [ ] #5 CLI help, usage docs and tests (parser, app control and model) cover the new verbs and exit codes; full offline tests and warnings-as-errors builds pass.
<!-- AC:END -->
