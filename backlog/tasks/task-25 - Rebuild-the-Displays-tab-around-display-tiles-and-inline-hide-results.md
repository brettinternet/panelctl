---
id: TASK-25
title: Rebuild the Displays tab around display tiles and inline hide results
status: In Progress
assignee: []
created_date: '2026-10-05 06:06'
updated_date: '2026-10-05 08:03'
labels:
  - app
  - ui
  - display-hide
dependencies:
  - TASK-24
references:
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/DisplayOperationConfirmation.swift
  - Sources/PanelCtlApp/DisplayHidePreferences.swift
documentation:
  - docs/display-hide-ux.md
priority: medium
type: feature
ordinal: 15010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hide setup was hard to use: an opt-in toggle per display, mirror sources listed by raw identity strings with no default, DDC inputs typed as codes, a separate Check DDC availability button and paragraphs of warnings. Every Hide or Show then required a long modal with an acknowledgement checkbox, followed by a result alert. A healthy hidden desktop was presented as an orange recovery card with journal paths and CLI commands, and the banner action "Review display recovery…" did nothing when Displays was already showing (it only changed the sidebar selection; nothing scrolls to the card).

On 2026-10-05 the user approved a tile-based Displays tab: each display shows its state and a Hide or Show action; the "Remove from desktop" (mirror) style sits behind the Experimental flag; the main display is the default mirror source (it is also the only hardware-qualified source); inputs are picked by name with the Mac input detected over DDC; one consent at the Experimental toggle replaces per-operation confirmations; results appear inline instead of in alerts. Recovery must stay reachable and honest.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Displays shows one selectable tile per active display, ordered left to right by arrangement, plus any journal-owned hidden or absent target, each with a short state (for example On, Hidden, Unavailable, Needs recovery). The selected display detail shows its name, a plain state line and the primary Hide or Show action.
- [ ] #2 With Experimental on, an eligible non-main external display can use Remove from desktop. The mirror source defaults to the main display and can be changed; the input to switch to is chosen from named inputs, a custom code, or no switch; the Mac current input is read automatically (read-only DDC) when the setup is shown and used as the return input, and an unreadable input is explained inline while manual switching stays available.
- [ ] #3 Hide and Show from Settings or the menu run without per-operation confirmation dialogs or success alerts. Desktop and input outcomes appear inline on the tile, detail and menu; failures appear inline with a way to retry; the quit-while-hidden warning remains.
- [ ] #4 A healthy hidden display reads as a normal state with Show. The cross-tab banner appears only for real recovery problems or inspection failures, and its action selects the Displays tab and the affected display. Journal path, identities and the recovery command sit under a collapsed Recovery details disclosure with copy actions.
- [ ] #5 Backend safety is unchanged: one removed display at a time, identity and topology checks, journal capture before writes, unresolved journals blocking new removal, and Show and recovery available regardless of the Experimental flag or automation state.
- [ ] #6 Fake-backed tests cover tile states, default source, input detection success and failure, inline outcomes and recovery focus; full offline tests and warnings-as-errors builds pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Model: DisplayTile list in arrangement order plus journal targets, typed readiness, one Hide/Show action per tile shared by Settings and the menu, main display as default mirror source, read-only Mac input detection as the return input, inline DisplayOperationResult instead of notices.
2. Remove per-operation confirmation (DisplayOperationConfirmation); Settings, menu and quit call hide/show(targetUUID:) with a completion; quit offers Show and Quit.
3. Displays view: tile strip, detail summary with primary action and inline results, Hide setup (switch, source picker, named input picker with Other…, Mac input row), collapsed Recovery details with copy actions; banner only for real problems and selects the affected display.
4. Tests and docs: fake-backed tile, default source, detection, inline outcome and recovery focus tests; Displays snapshot fixtures; development.md fixture notes; full offline tests and warnings-as-errors builds.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented model, view, menu and quit changes; removed confirmation dialogs and the foreground-only keyboard fixtures that exercised them. DDCError now conforms to LocalizedError so DDC failures read as their description instead of a generic Cocoa message. Full offline suite (223 core, 105 app; 4 opt-in skips) and warnings-as-errors builds pass.
<!-- SECTION:NOTES:END -->
