---
id: TASK-30
title: Let Hide black out a display that removed displays mirror onto
status: Done
assignee: []
created_date: '2026-10-05 19:42'
updated_date: '2026-10-05 22:24'
labels:
  - app
  - display-hide
  - mirror
dependencies: []
references:
  - Sources/PanelCtlApp/AppModel.swift
  - TASK-26
  - TASK-21
documentation:
  - docs/display-hide-ux.md
priority: medium
type: feature
ordinal: 20010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
While a display is removed from the desktop, Hide refuses to black out the display it's mirrored onto ('PanelCtl is mirroring … onto this display. Show it first.'). On the recorded setup that source is the main Dell AW3423DW, an OLED, so with the DELL S2721DGF removed the user can't black out the AW3423DW even though the K272HUL would stay visible. The user wants every other display's Hide to stay available while one is hidden, refusing only what would leave no visible display. The refusal dates from TASK-26: a cover on a display in a mirror set is copied to every display in the set, and CGDisplayIsInMirrorSet is true for the source too, so the source is treated like a display macOS mirrors (reconciliation also shows a blacked-out display that macOS starts mirroring). For the source of a PanelCtl removal the copy only reaches displays that are already removed. Automation can already overlay this source while hidden (TASK-21), but a person can't hide it until Show.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 While PanelCtl has removed displays onto a source, Hide can black out that source whenever another display stays visible. Removed displays still on the Mac's input mirror the cover, and the source's tile, menu item and script result show Hidden with Show available.
- [x] #2 Black out still refuses, and reconciliation still shows, displays that macOS mirrors outside a PanelCtl removal. Removing a display onto a blacked-out source is still refused.
- [x] #3 Showing a removed display leaves its blacked-out source covered, and showing the source removes only its cover and leaves the removal intact. Display changes, sleep and wake, disconnection, quit and relaunch keep both consistent; relaunch starts with the source shown and the removal kept.
- [x] #4 Removed displays and a blacked-out source never count as visible for the last-visible rule, and automation's source overlay never double-covers, or shows, a source that Hide blacked out.
- [x] #5 Fake-backed tests cover AC1–AC4, display-hide-ux.md states the rule, and the full offline suite and warnings-as-errors builds pass. With the user's approval, one check on their displays confirms the AW3423DW cover while the S2721DGF is removed onto it, then Show of each.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Inspect blackout eligibility, reconciliation, visibility and automation ownership. 2. Allow only verified PanelCtl removal sources and add fake-backed lifecycle/refusal coverage plus docs. 3. Run offline suite, warnings-as-errors builds and independent review. 4. Request scoped live-check approval, record evidence, commit, merge main and clean up owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation in .worktrees/task-30-blackout-source (branch task-30-blackout-source, base feadf4e). Executor workflow 0761e878-d3f6-4e0f-9a9c-4509e8912176 failed provider access (Unable to verify Daybreak Blue access) after partial edits; user authorized direct takeover. Full offline suite and panelctl/PanelCtlApp warnings-as-errors builds pass after takeover; fake tests cover verified source Hide/script/menu, independent Show, sleep/wake/disconnect/relaunch, automation ownership, external/unverified mirror refusal and loss of last independent display. Independent review pending. No live writes performed. Live AC5 still requires scoped user approval and visual observations. Worktree receipt: .git/worktrees/task-30-blackout-source/agent-creation.json, owner session 01a10de5-aef2-7226-b088-b7d1e9f98325.

Delivered a3fa961 (implementation) and live evidence documentation, merged to main. Validation: swift test --disable-sandbox: 241 core tests (2 skipped), 147 app tests (2 skipped), zero failures; panelctl and PanelCtlApp -warnings-as-errors builds pass. LSP diagnostics unknown (bounded report timeout); compiler/tests authoritative. One independent reviewer found stale topology before direct Hide and failure to restart automation after failed cover; both corrected with regressions and full checks rerun. Existing removal-onto-covered-source refusal retained. Live check 2026-10-05, Mac17,14/26A434: user approved each operation. Initial removal and refused source attempt reached installed older app; stopped, quit without Show, launched exact a3fa961 worktree executable and verified process path. Source Hide succeeded with automation stopped; user confirmed AW3423DW black, K272HUL/AW3425DW usable. Target Show verified DP 0x0F and restored layout while source remained covered; user confirmed. Source Show succeeded and user confirmed all displays restored. Journal E9181195-A9AE-4181-A992-C74CE9E7A5E4 restored. Test app quit; installed app/settings unchanged. Live scope limits recorded in docs/display-hide-ux.md. No remaining acceptance blocker; owned worktree cleanup pending.

Delivery complete: a3fa961 and 6330521 fast-forward merged to main. Owned task-30-blackout-source worktree and branch removed with Worktrunk; corresponding Herdr workspace w27 verified absent. Pre-existing recovery-enable worktree left untouched (not owned by this session). Claim released. No next implementation step remains; future live combinations require fresh approval.

Post-completion review (4ce885f): status said a blacked-out removal source was 'not in the idle display list'; it now says the source is blacked out by Hide (testBlackedOutRemovalSourceExplainsSuspendedAutomation).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Allow manual Black out of verified PanelCtl removal sources without relaxing external-mirror refusal or last-visible safety. Keep manual cover ownership separate from automation and removal Show. Verified full offline suite, warnings-as-errors builds, corrected independent-review findings, and a separately approved live source blackout / target-then-source Show check.
<!-- SECTION:FINAL_SUMMARY:END -->
