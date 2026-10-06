---
id: TASK-46
title: Coordinate multiple display steps in one named Action
status: Done
assignee: []
created_date: '2026-10-06 18:29'
updated_date: '2026-10-06 21:25'
labels:
  - app
  - automation
  - cli
  - display-hide
  - reviewed
dependencies:
  - TASK-36
  - TASK-32
references:
  - Sources/PanelCtlApp/DisplayActions.swift
  - Sources/PanelCtlApp/AutomationSettingsView.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/AppDelegate.swift
  - Sources/PanelCtlCore/AppControl.swift
  - Sources/PanelCtlCore/AppControlDisplayStatus.swift
  - Sources/PanelCtlCore/CLIHelp.swift
  - Tests/PanelCtlAppTests/DisplayActionAppTests.swift
  - Tests/PanelCtlAppTests/SettingsWindowTests.swift
  - TASK-32
  - TASK-36
  - TASK-44
documentation:
  - docs/usage.md
  - docs/display-hide-ux.md
  - docs/development.md
  - docs/display-recovery.md
priority: medium
type: feature
ordinal: 36010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Named Actions currently save one display command, offering little beyond an existing CLI script. Users want one Run button or command for a workflow such as Focus mode: remove the left and right displays while keeping a usable display on the Mac. The value over concatenated commands is whole-workflow validation, coordinated execution and an honest per-step result. Keep Action as the user-facing name and call its contents steps. This deliberately extends the one-display scope of TASK-36 without adopting general scripting or unattended automation; hardware setup stays in Displays.

Refinement findings (2026-10-06) that shape the criteria:
- The only display mutex is hideOperation, which is idle between Hides. Without a run-level lease, tiles, menu, scripts, other Actions, Show and Quit, quit, cleanup retry, Full disconnect and automation reconcile can interleave between steps.
- Remove and source Black out stop automation helpers and the last Show restarts them, so naive chaining churns helpers and lets automation start between steps.
- The CLI waits 30 s for one display command and app-control messages are capped at 4 KB (AppControlSocket.messageLimit); a multi-step run and its per-step reply can exceed both.
- A stored-Actions decode failure is silently replaced by an empty set and overwritten on the next save, so a schema change would lose Actions on corruption or downgrade.
- Combined checks must apply the same safety rules as per-display Hide/Show to the state projected after earlier steps, or preflight and execution will disagree.
- Hardware qualification covers only the TASK-32 same-order CLI round trip (S2721DGF then AW3425DW onto AW3423DW with input switching); app-driven and other combinations stay unqualified.

