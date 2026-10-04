---
id: TASK-3
title: Implement bounded retained-ID identity evidence and explicit refusal
status: To Do
assignee: []
created_date: '2026-10-04 05:03'
labels:
  - display-disable
  - offline
  - identity
dependencies:
  - TASK-2
references:
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - Sources/PanelCtlCore/RecoveryJournal.swift
  - Sources/PanelCtlCore/Probe.swift
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: high
type: feature
ordinal: 3
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A disabled display disappears from public lists. The survey supports retained CG ID plus supplementary hardware/connector evidence and conservative refusal, not guessing or a universal fresh-sink provider. Main snapshot already captures UUID/ID, vendor/model/serial and IODisplayLocation; integrated branch research shows IOMobileFramebuffer IDs, CG UUIDs and EDID UUIDs are not interchangeable, HPD/liveness is not fresh identity, and an offline ghost ID can lack identity entirely. Scope this delivery to the narrow evidence/refusal contract used before disable and before retained-ID re-enable. Transport state, framebuffer location and serials may support or invalidate a match, but stale or unavailable evidence cannot authorize it. Multi-identical-display research is deferred. If no real target qualifies, deliver truthful refusal behavior and leave the live gate blocked, not a permissive provider.

Direction: docs/display-disable-implementation-plan.md is canonical; docs/display-disable-tool-survey.md supplies evidence, not hardware qualification. Initial scope is one non-main external display, no mirroring, Apple Silicon, session-only transactions and explicit consent. Use injected/fake display writers for routine work; no live private setter, DDC write, display change, or disruptive recovery is authorized by this task. Preserve unresolved journals and fail closed on unknown identity. Record any real external blocker and the exact evidence or human approval needed; never weaken a guard to mark the task done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Capture persists supplementary identity and its provenance/context alongside retained ID and disabled-by-us intent; schema handling never upgrades old journals lacking evidence into private-write authority.
- [ ] #2 Policy has explicit eligible, ambiguous, stale, missing-evidence and unsupported outcomes with actionable diagnostics; it can address a journaled target absent from online enumeration without using current selection.
- [ ] #3 Fake fixtures cover unchanged eligible evidence, ID reuse, replacement at the same port, different port, duplicate/zero serials, ghost/virtual entries, absent connector, stale metadata and boot/OS/user changes; unsafe cases make zero writer calls.
- [ ] #4 A policy table states precisely which evidence authorizes a same-session attempt, why it is sufficient, and which facts remain unproven. Cached matching fields, HPD high, registry-object lifetime or equal framebuffer/CG integers alone never pass.
- [ ] #5 Public restoration checks remain strict; unknown/ambiguous identity retains needsAttention and never causes a blind ID sweep, force override or repeated enable attempt.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->
