---
id: TASK-19
title: Expose app hide and show to scripts without unattended hiding
status: Done
assignee: []
created_date: '2026-10-04 17:13'
updated_date: '2026-10-04 22:41'
labels:
  - display-hide
  - app
dependencies:
  - TASK-17
references:
  - Sources/PanelCtlApp/AppControlServer.swift
  - Sources/PanelCtlApp/AppDelegate.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - Sources/PanelCtlCore/CLIParser.swift
  - docs/usage.md
priority: medium
type: feature
ordinal: 9010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Scripts and Shortcuts control the app through panelctl app, while the Automation page runs unattended idle and empty-display protection. Direct panelctl mirror/away/back already serve scripts that pass UUIDs and journals; app actions add invocation by saved per-display configuration and serialization with app state. Add explicit hide/show app actions using the TASK-17 configuration (including TASK-18 inputs once present) without conflating them with unattended OLED protection. Do not build a rules engine or repurpose existing app enable/disable/toggle. Offline implementation and fake/no-write validation only; any live mirror/unmirror or DDC write needs fresh scoped human approval.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Documented panelctl app actions hide and show a configured display using the same settings, identity guards, confirmation policy and journal ownership as the UI. Headless calls that would need confirmation fail actionably instead of hanging on a dialog or bypassing the gate.
- [x] #2 Existing app enable/disable/toggle, blackout-now, restore, snooze/resume and sleep-now keep their documented meaning, except any Restore extension approved in TASK-16. Status JSON adds per-display observed hide state, operation progress, recovery-needed and skipped/partial input outcomes without presenting saved configuration as observed state.
- [x] #3 Requests serialize with UI and CLI mutations. Repeating hide or show on an already hidden or shown display is a reported no-op, never a toggle or a repeated DDC write; conflicting, stale-target and lost-response cases are tested.
- [x] #4 Idle and empty-display triggers stay overlay-only: no automatic hide, input switch or private disconnect, no empty-display hide feedback loop and no startup/wake re-hide. Any unattended hide policy needs a separately approved task.
- [x] #5 Scripts get documented exit codes and machine-readable outcomes for refusal, app unavailable, confirmation required, partial completion and recovery-needed; show works regardless of protection enablement or snooze.
- [x] #6 docs/usage.md gains script/Shortcuts examples, and fake end-to-end control-protocol tests cover success, duplicate/concurrent requests, protection interaction and failures; relevant tests and builds pass without hardware writes.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend the existing app protocol and CLI with UUID-scoped hide/show requests, typed outcomes and observed display status; preserve existing actions.
2. Route headless requests through current model readiness/journal checks: no-op for verified desired state, busy/refusal/recovery otherwise, confirmation-required for changes under the approved repeat-confirmation contract. Never open a modal or write hardware from headless calls.
3. Expose current operation and last session input result, keep protection/lifecycle behavior unchanged, and prohibit retry after a lost hide/show response.
4. Exercise parser, protocol socket and fake model paths including duplicates, concurrency, stale identity, recovery and protection; run warnings-as-errors tests/builds, one safety review, update docs and commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented UUID-scoped app hide/show with no-op or actionable headless confirmation refusal under the approved per-operation UI consent contract. Added observed per-display status, busy/recovery/partial outcomes, session-only last input evidence, documented exits and Shortcuts examples. No automatic hide/show path, modal, or consent bypass added; no hardware writes performed. Fake end-to-end socket tests exercise duplicate/concurrent requests, UI progress, configuration/identity refusal, disabled/snoozed Show, skipped/failed inputs, unresolved recovery, oversized status, and lost responses without retry. Fresh validation: swift test --build-system native --disable-sandbox -Xswiftc -warnings-as-errors passed 289 tests, 4 opt-in skips, zero failures; native warnings-as-errors builds for panelctl and PanelCtlApp passed. Default PanelCtlApp build also passed, with existing SDK actor-isolation warnings in DisplayOperationConfirmation. LSP report unknown (timeout), not claimed clean. Independent safety review pending before finalization/commit.

Delivery: 2dfafdf on main. Single independent safety review identified two concrete reporting defects, both fixed: hidden journal with canShow=false now yields recovery-needed (exit 6) rather than healthy Hide no-op/status; legacy action responses omit unrelated display arrays, so oversized status cannot misreport a completed toggle as refused. Socket regressions cover both and verify no extra writer/toggle calls. Final fresh full native warnings-as-errors suite: 290 tests, 4 opt-in skips, 0 failures; panelctl and PanelCtlApp native warnings-as-errors builds and git diff --check passed. AC1/3/5/6: fake end-to-end socket requests and parser/transport tests verify confirmation-required, no-op, concurrency, stale identity/journal, protection interaction, partial and recovery exits; no dialogs or hardware writes. AC2: legacy parser/protection tests plus overflow toggle regression pass; per-display observed/progress/input JSON asserted. AC4: existing fake lifecycle/protection coexistence tests pass; reviewer found no new topology/DDC mutation path. No further general review performed after these bounded corrections. No worktree created, no push, no live qualification claimed. Remaining limitations are intentional: actual changes require UI confirmation; input results are session-only; native keyboard/live blackout/ICC opt-ins were not run. No implementation blocker or resumable step remains; claim released.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added UUID-scoped app hide/show with actionable confirmation-required instead of unattended writes, idempotent observed no-ops, machine-readable display/input/recovery status and documented script/Shortcuts exits. Committed as 2dfafdf on main. Verified by 290 offline tests (4 opt-in skips), warnings-as-errors builds, diff check and one independent review with both findings fixed.
<!-- SECTION:FINAL_SUMMARY:END -->
