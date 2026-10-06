---
id: TASK-25
title: Rebuild the Displays tab around display tiles and inline hide results
status: Done
assignee: []
created_date: '2026-10-05 06:06'
updated_date: '2026-10-05 08:24'
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
- [x] #1 Displays shows one selectable tile per active display, ordered left to right by arrangement, plus any journal-owned hidden or absent target, each with a short state (for example On, Hidden, Unavailable, Needs recovery). The selected display detail shows its name, a plain state line and the primary Hide or Show action.
- [x] #2 With Experimental on, an eligible non-main external display can use Remove from desktop. The mirror source defaults to the main display and can be changed; the input to switch to is chosen from named inputs, a custom code, or no switch; the Mac current input is read automatically (read-only DDC) when the setup is shown and used as the return input, and an unreadable input is explained inline while manual switching stays available.
- [x] #3 Hide and Show from Settings or the menu run without per-operation confirmation dialogs or success alerts. Desktop and input outcomes appear inline on the tile, detail and menu; failures appear inline with a way to retry; the quit-while-hidden warning remains.
- [x] #4 A healthy hidden display reads as a normal state with Show. The cross-tab banner appears only for real recovery problems or inspection failures, and its action selects the Displays tab and the affected display. Journal path, identities and the recovery command sit under a collapsed Recovery details disclosure with copy actions.
- [x] #5 Backend safety is unchanged: one removed display at a time, identity and topology checks, journal capture before writes, unresolved journals blocking new removal, and Show and recovery available regardless of the Experimental flag or automation state.
- [x] #6 Fake-backed tests cover tile states, default source, input detection success and failure, inline outcomes and recovery focus; full offline tests and warnings-as-errors builds pass.
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

Independent review of e70dc73 found five P2 regressions, fixed in 25c6f94: invalid or empty custom input codes now turn switching off instead of leaving the last code armed; a Mac-input reading equal to the switch-to input is kept as onSwitchInput and never becomes the return input, even after the switch-to input changes; a DDC reading of unknown input 0 is reported as unavailable and keeps the saved return input; recovery problems no display tile shows (inspection failures, targetless journals such as recovery capture) appear above the displays with Recovery details; results that need attention show the backend's undo-input command, kept across settings edits. The return input is now kept while switching is off; Show uses it only when Hide switched. bc0017b adds a test that drives the real quit-while-hidden alert (Cancel; Show and Quit with a failed Show keeps the app running and opens the display). Evidence: AC1 testDisplayTilesFollowArrangementAndShowEachState, testNativeMissingJournalTargetStaysSelectedAndFreezesSetup; AC2 testRemovalDefaultsToTheMainDisplayAsMirrorSource, testMacInputIsDetectedReadOnlyAndBecomesTheReturnInput, testNativeHideSetupDefaultsSourceAndDetectsTheMacInputWhenSwitching; AC3 testHideAndShowReportDesktopAndInputResultsInline, testNativeShowRunsWithoutDialogsAndResultsStayInline, testQuitWhileHiddenWarnsAndKeepsRunningWhenShowFails; AC4 testNativeMenuAndSettingsKeepShowReachableForAHiddenDisplay, testRecoveryProblemOpensItsDisplayFromReopenAndMenu, testRecoveryJournalWithoutATargetDisplayIsShownAboveTheDisplays; AC5 PanelCtlCore diff since 896746f is only DDCError: LocalizedError, plus partial-failure, duplicate-refusal, identity and lifecycle tests; AC6 swift test --disable-sandbox -Xswiftc -warnings-as-errors (223 core, 108 app, 4 opt-in skips), swift build -Xswiftc -warnings-as-errors, scripts/test-release-version.sh. Displays snapshot fixtures (off, setup, unreadable, refused, partial, hidden, recovery, recovery-banner, recovery-journal) reviewed visually.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Rebuilt Settings > Displays around display tiles, each with its state and one Hide or Show action shared with the menu. Removed per-operation confirmations and result alerts in favor of inline results, made the main display the default mirror source, and added read-only Mac input detection. Recovery problems and undo-input commands stay visible. Backend safety is unchanged. Verified with fake-backed model, native AppKit, quit-alert and snapshot tests, the full offline suite, and warnings-as-errors builds.
<!-- SECTION:FINAL_SUMMARY:END -->
