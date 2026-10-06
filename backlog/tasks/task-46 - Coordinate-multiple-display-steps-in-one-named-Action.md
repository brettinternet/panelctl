---
id: TASK-46
title: Coordinate multiple display steps in one named Action
status: To Do
assignee: []
created_date: '2026-10-06 18:29'
updated_date: '2026-10-06 18:37'
labels:
  - app
  - automation
  - cli
  - display-hide
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
- [ ] #1 An Action has a name and 1–8 ordered steps. Each step targets one exact display by stable UUID with one existing effect — Hide (black out), Hide (remove from desktop) or Show — and Remove steps record that display’s reviewed setup. A display appears in at most one step per Action; empty Actions, duplicate displays and more than 8 steps cannot be saved.
- [ ] #2 Existing one-display Actions load as one-step Actions with unchanged IDs, names, commands, effects and reviewed setup. Rename or step edits preserve the ID; deletion invalidates the command without changing display state or recovery evidence. Unreadable or newer-format stored Actions are reported in Automations and never replaced or overwritten, and running an older one-step build after upgrade does not erase multi-step Actions.
- [ ] #3 The Action editor keeps the existing grouped sheet (Name, Steps, Command; Delete/Cancel/Save footer). Steps are numbered rows, each with Display and Effect pickers using the existing titles and, for Remove, the existing Mirror onto / Switch monitor to details, setup-change warning and Set Up in Displays… link. Add Step, Move Up, Move Down and Remove Step are keyboard- and VoiceOver-accessible buttons with step-numbered labels (no drag-only reorder); Remove Step is disabled for the only step. A new Action starts with one step on the selected display; Add Step defaults to an unused display. Validation names the step (“Step 2: …”); Return saves and Escape cancels; content scrolls without clipping.
- [ ] #4 Conflicts that follow from the definition and reviewed setup alone block Save with the step identified: a Remove step whose reviewed mirror source an earlier step hides (black out or remove), and a step that removes a display an earlier Remove step mirrors onto. State-dependent conflicts, such as keeping a visible display, are checked when the Action runs.
- [ ] #5 The Actions list keeps the existing row pattern (bold name, Edit…, Run, secondary summary, status line, inline result, no modal); one-step rows look and read as today. Multi-step rows show numbered step summaries (target, effect, reviewed removal setup) without hiding later steps at the 440 pt fixture width. Status shows Ready, Running step N of M…, or the first blocker prefixed by its step. After a run, each step reads done, already in state, stopped with its reason, or not run, with separate desktop and input lines, warnings in orange with the existing icon, selectable text, and Review in Displays… for a recovery-needed step.
- [ ] #6 Run and `panelctl app run-action --action UUID` run the same saved workflow once, in order, only in the running app (never launching it). Existing hide, show, toggle-hide and one-step run-action behavior, outcomes and exit codes remain compatible. No nested Actions, scripts, conditions, delays, new effects, schedules, automatic triggers, queueing or retry are introduced.
- [ ] #7 Before any display, input or automation-helper change, the whole Action is checked against one consistent snapshot: exact identity, reviewed-setup drift, Experimental consent, recovery and cleanup state, eligibility and, applying each step to the state projected by earlier steps, last-visible-display safety, mirror-source dependencies and Black out/Remove conflicts. The projection uses the same rules as per-display Hide/Show readiness (tests show a one-step Action and the matching tile action agree). A refusal names the step and writes nothing; no fallback effect or guessed identity. Steps already in their desired state are no-ops and do not block.
- [ ] #8 One run-level lease covers the whole run. While it is held, tiles, menu Hide/Show, scripted hide/show/toggle-hide/run-action, other Actions’ Run, Show and Quit, quit, Retry Automation Cleanup, Full disconnect and recovery repair are refused as busy with the running Action named, never queued or interleaved. The running Action’s Save and Delete are disabled until it finishes; other Actions stay editable. Requests received during the run stay refused after it finishes, while the run’s own steps never trip that stale-request guard.
- [ ] #9 Automation helpers are quiesced at most once per run, before the first write that requires it, stay stopped across steps (reconcile does not relaunch them between steps), and automation is reconciled once after the run under existing rules. Each step refreshes display and recovery state once before starting and verifies its outcome with the existing per-display checks; the run adds no polling, sleeps, retries or extra whole-layout inspection, and progress updates do not block the main thread. Fake-backed tests count helper stops/starts and inspections.
- [ ] #10 Steps run sequentially from the definition snapshot taken at start; edits or deletion cannot change a running run. Before each step PanelCtl rechecks identity, reviewed setup, Experimental consent, recovery and display lifecycle. A refused, failed, input-partial, recovery-needed or sleep/wake/reconfiguration-interrupted step stops the remaining steps. No automatic rollback, retry, resend or inverse Action.
- [ ] #11 JSON results add an ordered steps array (index, target UUID, effect, outcome, desktop summary, input outcome/detail) and display statuses for every step target; text output gives one line per step. Aggregate outcome uses existing values and exit codes: recovery-needed if any step needs recovery; partial if any display changed but not every step reached its state; otherwise the stopping step’s refused, busy or failed when nothing changed; done when all steps are done or no-op with at least one done; no-op when all are no-op. Results never claim atomic success.
- [ ] #12 The run-action reply wait covers 8 steps at the existing 30-second per-step budget, and a maximum-size reply (8 steps, worst-case messages, every target status) fits the app-control message limit, with tests. A lost, late or abandoned reply reports response-lost and never cancels, changes or reruns the in-app run; `app status --json` reports a running Action and its current step so callers can inspect before acting again.
- [ ] #13 Completed steps keep their actual display state and per-display Show/recovery paths after later failure, quit, crash, Action edits or deletion. Show uses recorded recovery even after setup changes or Experimental features are turned off. Relaunch, login, wake, reconnection and protection controls neither resume an interrupted run nor undo its Hides; run results are session-only.
- [ ] #14 Fake-backed model, app-control and CLI tests cover migration and unreadable/newer data, stable IDs, step limits and duplicates, save-time conflicts, projection/tile parity, multi-display Hide/Show, mixed effects, ordering, no-ops, missing targets, setup drift, every lease entry point, helper quiescence counts, mid-run state/definition changes, later-step failures, partial input, interruption, reply timeout/size and lost replies. Native UI fixtures at 680 and 440 pt show an unchanged one-step row, a multi-step list, running progress, a partial result with stopped and not-run steps, and the editor with mixed steps, a Remove setup warning and a step conflict. Full offline tests and warnings-as-errors builds pass without live display or input writes.
- [ ] #15 CLI help, usage.md and display-hide-ux.md (including its Actions and deferred-chains text) explain multi-step Actions, manual invocation, ordered non-atomic execution, stop-on-problem, the busy lease, aggregate outcomes and steps output, recovery, and inspecting state after uncertain results. Documentation distinguishes offline coverage from the hardware-qualified TASK-32 combination and retains separate explicit approval for live writes.
<!-- AC:END -->
