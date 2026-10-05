---
id: TASK-31
title: Remove the main display from the desktop
status: Done
assignee: []
created_date: '2026-10-05 19:42'
updated_date: '2026-10-05 22:29'
labels:
  - app
  - cli
  - display-hide
  - mirror
  - human-gated
dependencies: []
references:
  - Sources/PanelCtlCore/DisplayMirroring.swift
  - Sources/PanelCtlCore/RecoveryJournal.swift
  - Sources/PanelCtlCore/DisplayHide.swift
  - Sources/PanelCtlApp/AppModel.swift
  - TASK-13
documentation:
  - docs/display-hide-ux.md
  - docs/display-mirroring.md
  - docs/display-handoff.md
  - docs/display-recovery.md
priority: medium
type: feature
ordinal: 21010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user wants to remove whichever display is main from the desktop, for example to hand the main Dell AW3423DW to another computer while the Mac keeps working on its other displays. Remove from desktop refuses the main display by design (TASK-13): mirror capture, journal validation and post-mirror verification all require a non-main target and an unchanged main display, and the app says 'The main display can't be removed from the desktop.' Black out of the main display already works, and the workaround is to make another display main in System Settings → Displays first. macOS decides the outcome, not PanelCtl: the menu bar, Dock, windows, Spaces and the (0, 0) origin every other display is positioned from may move. Apple's CGGetActiveDisplayList documentation says that while mirroring the main display is 'the largest drawable display in the mirror set, or, if all displays are the same size, the one with the deepest pixel depth', so CGMainDisplayID may even keep reporting the removed display; observe the result rather than assume it. Recovering by hand means turning off mirroring and dragging the menu bar back in System Settings → Displays. The main display is also today's default and only hardware-qualified mirror source, so a main target has no qualified default. Several-at-once removal builds on this so it can design for a moving main display.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 With Experimental features on, the current main display can use Remove from desktop from tiles, the menu and scripts when it's an otherwise eligible external display. Built-in displays and displays without a stable ID stay ineligible.
- [x] #2 A main display's setup never defaults to mirroring onto itself; Hide shows a reason until the user chooses a source. The setup explains that macOS decides where the menu bar, Dock, windows and Spaces go. Existing configurations and other displays' default source don't change.
- [x] #3 Hide succeeds when the target is verified mirrored onto its source and every other captured property still matches, whichever display macOS then reports as main. That layout counts as hidden by PanelCtl, not recovery-needed, in the app, scripts, CLI mirror and away, and recovery status.
- [x] #4 Show from the app, scripts, CLI back or unmirror, and recovery restore makes the original display main again with the captured arrangement and modes, and verifies it. On mismatch it keeps recovery and gives the manual steps (turn off mirroring, drag the menu bar back in System Settings → Displays) without reporting success.
- [x] #5 Fake-topology tests cover main moving to the source, staying on the removed display or moving elsewhere; main changing again while hidden (for example across sleep and wake); Show restoring main; verification mismatch; and refusals. Full offline suite and warnings-as-errors builds pass with no real topology writes.
- [x] #6 Docs describe the main-display behavior as observed and what's qualified. A supervised trial, each write separately approved by the user, removes the main AW3423DW onto a display the user chooses and shows it, recording where the menu bar, Dock and (0, 0) origin went and the verified restoration. Untested combinations stay unsupported.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Allow eligible main mirror targets without changing private-disable eligibility; share strict hidden-topology verification that tolerates main reassignment only for a captured main target. Preserve exact restore verification and manual recovery guidance. 2. Remove app main-target refusal, require an explicit distinct source for new main-target setup, explain macOS placement behavior, and cover app/menu/script paths with fakes. 3. Add fake topology and restoration regressions, update qualification docs, run full offline suite and warnings-as-errors builds, then one independent safety review. 4. Request separately scoped human approval for the required live trial; never perform hardware writes from test success. Commit, integrate into main, record evidence/blocker, and clean up the owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Offline implementation committed fa26adf in session-owned .worktrees/main-display-removal. Full serialized warnings-as-errors suite passed: 245 core + 148 app tests (4 opt-in skips); both panelctl and PanelCtlApp warnings-as-errors builds passed; native main-target setup fixture inspected. Independent reviewer found no validated defects. LSP diagnostics unknown (bounded report timeout), compiler/tests provide validation. User elected supervised trial, chose AW3425DW as source, and confirmed presence, usable survivor, paused competing topology automation and manual System Settings fallback. Fresh read-only inventory: Mac17,14 / 26A434; target main AW3423DW UUID 1FC57E99-DE7C-4DAF-B896-3B512CEE064F (ID 5), source AW3425DW UUID A8D3635B-35EC-4171-BBE2-95FB8CF76111 (ID 2); all four displays awake. Default journal currently restored. No hardware write performed or authorized yet. Next: explicit approval for one public mirror write without DDC, inspect, then separate approval for restore. Preserve unrelated primary experimental-disconnect edits.

