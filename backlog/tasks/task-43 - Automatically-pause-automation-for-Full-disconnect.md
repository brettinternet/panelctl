---
id: TASK-43
title: Automatically pause automation for Full disconnect
status: Done
assignee: []
created_date: '2026-10-06 16:20'
updated_date: '2026-10-06 17:09'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/ProtectionCoordinator.swift
  - Sources/PanelCtlApp/ExperimentalDisconnectControls.swift
  - Sources/PanelCtlCore/DisplayDisconnect.swift
  - TASK-42
  - TASK-34
documentation:
  - docs/display-disable.md
  - docs/display-hide-ux.md
ordinal: 33010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Full disconnect currently requires users to turn off the Automation master switch even though the safety requirement is verified quiescence, not a persistent preference change. Make this manual experimental operation coordinate its own temporary automation pause so users do not have to disable and later re-enable protection. Existing disconnect recovery gating and multi-rule cleanup provide related behavior to reuse. Scope is offline implementation and fake-backed validation only; no live private setter, DDC, topology or recovery writes are authorized. Retain manual per-operation consent and all existing disconnect safeguards; this does not authorize unattended disconnect.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 With Automation enabled, a user can request Full disconnect without changing the master switch or rule settings; all automation helpers stop and covers and saved brightness are verified cleaned up before any disconnect write. Pending or failed cleanup prevents disconnect and exposes an actionable reason.
- [x] #2 Automation remains paused during disconnect preparation, consent, the active lease and unresolved recovery. Timer ticks, snooze expiry, preference changes and automation commands cannot restart treatment during that pause.
- [x] #3 After cancellation or pre-write refusal with no unresolved recovery, or after verified recovery of a performed disconnect, eligible automation resumes with a fresh countdown. Preserve the current master and rule settings, existing snooze deadline and deliberate user changes; do not enable automation that the user left off or bypass other safety blocks.
- [x] #4 Lease expiry or helper exit alone never counts as successful recovery. Failed or unreadable recovery state remains blocking across relaunch, keeps journal evidence and exposes recovery controls without automatically replaying a disconnect or private recovery write.
- [x] #5 Retain fresh one-use consent, confirmation-time revalidation, strict identity and survivor checks, bounded session-only lease, hidden-display and recovery refusals, and existing restrictions on scripting and unattended disconnect.
- [x] #6 Fake-backed regressions cover enabled, disabled and snoozed automation, multiple-rule cleanup and failure, cancellation and refusal, consent expiry, restart races, successful and failed recovery, relaunch and user preference changes. Synthetic UI and documentation explain temporary pausing and recovery blocks rather than requiring Turn Off Automation; relevant offline tests and builds pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reuse the existing app-side stopManagedProtection and coordinator cleanup boundary to hold a temporary disconnect pause across preparation, consent, lease and recovery without rewriting preferences. Audit all automation entry points and fail closed on inspection errors. 2. Update disconnect UI/status and docs; add fake-backed lifecycle, cleanup, preference and race regressions plus synthetic native UI coverage. 3. Run relevant offline tests and both product builds, obtain one independent safety review focused on restart races and recovery evidence, fix concrete findings, then commit and finalize the task.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete on main without hardware writes. Original executor a83eb16f timed out; partial diff captured at /tmp/panelctl-task43-timeout.diff and same worker resumed as 27a69671 to finish. Parent reran full offline swift test (log /tmp/panelctl-task43-final-tests.log), both product warnings-as-errors builds and release-version script; all passed. Synthetic pause and unreadable-recovery PNGs inspected in /tmp/panelctl-task43-ui. ProtectionCoordinator LSP clean; AppModel diagnostics unknown, compiler/tests passed. Independent safety review 34a95ced-b089-45fc-9c4b-97912fcc08ed pending; no acceptance checked or commit yet. Unrelated TASK-44 preserved.

Delivered 585ddc4 on main. Independent safety review 34a95ced found one P2: resolved disconnect journal could precede helper lock release, caching a busy handoff result and stranding automation. Corrected by retaining pause and retrying read-only handoff inspection until clear. Red/green regression demonstrated the failure before the fix. Added deterministic pending-reconciliation callback coverage and assertions of actual PANELCTL_REARM_ON_START=1 helper environment for fresh countdowns. Final parent full offline swift test passed (229 app tests, five app skips, zero failures; complete log /tmp/panelctl-task43-postreview-tests.log), both products passed warnings-as-errors builds, release-version and diff checks passed. AC1-3: 20 disconnect integration tests exercise multi-rule cleanup, pending callbacks, cancellation/refusal, settings/snooze preservation, recovery and fresh rearm. AC4-5: integration/core tests retain journals, fail closed on unreadable/missing recovery across relaunch, and preserve consent/identity/lease safeguards. AC6: synthetic native controls rendered and inspected, docs updated, full offline checks passed. One general review only; concrete correction checked directly. AppModel LSP remains unknown, compiler checks passed. No hardware writes, push or worktrees. Unrelated TASK-44 remains untouched.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented temporary verified automation quiescence for Full disconnect without changing enabled settings or snooze. Recovery remains fail-closed; eligible rules resume with fresh countdowns. Committed 585ddc4. Independent safety-review race fixed with red/green regression; final offline suite, both warnings-as-errors product builds, release-version checks and synthetic native UI passed. No live hardware validation or writes.
<!-- SECTION:FINAL_SUMMARY:END -->
