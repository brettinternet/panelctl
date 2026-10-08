---
id: TASK-74
title: Keep windows off only for hides that ask for it
status: In Progress
assignee:
  - '@codex'
created_date: '2026-10-08 18:51'
updated_date: '2026-10-08 19:03'
labels: []
dependencies:
  - TASK-65
references:
  - docs/display-hide-ux.md
  - docs/window-relocation.md
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/DisplaySettingsView.swift
  - Sources/PanelCtlApp/DisplayActions.swift
type: enhancement
ordinal: 62010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-65 made "keep windows off" a per-display setting enforced under any PanelCtl blackout. An idle or empty-display Automation rule that blacks out an opted-in display therefore moves every eligible window off it; Show never moves them back, so returning from idle finds that monitor emptied. Users also sometimes want to black out an opted-in display without moving anything. Ongoing evacuation fits covers that last until explicit Show (manual Hide, Action Hide), not rule covers that end on input, occupancy or time limits. Decision: keep-off becomes the intent of an individual hide; rules never keep windows off (a deliberate case should be an Action). No new CLI flag: Actions are the scripted way to choose either behavior.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Keep-off intent is held per active blackout Hide for the session only. Manual Hide (tile, menu, CLI hide/toggle-hide) takes it from the display's remembered choice; existing saved per-display opt-ins carry over as that remembered choice with their destination. Show, failed hide and quit clear it; relaunch never restores it.
- [ ] #2 Automation rule blackouts (watch or run-once) never move windows, even for a display whose remembered choice is on; the display reports armed rather than enforcing. Remove from desktop hides never use keep-off.
- [ ] #3 An Action Hide (black out) step can opt in to keep windows off while hidden with Automatic or a specific destination. Saved Actions without the field decode as off; the option is accepted only on black-out steps.
- [ ] #4 The Displays tile shows an "Also keep windows off" option and destination next to Hide (default off, remembered per display). While the display is hidden it pauses or resumes enforcement for the current hide without changing the remembered choice, and status distinguishes a user pause.
- [ ] #5 Copy says moves apply to the desktop currently showing on the display (other desktops unchanged) and that showing the display won't move windows back. Results report moved and failed counts and never claim the display is empty.
- [ ] #6 Existing gates, backoff, drag deferral, pass limits and helper relocation suppression are unchanged. Fake-backed tests cover: rule blackout of an opted-in display moves nothing; manual Hide with the option off moves nothing, toggling on mid-hide enforces, Show clears it; an Action keep-off step enforces and old steps decode as off. Docs (display-hide-ux, window-relocation, usage) describe the per-hide model.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Model: session-only keep-off intent per blackout-hidden display (configuration + user-paused flag), pruned whenever blackoutHiddenDisplays drops a key. coverWithBlackOut records it from the Action step keepWindowsOff field or, for manual hides, the remembered DisplayHideConfiguration.keepWindowsOff.
2. reconcileKeepWindowsOff: controllers for hidden displays with intent (enforce only when app-covered and not user-paused) and for remembered-on displays that are not blackout-hidden (armed/paused only). Rule blackouts no longer count as coverage; they still exclude destinations.
3. setHiddenKeepWindowsOff(_:for:) pauses/resumes the live hide; status reason "Paused for this hide."
4. DisplayActionStep.keepWindowsOff (black-out only) with codable/validation and Action editor toggle + destination.
5. Displays: move Windows section under the summary/Hide row; "Also keep windows off" when visible, live toggle when hidden; new copy (one-shot step too).
6. Update existing WindowRelocationTests to per-hide semantics; add rule-blackout regression and manual-hide off/toggle/Show checks; Action step decode. Docs: display-hide-ux, window-relocation, usage.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented per plan. Verification: swift test --filter WindowRelocationTests (37 tests, 3 consecutive green runs) and full non-interactive swift test (357 tests, 33 skipped, 0 failures). Helper relocation tests now hide the source manually after the fake helper settles, with rules on other displays, because Hide restarts automation. Rule-covered destination exclusion is unchanged (makeWindowMovePlan) and stays covered by selector tests.
<!-- SECTION:NOTES:END -->
