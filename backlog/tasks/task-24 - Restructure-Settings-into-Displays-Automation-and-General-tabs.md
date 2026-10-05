---
id: TASK-24
title: 'Restructure Settings into Displays, Automation and General tabs'
status: Done
assignee: []
created_date: '2026-10-05 06:06'
updated_date: '2026-10-05 06:40'
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
- [x] #1 Settings presents native toolbar tabs Displays, Automation and General instead of the sidebar; Startup options, Quit, version and the GitHub link move to General, and keyboard and VoiceOver navigation reach every tab.
- [x] #2 The Automation tab owns the automation on/off switch with live status, idle delay, Black out or Dim treatment (with darkness), the idle display checklist (All displays, per-display rows and unavailable saved selections), afterward behavior, empty-display blackout, pause conditions and the advanced hardware brightness and display-sleep options, in grouped form sections with concise copy. Saved preference keys, defaults and validation are unchanged.
- [x] #3 Settings and menu copy use Automation terminology instead of "OLED" or "Protection" (for example Pause Automation), without renaming persisted keys or CLI commands.
- [x] #4 General has a persisted Experimental toggle, off by default, that asks for one consent when turned on and links to documentation. With it off the hide configuration UI is hidden, while hidden-desktop status, Show and recovery stay visible whenever a journal or inspection failure exists.
- [x] #5 The always-disabled private-disconnect section is removed from production Settings; its presentation types and tests remain for TASK-20.
- [x] #6 docs/display-hide-ux.md records the user-approved 2026-10-05 amendment; full offline tests and warnings-as-errors builds pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Model: persisted experimentalFeaturesEnabled (default off); turning it on only sets experimentalConsentPending until acceptExperimentalConsent(), turning it off applies at once; makeHideRequest refuses while off; Automation wording in model, service and preference copy (persisted keys and CLI unchanged).
2. Window: SettingsTab + shared navigation; SettingsWindowController installs a preference-style NSToolbar with selectable Displays/Automation/General items, titles the window after the tab, supports Cmd-1..3 and follows recovery focus.
3. SwiftUI split: root SettingsView (banner, notice alert, tab switch), AutomationSettingsView (grouped Form owning switch, idle, displays, afterward, empty displays, pause conditions, advanced), GeneralSettingsView (startup, Experimental toggle with consent alert bound to the model and docs link, version, GitHub, Quit), interim DisplaySettingsView (recovery card always when a journal or inspection failure exists; hide cards only with Experimental on). Remove ExperimentalDisconnectView from production Settings.
4. Menu: Pause Automation submenu with Turn Off, Turn On/Resume Automation, Black Out Now, Sleep Displays, Retry Automation; hide section only with Experimental on or when a journal, inspection failure or operation exists; GitHub link leaves the status menu.
5. Record the 2026-10-05 amendment in docs/display-hide-ux.md.
6. Tests for tabs and keyboard, flag persistence, consent gating, recovery visibility, menu gating and copy; full swift test plus warnings-as-errors build.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions: the interim Displays tab keeps the existing hide cards (now a plain VStack; LazyVStack never rendered cards below a long recovery card) and shows a plain display list with a pointer to General while Experimental is off. Keep displays black during activity moved into When idle because it changes the Afterward timer. The Experimental consent lives in AppModel.experimentalConsentPending, like notice, so the native alert is testable. Hide fixtures in DisplayHideAppTests turn Experimental on in makeDefaults; gating has its own tests. The old Tab-advances assertion relied on the removed sidebar List (the only valid key view without Full Keyboard Access); tab reachability is now covered by Command-1..3, toolbar AX buttons and toolbar actions.
Validation 2026-10-05: swift test --disable-sandbox -Xswiftc -warnings-as-errors passed (core 223 tests, 2 skipped; app 102 tests, 3 opt-in skips); swift build --product panelctl and --product PanelCtlApp with -warnings-as-errors passed; scripts/test-release-version.sh passed. PANELCTL_RUN_NATIVE_DISPLAY_KEYBOARD_FIXTURES=1 DisplayHideAppTests.testNative: 6 passed, 2 skipped because the XCTest host could not become frontmost from this terminal. Settings PNG fixtures (PANELCTL_SETTINGS_FIXTURE_OUTPUT) reviewed for default and variant states of all three tabs. No display, DDC or hardware writes were made.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Settings now uses native toolbar tabs: Displays, Automation (switch and live status, When idle, display checklist, empty displays, Pause while, Advanced) and General (startup, menu icon, Experimental features with one consent and docs link, version, GitHub, Quit). OLED/Protection copy became Automation in Settings, menu and status text (Pause Automation submenu, Black Out Now, Sleep Displays); persisted keys and CLI are unchanged. Experimental off by default hides hide configuration and refuses Hide in Settings, menu and app control, while Show and recovery stay reachable. The disabled disconnect preview left Settings. docs/display-hide-ux.md records the 2026-10-05 amendment. Verified with new SettingsWindowTests (tabs, Command-1..3, VoiceOver toolbar buttons, recovery focus, flag persistence and gating, native consent alert, menu wording), updated hide/protection tests, the full offline suite and warnings-as-errors builds.
<!-- SECTION:FINAL_SUMMARY:END -->
