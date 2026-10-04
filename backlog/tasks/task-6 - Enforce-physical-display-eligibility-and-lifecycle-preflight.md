---
id: TASK-6
title: Enforce physical-display eligibility and lifecycle preflight
status: To Do
assignee: []
created_date: '2026-10-04 05:03'
labels:
  - display-disable
  - offline
  - safety
dependencies:
  - TASK-3
references:
  - Sources/PanelCtlCore/DisplayInventory.swift
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - Sources/PanelCtlCore/Blackout.swift
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: high
type: feature
ordinal: 6
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Online display count is not a safety proof: macOS can create a headless virtual display after physical displays disappear. Define a conservative preflight for exactly one non-main external physical target and at least one other usable physical screen, using the bounded identity evidence. Existing Blackout lifecycle/notification handling is a reference, not a reason to turn blackout policy into disconnect automation. Restrict to Apple Silicon, no mirrored configuration, no DisplayLink or active virtual-display drivers, and defer through sleep/wake. Main/built-in disable and allow-disabling-all overrides are out of scope.

Direction: docs/display-disable-implementation-plan.md is canonical; docs/display-disable-tool-survey.md supplies evidence, not hardware qualification. Initial scope is one non-main external display, no mirroring, Apple Silicon, session-only transactions and explicit consent. Use injected/fake display writers for routine work; no live private setter, DDC write, display change, or disruptive recovery is authorized by this task. Preserve unresolved journals and fail closed on unknown identity. Record any real external blocker and the exact evidence or human approval needed; never weaken a guard to mark the task done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A testable eligibility result explains every refusal; online count, UUID presence or builtin=false alone cannot establish physical usability. Unknown physical/driver classification fails closed.
- [ ] #2 Fixtures reject last usable display, virtual/headless/DisplayLink-only survivors, main/built-in targets, mirrored topology, Intel and unknown driver state. A closed-lid built-in display does not count as a usable survivor.
- [ ] #3 Topology or eligibility changes between selection and mutation invalidate preflight; loss of the remaining physical screen requests guarded recovery rather than another disable.
- [ ] #4 Sleep/wake transitions defer writes with a bounded policy; system-initiated re-enable clears/reconciles our intent and never causes automatic re-disconnection.
- [ ] #5 Pure policy and simulated notification tests cover races without changing displays. Runtime integration points for TASK-7 are documented.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->
