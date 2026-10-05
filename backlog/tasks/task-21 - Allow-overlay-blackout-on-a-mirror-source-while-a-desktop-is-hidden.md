---
id: TASK-21
title: Allow overlay blackout on a mirror source while a desktop is hidden
status: Done
assignee: []
created_date: '2026-10-04 18:22'
updated_date: '2026-10-05 03:05'
labels:
  - display-hide
  - app
  - protection
dependencies:
  - TASK-17
references:
  - Sources/PanelCtlCore/Blackout.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - docs/display-hide-ux.md
priority: medium
type: feature
ordinal: 11010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
While a desktop is hidden by mirroring (TASK-13/15/17), blackout refuses every display in the mirror set because validateTarget checks CGDisplayIsInMirrorSet, which is true for the mirror source as well as the mirrored target. The TASK-16 contract therefore pauses app protection for the whole hide or handoff. In the recorded setup the source is the OLED AW3423DW. During a handoff the user is usually on the other computer while the Mac sits idle on a static desktop, so the OLED is unprotected exactly when protection matters most. This task decides whether blackout can safely cover a mirror-set source, and implements that if so. The overlay would also appear on the mirrored target: harmless on a handed-off input, visible black on a plain hide. Brightness dimming of the target, or of the source through DDC, risks fighting the hide/show transaction. Hide/show ownership, locks and the journal stay unchanged. Offline implementation and fake/no-write validation only; any live blackout of a mirrored display or topology write needs fresh scoped human approval.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An updated docs/display-hide-ux.md coexistence contract, approved by the user, states which displays in a PanelCtl-owned mirror set may receive overlay blackout. It also covers what the mirrored target shows and why brightness dimming stays excluded or is safe. If the conclusion is that it cannot be made safe, that conclusion and its evidence are recorded instead, and the remaining criteria are dropped.
- [x] #2 Blackout allows only the approved mirror-set displays, and only while observed state is Hidden by PanelCtl, verified against the shared journal. External mirrors, recovery-needed, busy hide/show and stale or unknown topology keep the existing refusal.
- [x] #3 Overlay protection never makes topology, DDC input or brightness writes, and is quiesced before Show capture and verification. Show and recovery remain reachable and keyboard-accessible over an active overlay, and activity or Restore never triggers Show.
- [x] #4 Hide confirmation and protection status copy are updated to match the new behavior; nothing claims protection that does not occur.
- [x] #5 Fake tests cover the allowed source, refused external mirror, refused recovery-needed or busy state, topology change during overlay and Show while overlaid; relevant tests and warnings-as-errors builds pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Record user-approved source-only overlay coexistence contract, preserving brightness/sleep suspension and explicit Show. 2. Add journal/topology-verified core source exception and app overlay-only runtime policy; quiesce before Show and preserve keyboard recovery. 3. Add fake core/app tests and update truthful confirmation/status copy. 4. Run focused tests and warnings-as-errors builds, one independent safety review, fix concrete findings, then commit on main and finalize provider evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User approved the TASK-21 coexistence contract in-session: only the selected mirror source in verified Hidden by PanelCtl may receive overlay blackout; never the mirrored target. Target shows black on the Mac input. Brightness and automatic follow-up sleep remain suspended. Busy/recovery/unknown/external mirrors refuse; quiesce before Show, preserve keyboard recovery, and Escape/activity/Restore remain protection-only. Approval is offline implementation/fake validation only, not live blackout or topology/DDC writes.

Delivered implementation commit f02d11f on main. Source/core changes cover strict helper options, journal/source identity and exact mirror-topology evidence, authorization revocation while covered, and source-only opaque bounded overlay arguments. App changes cover runtime policy, Show cleanup, keyboard/recovery reachability and truthful confirmation/status; docs/display-hide-ux.md records the user-approved contract. Saved preferences, hide/show ownership and recovery locks remain unchanged. Brightness, DDC input, topology and automatic follow-up Sleep are excluded from hidden-source treatment; maximum overlay Restore timeout is 24 hours. One independent safety review found four concrete defects: authorization surviving journal revocation, crash cleanup latching Show, changed-main topology admission, and failed helper labelled watching. All four were corrected with targeted regression tests; parent inspected these fixes, with no second general review. Final parent verification: swift test --disable-sandbox -Xswiftc -warnings-as-errors passed the full suite; routine live-blackout/retained-ICC and two foreground keyboard fixtures skipped as configured. PANELCTL_RUN_NATIVE_DISPLAY_KEYBOARD_FIXTURES=1 swift test --disable-sandbox --filter DisplayHideAppTests.testNative -Xswiftc -warnings-as-errors passed all 8 native synthetic fixtures with no skips. Both swift build --product panelctl -Xswiftc -warnings-as-errors and swift build --product PanelCtlApp -Xswiftc -warnings-as-errors passed. git diff --check passed. LSP diagnostic report was unknown (bounded wait expired); compiler/tests provide verification. No live mirrored blackout, topology/DDC/private setter writes or hardware qualification performed; fake coverage revocation and native synthetic UI are not live WindowServer qualification. No remaining offline blocker or resumable implementation step. Any hardware trial requires fresh scoped human consent. No worktree created, no push performed; claim released.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented source-only overlay protection for journal-verified Hidden by PanelCtl, with fail-closed ongoing authorization, overlay cleanup before Show, truthful UI and no brightness/input/topology or automatic Sleep writes. Commit f02d11f; full offline tests, 8 native synthetic fixtures and both warnings-as-errors builds pass. Four independent-review findings fixed. Live hardware behavior remains unqualified.
<!-- SECTION:FINAL_SUMMARY:END -->