User approved one mirror attempt AW3423DW -> AW3425DW. Command refused before capture/transaction: recovery is busy or lock permissions are unsafe. lsof identified unrelated primary-checkout RecoveryLeaseTests helper PID 27759 holding operation.lock under core suite PID 86135. Read-only inventory unchanged; no display write occurred. User chose to wait for those tests to finish, then receive a fresh write-approval request. Watch c8b416c5 resumes on both processes exiting; no lock bypass or process termination. Trial/merge/cleanup remain pending.

Supervised cycle passed on fa26adf: fresh separately approved mirror AW3423DW -> AW3425DW returned mirrored, journal F768EE67-6C81-46C9-93B7-3336E743D67D. Source became main at (0,0); target inactive/non-main; S2721DGF y moved -4 -> 0. User confirmed menu bar/Dock moved to AW3425DW and usable. Separately approved unmirror restored all exact captured modes/origins and AW3423DW main; separate recovery verify passed (restored), user confirmed menu bar/Dock back and usable. No DDC/private writes. Docs/help and updated qualification assertions committed 55da411; final focused 39 tests and both warnings-as-errors builds passed. Only this CLI cycle is qualified; other combinations/live app paths/input switching remain unqualified. Implementation/review and all acceptance criteria complete; delivery pending merge because unrelated ongoing main edits overlap AppModel/DisplaySettingsView/SettingsWindowTests. User explicitly chose to wait for their commit, not stash. Next: refresh clean main, merge branch preserving concurrent committed changes, run integration checks, finalize task and clean owned worktree. Ownership receipt .git/worktrees/main-display-removal/agent-creation.json belongs to session 01a10e04-e742-7226-b088-b7e4930485d2; created at e7a9d5d863af4294ef60d09c5a42297efb1e648e. Prior recovery-enable worktree is unrelated and must remain untouched.

Delivered: merged into main as 19d39b3 after concurrent work committed. Resolved only DisplaySettingsView copy conflict, preserving concise non-main wording and main-target placement explanation. Final integrated full suite passed: 245 core + 150 app tests, 4 opt-in skips, no failures; panelctl and PanelCtlApp warnings-as-errors builds passed. Removed session-owned main-display-removal worktree and branch via Worktrunk after receipt/list verification; no matching Herdr workspace or panes existed before cleanup, post-remove hook succeeded. Unrelated recovery-enable checkout retained untouched. No remaining blocker or resumable work for this item; no push performed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Main external displays now support guarded Remove from desktop with explicit source selection, main-aware hidden-state verification, and exact original-main restoration. Integrated in 19d39b3 (implementation fa26adf, trial evidence 55da411). Independent safety review found no defects; merged full offline suite and warnings-as-errors builds passed. Separately approved AW3423DW -> AW3425DW mirror/unmirror cycle passed with user-confirmed menu bar/Dock movement and restoration plus exact recovery verification; only that documented setup is qualified. Worktree/branch cleaned up; claim released.
<!-- SECTION:FINAL_SUMMARY:END -->
