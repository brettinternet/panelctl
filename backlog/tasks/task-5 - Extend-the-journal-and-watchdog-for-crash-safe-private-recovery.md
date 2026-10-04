---
id: TASK-5
title: Extend the journal and watchdog for crash-safe private recovery
status: To Do
assignee: []
created_date: '2026-10-04 05:03'
labels:
  - display-disable
  - offline
  - recovery
dependencies:
  - TASK-4
references:
  - Sources/PanelCtlCore/RecoveryJournal.swift
  - Sources/PanelCtlCore/RecoveryWatchdog.swift
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - scripts/test-display-recovery.swift
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: high
type: feature
ordinal: 5
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The existing helper only restores public configuration and refuses missing displays. Extend that single recovery pipeline to handle a journaled private disable with the qualified identity/backend; do not create another daemon. Its READY acknowledgment is not lifetime proof. Parent, helper and manual/startup recovery must serialize through existing per-user/per-journal locks, including custom journal paths. Capture intent before mutation and cover the race where disable commits before its acknowledgment persists. Keep the initial short 1–60 second deadline/lease semantics; indefinite disconnect is outside this first delivery.

Direction: docs/display-disable-implementation-plan.md is canonical; docs/display-disable-tool-survey.md supplies evidence, not hardware qualification. Initial scope is one non-main external display, no mirroring, Apple Silicon, session-only transactions and explicit consent. Use injected/fake display writers for routine work; no live private setter, DDC write, display change, or disruptive recovery is authorized by this task. Preserve unresolved journals and fail closed on unknown identity. Record any real external blocker and the exact evidence or human approval needed; never weaken a guard to mark the task done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Durable baseline and disabled-by-us intent precede mutation; helper readiness, lease and current topology are revalidated immediately before the setter. Dead/unready helper or persistence failure prevents disable.
- [ ] #2 Fault-injection tests cover parent exit/SIGINT/SIGTERM/SIGKILL, helper death before/after READY, deadline, crashes around setter/commit/journal persistence and concurrent commands/custom journals. Evidence is not lost and competing recovery writes cannot occur.
- [ ] #3 Private re-enable is a journal-driven, identity-checked bounded attempt, followed by public restoration and bounded read-only convergence verification. Interrupted/failed enable attempts are not blindly replayed; return-code success alone is not restored.
- [ ] #4 Legacy and verifyOnly journals never reach the private writer; unresolved evidence cannot be overwritten or discarded. Unknown identity and exhausted convergence end in needsAttention.
- [ ] #5 Same-boot startup recovery and normal shutdown use the same guarded path; new boot/OS/user invalidates stale authority. Helper limitations (sleep delay, its own death, logout/reboot and driver failure) remain explicit.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->