Kept as one task: splitting the model/editor from the coordinated run would ship savable multi-step Actions that cannot run. Scope is offline implementation and fake-backed validation only; this task does not authorize live topology or DDC writes or qualify new hardware combinations.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An Action has a name and 1–8 ordered steps. Each step targets one exact display by stable UUID with one existing effect — Hide (black out), Hide (remove from desktop) or Show — and Remove steps record that display’s reviewed setup. A display appears in at most one step per Action; empty Actions, duplicate displays and more than 8 steps cannot be saved.
- [x] #2 Existing one-display Actions load as one-step Actions with unchanged IDs, names, commands, effects and reviewed setup. Rename or step edits preserve the ID; deletion invalidates the command without changing display state or recovery evidence. Unreadable or newer-format stored Actions are reported in Automations and never replaced or overwritten, and running an older one-step build after upgrade does not erase multi-step Actions.
- [x] #3 The Action editor keeps the existing grouped sheet (Name, Steps, Command; Delete/Cancel/Save footer). Steps are numbered rows, each with Display and Effect pickers using the existing titles and, for Remove, the existing Mirror onto / Switch monitor to details, setup-change warning and Set Up in Displays… link. Add Step, Move Up, Move Down and Remove Step are keyboard- and VoiceOver-accessible buttons with step-numbered labels (no drag-only reorder); Remove Step is disabled for the only step. A new Action starts with one step on the selected display; Add Step defaults to an unused display. Validation names the step (“Step 2: …”); Return saves and Escape cancels; content scrolls without clipping.
- [x] #4 Conflicts that follow from the definition and reviewed setup alone block Save with the step identified: a Remove step whose reviewed mirror source an earlier step hides (black out or remove), and a step that removes a display an earlier Remove step mirrors onto. State-dependent conflicts, such as keeping a visible display, are checked when the Action runs.
- [x] #5 The Actions list keeps the existing row pattern (bold name, Edit…, Run, secondary summary, status line, inline result, no modal); one-step rows look and read as today. Multi-step rows show numbered step summaries (target, effect, reviewed removal setup) without hiding later steps at the 440 pt fixture width. Status shows Ready, Running step N of M…, or the first blocker prefixed by its step. After a run, each step reads done, already in state, stopped with its reason, or not run, with separate desktop and input lines, warnings in orange with the existing icon, selectable text, and Review in Displays… for a recovery-needed step.
- [x] #6 Run and `panelctl app run-action --action UUID` run the same saved workflow once, in order, only in the running app (never launching it). Existing hide, show, toggle-hide and one-step run-action behavior, outcomes and exit codes remain compatible. No nested Actions, scripts, conditions, delays, new effects, schedules, automatic triggers, queueing or retry are introduced.
- [x] #7 Before any display, input or automation-helper change, the whole Action is checked against one consistent snapshot: exact identity, reviewed-setup drift, Experimental consent, recovery and cleanup state, eligibility and, applying each step to the state projected by earlier steps, last-visible-display safety, mirror-source dependencies and Black out/Remove conflicts. The projection uses the same rules as per-display Hide/Show readiness (tests show a one-step Action and the matching tile action agree). A refusal names the step and writes nothing; no fallback effect or guessed identity. A step already in its desired state, determined with the same evidence as today (a Remove counts only when its removal is verified, and the other hide style never counts), is a no-op only in needing no write. It still passes every check one-step Actions apply before their no-op check: identity, reviewed setup, Experimental consent, recovery, cleanup, lifecycle and busy. It counts as current state for the checks on later steps, and tests cover each case where a step is already in its desired state but blocked.
- [x] #8 One run-level lease covers the whole run. While it is held, tiles, menu Hide/Show, scripted hide/show/toggle-hide/run-action, other Actions’ Run, Show and Quit, quit, Retry Automation Cleanup, Full disconnect and recovery repair are refused as busy with the running Action named, never queued or interleaved. The running Action’s Save and Delete are disabled until it finishes; other Actions stay editable. Requests received during the run stay refused after it finishes, while the run’s own steps never trip that stale-request guard.
- [x] #9 Automation helpers are quiesced at most once per run, before the first write that requires it, stay stopped across steps (reconcile does not relaunch them between steps), and automation is reconciled once after the run under existing rules. Each step refreshes display and recovery state once before starting and verifies its outcome with the existing per-display checks; the run adds no polling, sleeps, retries or extra whole-layout inspection, and progress updates do not block the main thread. Fake-backed tests count helper stops/starts and inspections.
- [x] #10 Steps run sequentially from the definition snapshot taken at start; edits or deletion cannot change a running run. Before each step PanelCtl rechecks identity, reviewed setup, Experimental consent, recovery and display lifecycle. A refused, failed, input-partial, recovery-needed or sleep/wake/reconfiguration-interrupted step stops the remaining steps. No automatic rollback, retry, resend or inverse Action.
- [x] #11 JSON results add an ordered steps array (index, target UUID, effect, outcome, desktop summary, input outcome/detail) and display statuses for every step target; text output gives one line per step. Aggregate outcome uses existing values and exit codes: recovery-needed if any step needs recovery; partial if any display changed but not every step reached its state; otherwise the stopping step’s refused, busy or failed when nothing changed; done when all steps are done or no-op with at least one done; no-op when all are no-op. Results never claim atomic success.
- [x] #12 The run-action reply wait covers 8 steps at the existing 30-second per-step budget, and a maximum-size reply (8 steps, worst-case messages, every target status) fits the app-control message limit, with tests. A lost, late or abandoned reply reports response-lost and never cancels, changes or reruns the in-app run; `app status --json` reports a running Action and its current step so callers can inspect before acting again.
- [x] #13 Completed steps keep their actual display state and per-display Show/recovery paths after later failure, quit, crash, Action edits or deletion. Show uses recorded recovery even after setup changes or Experimental features are turned off. Relaunch, login, wake, reconnection and protection controls neither resume an interrupted run nor undo its Hides; run results are session-only.
- [x] #14 Fake-backed model, app-control and CLI tests cover migration and unreadable/newer data, stable IDs, step limits and duplicates, save-time conflicts, projection/tile parity, multi-display Hide/Show, mixed effects, ordering, no-ops, missing targets, setup drift, every lease entry point, helper quiescence counts, mid-run state/definition changes, later-step failures, partial input, interruption, reply timeout/size and lost replies. Native UI fixtures at 680 and 440 pt show an unchanged one-step row, a multi-step list, running progress, a partial result with stopped and not-run steps, and the editor with mixed steps, a Remove setup warning and a step conflict. Full offline tests and warnings-as-errors builds pass without live display or input writes.
- [x] #15 CLI help, usage.md and display-hide-ux.md (including its Actions and deferred-chains text) explain multi-step Actions, manual invocation, ordered non-atomic execution, stop-on-problem, the busy lease, aggregate outcomes and steps output, recovery, and inspecting state after uncertain results. Documentation distinguishes offline coverage from the hardware-qualified TASK-32 combination and retains separate explicit approval for live writes.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend the existing Action model/editor to ordered bounded steps, preserving legacy IDs and protecting stored data with a separate versioned storage key so older builds cannot overwrite upgraded Actions. Reuse current presentation and validation patterns.
2. Reuse per-display readiness and execution checks for projected whole-run preflight; add one run-level lease across every competing entry point and suppress intermediate automation reconciliation. Preserve verified no-op checks and per-target recovery.
3. Extend app-control responses/status with ordered results and progress; cover eight per-step budgets and bound response payloads without changing existing command outcomes.
4. Add fake-backed regression coverage and native 680/440 fixtures, update help/docs, run full offline tests and warnings-as-errors builds. No real display/input writes.
5. One independent review focused on lease completeness, projected safety, persistence/downgrade protection and partial-result correctness; fix concrete findings and rerun affected checks. Parent verifies evidence, finalizes backlog and commits on main as requested.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User changed execution location from main to a worktree. Worktrunk created /Users/brett/dev/me/panelctl/.worktrees/multi-step-actions, branch multi-step-actions, base d0de5fdf766422bf510c6bbd77998d94847f0b94; verified receipt .git/worktrees/multi-step-actions/agent-creation.json records session 01a11274-4436-744c-80cc-72031f4810f3 and transcript /Users/brett/.pi/agent/sessions/--Users-brett-dev-me-panelctl--/2026-10-06T18-22-51-958Z_01a11274-4436-744c-80cc-72031f4810f3.jsonl. Executor 02b68fa4-c01b-438c-b0b4-728403155e8a asked to checkpoint and stop; source transfer awaits confirmed inactivity. Backlog stays on primary main. Unrelated TASK-47 and automation-remaining-displays worktree are not owned by this task. Current work is incomplete and uncommitted; offline only. Parent diagnosed and stopped a hung fake lease test, which needed deterministic action-start synchronization; full validation and independent review remain pending.

