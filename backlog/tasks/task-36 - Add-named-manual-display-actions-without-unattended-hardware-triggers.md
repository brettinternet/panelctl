---
id: TASK-36
title: Add named manual display actions without unattended hardware triggers
status: Done
assignee: []
created_date: '2026-10-05 22:30'
updated_date: '2026-10-06 15:28'
labels:
  - app
  - automation
  - display-hide
  - cli
dependencies:
  - TASK-35
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/AppControlServer.swift
  - Sources/PanelCtlCore/AppControl.swift
  - TASK-27
  - TASK-29
  - TASK-32
  - Sources/PanelCtlApp/DisplayHidePreferences.swift
  - Sources/PanelCtlApp/AutomationSettingsView.swift
  - Sources/PanelCtlCore/CLIParser.swift
  - Sources/PanelCtlCore/CLIHelp.swift
documentation:
  - docs/display-hide-ux.md
  - docs/display-handoff.md
  - docs/usage.md
priority: medium
type: feature
ordinal: 26010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Users want reusable display actions alongside protection rules, including handing a monitor to another computer from Shortcuts or Stream Deck, without converting safe idle protection into topology or input writes. Add deliberately invoked named actions in Automations, clearly separated from automatic rules. Reuse the existing Displays setup, app control and Hide/Show recovery rather than creating another hardware or recovery path. Initial scope is one exact display per action with exactly three effects: Black out, Remove from desktop (with its configured optional input handoff) or Show. A named action never falls back to a different effect, unlike the per-display Hide button. The plan fixes the list, editor, command and refusal wording. Multi-display scenes, toggles, arbitrary sequences, schedules, idle- or empty-triggered removal or input switching, DDC power and private disconnect remain deferred. TASK-31/TASK-32 remain separate work and must not be duplicated or assumed complete. Delivery is offline only; new hardware qualification requires separately scoped human approval.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Users can create, name, edit and delete single-display actions in an Actions section of Automations. Each row has Run and Edit; the editor shows a read-only Runs line (only when you choose Run or run its command), Display, Effect and a copyable bundled-CLI command using a stable action ID. There is no trigger picker, no menu bar item and no hotkey; startup, login, wake, reconnection and automation never run actions.
- [x] #2 Saved actions disclose the exact target and effect, including mirror source and away input for removal. Hardware setup stays in Displays, reached through a Set Up in Displays button. A change to the reviewed removal setup (Remove from desktop on/off, mirror source or away input) marks the action Needs review, disabling Run and refusing its command until saved again; Remove from desktop with Experimental features off is refused, never converted to Black out. Execution rechecks the reviewed configuration and identity.
- [x] #3 Actions reuse the current experimental consent, eligibility, last-visible safety, automation cleanup, operation serialization and journal recovery checks. Unsupported targets, busy state and unresolved recovery report actionable refusals inline and in the command result; no confirmation dialog, bypass, queued execution, automatic retry, fallback method or guessed identity is introduced.
- [x] #4 Hide and Show are desired-state operations: Hide already done with the same style and Show of a display that is not hidden are no-ops without another input write; Hide of a display hidden with the other style is refused. Show follows the actual outstanding Hide/recovery evidence rather than current setup, including after configuration changes or with Experimental features off. Existing per-display Show and recovery stay available if an action is edited or deleted.
- [x] #5 Activity, protection Restore, Escape on automation covers and Pause do not undo an action Hide or switch a monitor back from another computer. Results appear inline on the action row and display tile and distinguish desktop outcome, input outcome and recovery needed; an unavailable or lost response never triggers automatic resend.
- [x] #6 The app run-action command takes the action ID, uses the running app, never launches it, and reuses the hide/show outcomes and exit codes, with unknown IDs, needs review, Experimental off and style mismatch reported as refusals. Existing per-display hide/show/toggle-hide commands remain compatible. CLI help and docs explain command copying, state inspection after uncertain results and the difference between deliberately invoked commands and unattended built-in triggers.
- [x] #7 Fake-backed model, app-control, parser and UI tests cover setup drift, stable IDs across rename, repeated requests, contention, cleanup failure, missing targets, consent, style mismatch, partial input outcomes, deletion with outstanding recovery and absence of automatic execution. Native UI fixtures at 680 and 440 pt are inspected; full offline tests and warnings-as-errors builds pass. Docs distinguish implemented actions from hardware-qualified combinations and retain power/private-disconnect exclusions.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
0. Before claiming: confirm TASK-35 is Done; read the Automations tab/editor patterns it shipped and TASK-32’s state (multi-removal changes refusals and Show). Reuse, don’t fork, the per-display Hide/Show path in AppModel and its result store.

## Decisions (settled; do not reopen without the user)

