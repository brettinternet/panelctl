---
id: TASK-43
title: Automatically pause automation for Full disconnect
status: To Do
assignee: []
created_date: '2026-10-06 16:20'
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
- [ ] #1 With Automation enabled, a user can request Full disconnect without changing the master switch or rule settings; all automation helpers stop and covers and saved brightness are verified cleaned up before any disconnect write. Pending or failed cleanup prevents disconnect and exposes an actionable reason.
- [ ] #2 Automation remains paused during disconnect preparation, consent, the active lease and unresolved recovery. Timer ticks, snooze expiry, preference changes and automation commands cannot restart treatment during that pause.
- [ ] #3 After cancellation or pre-write refusal with no unresolved recovery, or after verified recovery of a performed disconnect, eligible automation resumes with a fresh countdown. Preserve the current master and rule settings, existing snooze deadline and deliberate user changes; do not enable automation that the user left off or bypass other safety blocks.
- [ ] #4 Lease expiry or helper exit alone never counts as successful recovery. Failed or unreadable recovery state remains blocking across relaunch, keeps journal evidence and exposes recovery controls without automatically replaying a disconnect or private recovery write.
- [ ] #5 Retain fresh one-use consent, confirmation-time revalidation, strict identity and survivor checks, bounded session-only lease, hidden-display and recovery refusals, and existing restrictions on scripting and unattended disconnect.
- [ ] #6 Fake-backed regressions cover enabled, disabled and snoozed automation, multiple-rule cleanup and failure, cancellation and refusal, consent expiry, restart races, successful and failed recovery, relaunch and user preference changes. Synthetic UI and documentation explain temporary pausing and recovery blocks rather than requiring Turn Off Automation; relevant offline tests and builds pass.
<!-- AC:END -->
