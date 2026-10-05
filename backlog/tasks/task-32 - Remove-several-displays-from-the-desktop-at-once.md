---
id: TASK-32
title: Remove several displays from the desktop at once
status: In Progress
assignee:
  - '@pi'
created_date: '2026-10-05 19:42'
updated_date: '2026-10-05 22:31'
labels:
  - app
  - cli
  - display-hide
  - mirror
  - human-gated
dependencies:
  - TASK-31
references:
  - Sources/PanelCtlCore/RecoveryJournal.swift
  - Sources/PanelCtlCore/DisplayMirroring.swift
  - Sources/PanelCtlCore/DisplayHandoff.swift
  - Sources/PanelCtlCore/DisplayHide.swift
  - Sources/PanelCtlApp/AppModel.swift
  - TASK-13
  - TASK-17
  - TASK-26
documentation:
  - docs/display-hide-ux.md
  - docs/display-recovery.md
  - docs/display-mirroring.md
  - docs/display-handoff.md
  - docs/usage.md
priority: medium
type: feature
ordinal: 22010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user hands several monitors to another computer at once. On the recorded setup the DELL S2721DGF and AW3425DW both use Remove from desktop onto the main Dell AW3423DW with DDC input switching, and the K272HUL uses Black out. Once one display is removed, every other Remove-from-desktop Hide is refused ('Only one display can be removed at a time'), so only one monitor can go to the other computer; Black out already allows several (TASK-26). The limit is PanelCtl's recovery design from TASK-13 and TASK-17, not macOS: one journal (Recovery/current.json) that a new capture can't replace while unresolved, mirror capture that refuses any existing mirror, Show restoring that journal's whole snapshot (which would undo other removals), and Hide setup frozen for every display while any journal is unresolved. macOS can rearrange the remaining displays when one joins a mirror set, and removing the main display (TASK-31) moves the origin every position is relative to, so a display's saved position can depend on displays removed before or after it. The user also wants the last display protected: in any mix of styles and order, the Mac keeps at least one visible display on its desktop. Private disable (TASK-9, TASK-20) shares the journal and keeps its single-transaction guarantees. Only the cycles recorded in docs/display-mirroring.md and docs/display-handoff.md are hardware-qualified; each new combination needs the user's approval before it runs on real displays.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With Experimental features on, two or more displays configured for Remove from desktop can be removed at the same time, in any order, from tiles, the menu and scripts, including several onto the same source. Each display's tile, menu item and app status entry shows its own state, and each display's Hide setup stays editable unless that display is removed or mid-operation.
- [ ] #2 Show on any removed display, in any order, returns only that display to the desktop and switches its input back as configured; the others stay removed. After the last Show, the arrangement, modes and main display match the layout from before the first removal, including when a removal moved the main display, verified as strictly as single-display Show is today. Any mismatch keeps recovery instead of reporting success.
- [ ] #3 Each removal is recoverable on its own: its topology is recorded durably before any change; a failed or interrupted Hide or Show leaves other removals' recovery intact; macOS restoring a display itself (for example after wake) resolves only what it matches; a disconnected removed display keeps its own recovery-needed state. Healthy removals never block other Hides; recovery that needs attention blocks new removals until resolved.
- [ ] #4 In every combination of styles and order, the Mac keeps at least one visible display on its desktop. Hide refuses, with the reason on the tile, menu and script reply: removing a display other removed displays mirror onto, removing onto a removed or blacked-out display, and hiding the last visible display. Removed displays never count as visible.
- [ ] #5 Automation stays paused while any display is removed and restarts only after the last Show, and the hidden-mirror source overlay (TASK-21) applies to every source in use. The recovery banner and card, Review Display Recovery and the quit prompt's Show and Quit handle several removed displays.
- [ ] #6 The CLI stays correct with several removals: recovery status reports each; back, unmirror, recovery verify and recovery restore have documented behavior for several removals and refuse ambiguous requests; mirror and away can add a removal beside healthy ones. Journals from older builds still show and recover. Private disable refuses while any removal is unresolved, and removal refuses while a private-disable journal is unresolved.
- [ ] #7 Fake-topology tests cover two and three removals shown in every order, shared and distinct sources, main-display removal combined with others, macOS rearranging displays on mirror, failure or interruption during a second Hide or first Show, wake self-restore, disconnection of one removed display, refusals, relaunch with several removals, legacy journals and CLI ambiguity. Full offline suite and warnings-as-errors builds pass with no real topology writes.
- [ ] #8 display-hide-ux.md, display-recovery.md, display-mirroring.md and usage.md describe several removals, Show order and what's qualified. A supervised trial, each write separately approved by the user, removes the S2721DGF and then the AW3425DW onto the AW3423DW with input switching and shows them in the same order, recording arrangement, modes and verification. Untested combinations stay unsupported.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend the existing locked, atomically saved recovery journal with a versioned public-mirror session: immutable pre-first-Hide layout plus independently identified per-display removals, each with write-ahead topology and operation state. Preserve legacy recovery and private-disable single-transaction behavior. 2. Implement per-target Hide/Show and strict partial-layout verification without replaying other removals; restore and verify the exact original arrangement, modes and main display on final Show. Reconcile only proven system restorations, retaining disconnected/failed entries. 3. Update app/menu/scripts, source overlays, automation pause, recovery/quit UI and per-display setup eligibility; enforce visible-survivor and source protections across both Hide styles. 4. Make CLI selection explicit where several entries make a command ambiguous; document status, back, unmirror, verify and restore behavior. 5. Add fake-topology permutation, interruption, relaunch, legacy and ambiguity coverage; run full offline suite and warnings-as-errors builds, then one independent safety review. 6. Obtain separately scoped approval for each required live-trial write, record exact qualification evidence, commit and merge authorized changes to main, and clean only the session-owned worktree. Architecture plan requires approval before source implementation.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Claimed by Pi session 01a10e2f-abc7-743d-bd4d-d5742cdb4439. Created .worktrees/multi-display-removal on branch multi-display-removal using Worktrunk; ownership receipt is .git/worktrees/multi-display-removal/agent-creation.json. Existing recovery-enable worktree is unrelated and must remain untouched. Primary main advanced concurrently to 27e9935; preserve unrelated backlog work. Inspected RecoveryJournal, MirrorController, DisplayHideController, RecoverySnapshot verification and public restoration: current singleton assumptions span persistence, whole-layout restore and app status. Proposed one atomic session document rather than independently written files, so baseline and all per-display recovery entries remain crash-consistent. No source changes or display/DDC writes yet. Next: approve architecture plan, then implement and validate offline; hardware approval is separate.

User approved the proposed atomic session journal architecture in-session: original baseline plus per-display removal entries, per-target Show, exact final-layout verification, legacy compatibility and private-disable safeguards. Approval covers offline implementation/review only; each live write still requires separate approval.
<!-- SECTION:NOTES:END -->