- An **action** = one exact display + one effect, run only by a person: the row’s **Run** button or its CLI command (Shortcuts/Stream Deck). There is no trigger picker; the editor shows a read-only "Runs: Only when you choose Run or run its command."
- Effects (exactly three): **Black out** (Hide using Black out regardless of the display’s Hide style), **Remove from desktop** (Hide using the display’s Displays setup: mirror source and optional Switch monitor to), **Show** (undo whatever Hide/recovery evidence exists for that display). No Toggle effect (per-display `app toggle-hide` already exists), no multi-display scenes, no power/private disconnect.
- Named actions never fall back: Remove from desktop with Experimental features off or setup missing is refused, never converted to Black out (unlike per-display Hide’s documented fallback).
- Setup lives in Displays. The action stores the target `DisplayIdentitySnapshot` and, for removal, a reviewed fingerprint `‹removeEnabled, sourceUUID, awayInput›` (not `returnInput`, which detection updates). Any fingerprint difference → **Needs review**: Run disabled, command refused, editor shows the change (e.g. "Switch monitor to: HDMI 1 → HDMI 2"); Save re-snapshots. Black out and Show actions have no setup fingerprint.
- Desired-state semantics: Hide when already hidden by the same style = `no-op` (no input write); hidden by the other style = refused "Already hidden by ‹style›. Show it first."; Show when not hidden = `no-op`.
- Not in the menu bar menu; no global hotkeys; no confirmation before Run (matches tile Hide/Show); results inline, no dialogs.
- Automation never runs actions; Restore, activity, Escape on automation covers and Pause never undo them. Startup, login, wake and reconnection never run them.

## Automations tab additions

```
Section "Actions"   (below Rules)
  Hand off S2721DGF                        [Edit…] [Run]
  Remove DELL S2721DGF from desktop onto DELL AW3423DW · switch to HDMI 1
  Display is on                     ← or "Hidden", "Running…", "Unavailable: ‹reason›", ⚠ "Needs review: Displays setup changed"
  ‹last result line for this run, session-only, same text as the tile result›
  [Add Action…]
  footer: Actions run only when you choose Run or run their command. Automation, startup, wake and reconnection never run them.
```

- Summary names the actual effect: "Black out DELL S2721DGF", "Remove … from desktop onto … · switch to HDMI 1 | · don’t switch input", "Show DELL S2721DGF". Missing target: "DELL S2721DGF (unavailable)", Run disabled with reason.
- Run is disabled with a visible reason (not tooltip-only) when refused up front: needs review, Experimental off, target unavailable, operation busy, recovery needs attention. While running: "Running…", button disabled. Also show the result on the display tile (existing store).
- Empty state: "No actions." + Add Action… + footer.

## Action editor sheet

```
New Action / Edit Action
  Name     [Hand off S2721DGF      ]
  Runs     Only when you choose Run or run its command          (read-only)
  Display  [DELL S2721DGF ▾]   (stable-UUID displays only; saved missing target listed as "(unavailable)")
  Effect   [Black out | Remove from desktop | Show]
           Remove disabled with reason + [Set Up in Displays…] when Experimental is off or the display has no Remove from desktop setup
Effect details (read-only, from Displays; Remove only)
  Mirror onto        DELL AW3423DW
  Switch monitor to  HDMI 1 | Don’t switch
  ⚠ Displays setup changed since review: … Save to accept.
Command
  /Applications/PanelCtl.app/Contents/Helpers/panelctl app run-action --action ‹UUID›   [Copy]
  footer: For Shortcuts or Stream Deck. PanelCtl must be running; requests are never queued or retried.
────────────────────────────────────────────────
[Delete Action…]                         [Cancel] [Save]
```

- Defaults: name empty (required, unique case-insensitively among actions), Display = selected Displays tile if any, Effect = Black out. Rename never changes the ID or command.
- Delete Action… → alert "Delete “‹name›”?" message "Scripts that run its command will stop working. The display’s current state doesn’t change." Deleting never shows a display; the tile’s Show and recovery stay available.
- `Set Up in Displays…` uses `navigation.showDisplays(selecting:)`; no setup controls in this sheet.

## CLI and app control

- `panelctl app run-action --action UUID [--json]`: new `AppControlCommand.runAction` with additive `actionID` request field (protocol stays 1). Never launches the app (same as hide/show), waits up to 30 s, never queued or resent.
- Response/exit codes reuse the hide/show table (`done`, `no-op`, `refused`, `busy`, `failed`, `response-lost`, `partial`, `recovery-needed`). Unknown/deleted ID, needs review, Experimental off and style mismatch are `refused` (exit 1) with a specific `error`. `displays` carries state for inspection after uncertain results; no new status fields.
- Copy string generated like `AppControlCommand.commandLine` (shell-safe quoting of the bundled CLI path).
- Existing `hide|show|toggle-hide --display` unchanged.

## Steps