Migration complete: executor checkpoint confirmed inactive; all 11 TASK-46 source/test/doc diffs were applied to .worktrees/multi-step-actions, byte-for-byte patch equality verified, then the exact patch was reverse-applied on main. Main now contains only backlog changes (TASK-46 plus unrelated untracked TASK-47); all implementation edits are in the owned worktree. Backup patch /tmp/panelctl-task46-migration.patch. Focused DisplayActionAppTests passed 22 tests after deterministic lease-test synchronization fix. Remaining: broader criteria coverage, native fixtures, full offline suite/builds, independent safety review and commit. Original workflow 73efeade completed with implementation checkpoint only; review did not run.

Worktree implementation and 680/440 fixtures completed; executor reports full suite/builds passed. Parent reran warnings-as-errors suite: 283 core tests passed (2 skips); 250 app tests had only the existing native menu-arrow test fail (4 assertions), then that test passed in isolation. Both debug product builds passed. Parent inspected 440 partial/editor PNGs; LSP AppModel diagnostics unknown (bounded timeout), not clean. One independent review 0e993283 found six confirmed defects: deferred hidden-display reconciliation lost; preflight refusal omitted recovery cleanup; ordinary delayed display requests ignore Action finish timestamp; projected Show retains live mirror deps; corrupt legacy missing effect defaults to blackout; no-op/blocker replies bypass payload bounds. Retained executor resumed as 2b8c11f2 to fix these with targeted regressions and full checks; no second general review planned. Review artifact /Users/brett/.pi/agent/sessions/--Users-brett-dev-me-panelctl--/subagent-artifacts/outputs/0de79017-71db-4729-a847-e07f387153e2/task46-worktree-review.md. No commit or hardware writes. Main advanced independently with TASK-47; worktree remains based on d0de5fd.

