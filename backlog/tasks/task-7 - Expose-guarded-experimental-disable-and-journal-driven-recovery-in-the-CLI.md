---
id: TASK-7
title: Expose guarded experimental disable and journal-driven recovery in the CLI
status: To Do
assignee: []
created_date: '2026-10-04 05:03'
labels:
  - display-disable
  - offline
  - cli
dependencies:
  - TASK-5
  - TASK-6
references:
  - Sources/PanelCtlCore/CLIParser.swift
  - Sources/PanelCtlCore/CLIHelp.swift
  - Sources/panelctl/main.swift
  - docs/usage.md
  - docs/display-recovery.md
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: high
type: feature
ordinal: 7
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deliver the first user-facing tool by composing the existing journal/helper, identity, transaction and physical-eligibility work. The goal is signal removal and later return for a multi-input monitor, not OLED maintenance or guaranteed input switching. Choose CLI syntax consistent with existing recovery commands and DisplaySelector; record it in help/tests rather than inventing a separate service. Disable must be explicit and bounded by the armed helper. Enable/status must work from retained journal identity even when the target is absent from inventory. This task implements commands but grants no permission to run their state-changing paths on hardware. App UI, auto-disable on launch/login/wake and persistent indefinite disable remain out of scope.

Direction: docs/display-disable-implementation-plan.md is canonical; docs/display-disable-tool-survey.md supplies evidence, not hardware qualification. Initial scope is one non-main external display, no mirroring, Apple Silicon, session-only transactions and explicit consent. Use injected/fake display writers for routine work; no live private setter, DDC write, display change, or disruptive recovery is authorized by this task. Preserve unresolved journals and fail closed on unknown identity. Record any real external blocker and the exact evidence or human approval needed; never weaken a guard to mark the task done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Strict parser/help tests require one explicit target, affirmative disable consent and bounded timeout; malformed/conflicting arguments and unsupported preflight make zero mutation calls.
- [ ] #2 Disable cannot run until durable intent, current identity/topology and helper readiness pass. Journal-driven status exposes offline disabled-by-us targets and refusal/recovery state; enable does not depend on online selection.
- [ ] #3 Quit, signals and same-session startup recovery use the shared guarded recovery path, preserving one-shot/crash semantics. Rehearsal remains no-write and existing blackout/sleep/DDC-brightness behavior remains unchanged.
- [ ] #4 Panic recovery attempts only identity-qualified journal entries. Any global CGRestorePermanentDisplayConfiguration fallback is separately explicit and warned as unverified, never an automatic response to identity refusal; no gamma reset or permanent commit is added.
- [ ] #5 Docs clearly distinguish blackout, topology disable, monitor standby and input switching; show journal recovery and manual failure ladder without promising replug/reboot success or restored window/Spaces placement.
- [ ] #6 End-to-end fake CLI tests exercise success, unavailable API, lost helper, missing/ambiguous target and recovery failure, with stable nonzero errors and no unguarded writer path.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->
