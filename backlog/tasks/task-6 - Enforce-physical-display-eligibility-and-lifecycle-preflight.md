---
id: TASK-6
title: Enforce physical-display eligibility and lifecycle preflight
status: Done
assignee: []
created_date: '2026-10-04 05:03'
updated_date: '2026-10-04 07:34'
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
- [x] #1 A testable eligibility result explains every refusal; online count, UUID presence or builtin=false alone cannot establish physical usability. Unknown physical/driver classification fails closed.
- [x] #2 Fixtures reject last usable display, virtual/headless/DisplayLink-only survivors, main/built-in targets, mirrored topology, Intel and unknown driver state. A closed-lid built-in display does not count as a usable survivor.
- [x] #3 Topology or eligibility changes between selection and mutation invalidate preflight; loss of the remaining physical screen requests guarded recovery rather than another disable.
- [x] #4 Sleep/wake transitions defer writes with a bounded policy; system-initiated re-enable clears/reconciles our intent and never causes automatic re-disconnection.
- [x] #5 Pure policy and simulated notification tests cover races without changing displays. Runtime integration points for TASK-7 are documented.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add pure physical eligibility and selection revalidation using existing bounded identity policy; unknown classification remains refused.
2. Add deterministic lifecycle state for topology invalidation, bounded sleep/wake deferral, guarded recovery requests and system-reenable reconciliation (no writers).
3. Exercise eligibility fixtures, notification races and transaction boundaries with fake writers; document TASK-7 wiring and limitations.
4. Run focused/full checks, one safety review, record delivery evidence and commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered on main in commit 598aff8 (Add physical display eligibility and lifecycle policy). Changed Sources/PanelCtlCore/RecoveryEligibility.swift, RecoveryLifecycle.swift, RecoveryDisable.swift (seam documentation), Tests/PanelCtlCoreTests/RecoveryEligibilityTests.swift, docs/recovery-eligibility.md and docs/recovery-private-lease.md.

AC1–2: positive synthetic binding plus physical/driver/architecture/mirror/lid fixtures prove fail-closed selection and diagnostic refusals. Online count, UUID and builtin=false alone do not qualify a survivor. AC3: actual RecoveryDisable with fake transactions cancels topology-ABA, lid, sleep and physical-classification races after begin or staging; survivor collapse requests guarded recovery. AC4–5: simulated AppKit notification mapping verifies matching resumes, one-second settling, fixed five-second deferral budget, attention on exhaustion, qualified system-reenable intent retirement and no re-disconnection. TASK-7 integration contract is documented in docs/recovery-eligibility.md.

Fresh checks: swift test --disable-sandbox --filter RecoveryEligibilityTests passed 7 tests. Full swift test --disable-sandbox reproduced only the three existing compositor-bounds assertions in BlackoutGeometryTests.testWindowPlacementOnConnectedExternalScreens (previously recorded by TASK-5). After corrections, swift test --disable-sandbox --skip BlackoutGeometryTests.testWindowPlacementOnConnectedExternalScreens passed (one opt-in symbol test skipped); both product builds, scripts/test-release-version.sh and git diff --check passed. LSP reports were mixed clean/unknown; compiler/tests are authoritative.

One independent read-only Pi/OpenRouter GPT-5.4 safety review found premature intent retirement with unqualified reappearance observations and silently ignored ambiguous/unusable target reappearance. Both now preserve intent and request guarded recovery, with passing regression tests. Earlier reviewer attempts produced no review (Claude CLI unauthenticated; Pi/Anthropic timed out). No second general review.

No live setter, DDC write or hardware qualification performed. Residual risks: no qualified production physical/driver or offline-sink provider; notifications and hardware commits are not atomic; sleep may delay timers; helper death remains outside lease guarantees. Unknown evidence continues to refuse. No external blocker to this offline policy task. Next step is TASK-7 runtime/CLI wiring: fresh provider observations, serialized lifecycle events, recovery/public-write gating, and verify-only durable reconciliation through existing engine; do not bypass identity or sleep refusal. No worktree created; claim released.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented and committed fail-closed physical eligibility, selection race invalidation, bounded lifecycle deferral and guarded recovery/reappearance policy (598aff8). Seven focused tests, the suite excluding one known live-window failure, both builds and release checks pass. Independent safety findings fixed. TASK-7 wiring documented; production writers remain uninstalled and hardware unqualified.
<!-- SECTION:FINAL_SUMMARY:END -->
