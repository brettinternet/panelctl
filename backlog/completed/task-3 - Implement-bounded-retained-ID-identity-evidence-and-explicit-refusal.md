---
id: TASK-3
title: Implement bounded retained-ID identity evidence and explicit refusal
status: Done
assignee: []
created_date: '2026-10-04 05:03'
updated_date: '2026-10-04 05:53'
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
- [x] #1 Capture persists supplementary identity and its provenance/context alongside retained ID and disabled-by-us intent; schema handling never upgrades old journals lacking evidence into private-write authority.
- [x] #2 Policy has explicit eligible, ambiguous, stale, missing-evidence and unsupported outcomes with actionable diagnostics; it can address a journaled target absent from online enumeration without using current selection.
- [x] #3 Fake fixtures cover unchanged eligible evidence, ID reuse, replacement at the same port, different port, duplicate/zero serials, ghost/virtual entries, absent connector, stale metadata and boot/OS/user changes; unsafe cases make zero writer calls.
- [x] #4 A policy table states precisely which evidence authorizes a same-session attempt, why it is sufficient, and which facts remain unproven. Cached matching fields, HPD high, registry-object lifetime or equal framebuffer/CG integers alone never pass.
- [x] #5 Public restoration checks remain strict; unknown/ambiguous identity retains needsAttention and never causes a blind ID sweep, force override or repeated enable attempt.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend snapshot/journal evidence with provenance and explicit disabled-by-us target; preserve legacy public recovery without private authority. 2. Add typed retained-ID policy outcomes and integrate with existing re-enable guards, keeping production unqualified. 3. Exercise fake evidence and zero-write refusal cases, document the policy table, run tests/builds and one independent safety review. 4. Record delivery evidence and commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Resumed existing main changes under explicit user handoff. Added engine-level zero-write/replay checks for ID reuse, same-port replacement, changed port, boot/OS/user changes and real CG/CoreDisplay provenance even with matching HPD-high metadata. Fresh validation: swift test --disable-sandbox (54 tests, 0 failures); swift build --product panelctl; swift build --product PanelCtlApp; scripts/test-release-version.sh all pass. LSP diagnostics unknown (bounded report timeout); compiler/tests provide validation. Independent read-only review running; no hardware writes or live qualification performed.

Fresh resumed validation on main: swift test --disable-sandbox passed 180 XCTest cases (126 core with 1 optional retained-profile test skipped; 54 app), zero failures. Both swift build --product panelctl and swift build --product PanelCtlApp passed; scripts/test-release-version.sh and git diff --check passed. Corrects the earlier note that reported only the 54 app tests. Independent bounded review run 8f49bcda-eac4-4d75-a484-0a4834a34747 is pending; no hardware writes performed.

Delivered on main in commit 4269cdd (Add retained-ID identity refusal policy). Changed DisplayRecovery.swift, RecoveryJournal.swift, RecoveryReenable.swift, new RecoveryIdentityPolicy.swift, RecoveryReenableTests.swift, docs/display-recovery.md and new docs/recovery-identity-policy.md. Final fresh checks: swift test --disable-sandbox: 180 XCTest cases, 1 optional test skipped, 0 failures; 14 recovery re-enable tests passed. swift build --product panelctl, swift build --product PanelCtlApp, scripts/test-release-version.sh and git diff --check passed. Prior LSP diagnostics remained unknown; compiler/tests are the validation evidence. Recovered completed independent reviewer child 2ea87f39-9935-4eeb-b529-156b1709c8e6 after parent workflow 8f49bcda-eac4-4d75-a484-0a4834a34747 stopped on session reload: no validated safety findings. Review inspected production callers, legacy authority, unsafe writes and replay; it did not independently execute tests. AC evidence: journal round-trip and legacy/intent tests prove schema behavior; policy outcome and engine zero-write fixtures prove conservative refusal including context/port/identity changes; docs/recovery-identity-policy.md states the evidence table; existing strict public recovery and one-shot tests pass. Ghost/virtual cases are modeled by unqualified binding, not a real classifier. No hardware writes or qualification performed. No remaining TASK-3 blocker; live use remains blocked on qualified fresh physical-sink-to-retained-ID evidence and separate scoped approval. Next available offline step: TASK-4 verified transaction backend. No worktree created or adopted.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Persisted diagnostic identity provenance and version-2 disabled-by-us intent; added explicit retained-ID refusal outcomes with synthetic-only eligibility. Legacy journals cannot gain private authority; unresolved recovery and one-shot attempts remain strict. Delivered as 4269cdd, verified by 180 XCTest cases (1 skipped, 0 failures), both product builds, release-version checks and independent safety review with no validated findings. Real hardware remains unqualified.
<!-- SECTION:FINAL_SUMMARY:END -->