1. Model: `DisplayAction ‹id: UUID, name, target: DisplayIdentitySnapshot, effect, reviewedRemoval?›` persisted (versioned) beside the TASK-34 rule set; validation and review-state as pure functions.
2. Execution: thread an explicit hide style through the existing AppModel Hide path (today style comes from `hidePreferences[uuid].enabled` + Experimental), recheck fingerprint and identity under the existing operation lock, then call the same Hide/Show code (consent, eligibility, last-visible, automation quiescence, journal). No new hardware path.
3. App control + parser + CLI help (`CLIHelp.swift`) for `run-action`.
4. UI: Actions section, editor sheet, row state/results, Copy.
5. Tests with fakes: stable IDs across rename; drift → needs review for each fingerprint field; Experimental off refuses removal but Show works; style mismatch refusal; repeated Hide/Show no-op without input writes; busy/contention; cleanup failure refusal; missing target; consent; partial input outcomes; delete with outstanding removal keeps tile Show; relaunch/wake/reconnect/login run nothing; Restore/Pause don’t undo; parser/app-control round trips and exit codes. Fixtures at 680/440 pt: actions list (ready, hidden, needs review, unavailable), editor Remove with details, editor Remove disabled.
6. Docs: `docs/usage.md` (named actions, command copying, inspecting `app status --json` after `response-lost`), `docs/display-hide-ux.md` (actions vs per-display Hide, no fallback, deliberate vs unattended), `docs/display-handoff.md` cross-link; keep hardware-qualified combinations and power/private-disconnect exclusions explicit. Full suite, warnings-as-errors debug+release builds, `git diff --check`. No live writes; hardware qualification needs separate approval.

## Do not add

Toggle effect, multi-display or sequenced actions, schedules or any automatic trigger, menu-bar action items, hotkeys, Run confirmations, completion dialogs, retries/queues, setup editing inside the action sheet, power or private-disconnect effects.

Execution: implement the settled plan in an isolated Worktrunk checkout, offline only; one independent safety review, focused and full checks plus native fixtures, then commit, merge main, finalize task and remove only the owned checkout.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Claimed by Pi session 01a1118d-1cfa-717a-9b32-58a3c5a08ced. Worktrunk created /Users/brett/dev/me/panelctl/.worktrees/named-display-actions, branch named-display-actions, base 8d407a9e59986a8b1140b3d768ab84c4d19e2b2c. Ownership receipt .git/worktrees/named-display-actions/agent-creation.json; transcript /Users/brett/.pi/agent/sessions/--Users-brett-dev-me-panelctl--/2026-10-06T14-10-23-098Z_01a1118d-1cfa-717a-9b32-58a3c5a08ced.jsonl. Workflow cb3bd501-859b-4fe3-aa89-7011985859d3 implements settled scope then one independent safety review; parent owns backlog, acceptance, commits, integration and cleanup. Existing recovery-enable and sleep-hide-recovery are unrelated and retained untouched. Offline/fake validation only; no hardware writes. Next: consume implementation/review, fix concrete findings, verify and deliver.

Implementation completed after executor timeout/resume (b1bdd4c5 -> cf871893); original workflow cb3bd501 failed before review. Partial diff preserved at /tmp/panelctl-task36-timeout.diff, complete review diff /tmp/panelctl-task36-review.diff. Reported full offline suite 280 core +214 app, 7 skips, zero failures; four warnings-as-errors builds and six native 680/440 action fixture inspections passed. Parent checked final app test/build logs and diff check. LSP unknown (bounded diagnostic timeout), compiler evidence is authoritative. One independent review running as 129120af-0cab-4540-ada4-b973e15d329a. Main advanced to 43d4957 with unrelated ExperimentalDisconnectControls spacing change; preserve at integration. No hardware writes or commits yet. Next: consume review, fix scoped findings, integrate current main and validate, commit/merge and cleanup.

Delivered implementation 0cd6bfa; integrated concurrent main spacing change in afa55fc and fast-forwarded main to that tested merge. One independent review found four concrete defects, all fixed with regressions: non-executing replies preserve input warning/undo/status evidence and in-flight results; removal no-op requires verified hidden topology; unknown/unreadable recovery refuses Show no-op; default Black out editor exposes missing-removal setup guidance/navigation. Parent inspected corrected paths; no second general review. Final integrated full warnings-as-errors suite passed 280 core +218 app tests (498 total, 7 skips); opt-in native action fixtures separately rendered/inspected at 680/440 including first-use guidance, and production-editor navigation/Save/Cancel tests passed. Both products debug/release warnings-as-errors builds passed after integration; diff check passed. Logs: /tmp/panelctl-task36-integrated-tests.log and /tmp/panelctl-task36-integrated-{debug,release}-{cli,app}.log. LSP unknown, not claimed clean. No hardware writes, live qualification or push. Worktrunk list and original session receipt matched; removed owned named-display-actions checkout and branch, exact matching Herdr workspace absent before and after cleanup. Existing recovery-enable and sleep-hide-recovery retained as unrelated/user-owned. Claim released; no remaining blocker or owned checkout.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added named manual Black out, Remove from desktop and Show actions, stable-ID run-action CLI, setup review and inline recovery-aware results. All four independent review findings fixed and regression-tested. Integrated 0cd6bfa via afa55fc on main; 498 offline tests (7 skips), native fixtures and all four warnings-as-errors builds passed. Owned worktree/branch cleaned up; no push or hardware writes.
<!-- SECTION:FINAL_SUMMARY:END -->
