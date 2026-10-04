---
id: TASK-16
title: Define coherent display hide and handoff flows across the app
status: Done
assignee: []
created_date: '2026-10-04 17:13'
updated_date: '2026-10-04 18:19'
labels:
  - display-hide
  - app
dependencies: []
references:
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlApp/AppDelegate.swift
  - docs/usage.md
  - docs/display-mirroring.md
  - docs/display-handoff.md
  - docs/display-disable-implementation-plan.md
priority: medium
type: task
ordinal: 6010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The app organizes Automation, Displays and Startup around OLED protection. Adding hide as another blackout mode would confuse keeping pixels dark with removing a desktop or handing a monitor to another computer. Settle a small, user-reviewed interaction contract before implementing controls, reusing existing navigation rather than a second settings system. Backend facts the contract must reflect: TASK-13 public mirror hide and TASK-15 away/back share one journal and back restores either; away without an input code is exactly mirror hide. So the default design is one per-display action pair (hide/show) with optional input switching as configuration, not separate hide and handoff verbs; justify any extra verb in review. Mirroring is qualified for one observed S2721DGF cycle only, so the contract must decide how the app labels or gates it as experimental and how confirmation works on first versus repeat use. Private disconnect stays separately gated (TASK-20). Write the contract to docs/display-hide-ux.md. Offline design only; no live mirror/unmirror, DDC or private setter writes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 docs/display-hide-ux.md has a use-case matrix covering OLED blackout/working dimming, temporarily removing an external desktop, handing a monitor to another computer with DDC, manual input switching without DDC, and restoring after interruption; each row shows entry point, configuration, visible result and return/recovery path.
- [x] #2 Annotated flows or mockups cover the menu bar and the Displays page (Automation/Startup only where they change), for first and repeat use. Protection enable/disable stays distinct from hide/show; one action pair with optional input switching is the default, and labels, placement, confirmation model, experimental labeling/opt-in and global Restore scope are settled.
- [x] #3 Visible states and actions are specified for normal, busy, hidden by PanelCtl, disconnected, externally mirrored, unsupported and recovery-needed displays. Show/recovery stays reachable when the target is absent from enumeration, Settings is closed, the app relaunched, or the menu icon is hidden.
- [x] #4 Copy explains that blackout keeps the desktop, hiding removes the separate desktop but keeps the Mac signal and may change modes/HDR/refresh, and input switching is optional and DDC-dependent. It promises no signal loss, automatic input switching, OLED maintenance or window/Spaces placement.
- [x] #5 A behavior matrix covers manual hide/show against idle/empty-display automation, activity restore, snooze, global Restore, quit/relaunch, sleep/wake and hotplug. Existing protection defaults are preserved, startup/wake re-hide is excluded and unsupported combinations are named rather than inheriting blackout semantics.
- [x] #6 The flows are walked through single-display, multi-display, unavailable-target, no-DDC and partial-failure scenarios, with keyboard/VoiceOver navigation documented. User approval of the contract is recorded in the task before TASK-17 starts.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Completed: inspect existing navigation, protection lifecycle and mirror/handoff backends. 2. Completed: draft contract with flows, states, coexistence and offline scenario walkthroughs. 3. Completed: one scoped review, documentation checks and explicit user approval. 4. Commit approved contract and completed task on main; no push or hardware writes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-04: Drafted docs/display-hide-ux.md against SettingsView/AppDelegate/AppModel/ProtectionService and MirrorController/HandoffController plus recorded hardware evidence. One general offline review checked all six criteria: use-case and lifecycle matrices, menu/Displays mockups, first/repeat confirmations, all seven observed states, absent-target/relaunch/hidden-icon recovery, truthful limitations, single/multi-display/no-DDC/partial-failure walkthroughs and keyboard/VoiceOver contract. Backend checks confirmed shared journal and locks, capture-before-input, restore-before-return-input, absent-target refusal and non-persisted input recovery. User explicitly selected Approve contract in the structured approval prompt: Hide/Show, per-operation confirmation, protection-only Restore and runtime protection suspension during hide/recovery. Design approval only; no hardware consent. Documentation link/fence checks and git diff --check passed. No source changes, native UI execution or hardware writes; native fixture verification belongs to TASK-17/18. Existing backlog re-slice was independently committed as aeece54 and was preserved. No remaining TASK-16 blocker; TASK-17 is next.

Delivery: b40a702 on main commits the approved contract and completed task. Claim released; no worktree created, no push. Documentation checks passed and working tree was clean after delivery. Next resumable item is TASK-17.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Approved hide/show app interaction contract in docs/display-hide-ux.md, including optional DDC, journal-backed recovery, conservative protection coexistence and accessible flows. Verified by offline scenario/criteria review and documentation checks; user explicitly approved. TASK-17 may proceed with offline implementation, not live writes.
<!-- SECTION:FINAL_SUMMARY:END -->