Delivered implementation commit 6de658a on multi-step-actions. All six independent-review findings corrected and regression-tested; parent inspected corrected paths and final test/build logs. Final warnings-as-errors full suite: 283 core +255 app tests, 7 expected skips, zero failures, including native menu keyboard test unchanged. Both products debug warnings-as-errors builds passed; diff check clean. Evidence: /tmp/panelctl-task46-followup-{focused,full,cli-build,app-build}.log. Native 680/440 Actions list/progress/partial/editor fixtures rendered and inspected separately at /tmp/panelctl-task46-fixtures; parent inspected narrow partial/editor examples. Storage/limits/conflicts/projection/no-op/lease/quiescence/interruption/recovery/result/server-encoding criteria covered by 35 DisplayActionAppTests plus AppControlTests and native SettingsWindowTests; docs/help updated. LSP remains unknown, compiler/test evidence authoritative. No live hardware writes or new qualification. User superseded the original main-only plan with worktree execution: source commit stays on multi-step-actions, not merged or pushed; primary main independently advanced with TASK-47. Retained clean owned checkout /Users/brett/dev/me/panelctl/.worktrees/multi-step-actions and hook-created workspace pending integration, not removed because implementation is intentionally unmerged. Original receipt and session evidence recorded above; all delegated work complete, claim released.

Review: fixed automation helpers never restarting after an Action that quiesced them (reconcile once at lease end); a step whose fresh state needs a write after an all-no-op preflight is now refused instead of writing with helpers running; replaced string-matched save errors with typed validation. Regression tests added. Commit 6e1103e on multi-step-actions (still unmerged; branch based on d0de5fd and will conflict with TASK-47 in AppModel overlay reconciliation). Full warnings-as-errors suite (283 core, 257 app) and both builds passed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added named Actions with 1–8 ordered display steps, protected legacy migration/storage, whole-run projected preflight and busy lease, coordinated helper cleanup, progress and per-step CLI/UI results. Fixed six independent safety-review findings. Commit 6de658a on multi-step-actions; full offline warnings-as-errors suite passed 538 tests with 7 skips, both product builds and native 680/440 fixtures verified. No live writes, push or merge. Worktree retained for integration.
<!-- SECTION:FINAL_SUMMARY:END -->
