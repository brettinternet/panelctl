---
id: TASK-12
title: Implement plan-contract production identity and preflight providers
status: In Progress
assignee:
  - '@pi'
created_date: '2026-10-04 15:50'
updated_date: '2026-10-05 04:26'
labels:
  - display-disable
  - offline
  - qualification
dependencies:
  - TASK-8
references:
  - docs/display-provider-qualification.md
  - docs/recovery-identity-policy.md
  - docs/recovery-eligibility.md
  - Sources/PanelCtlCore/RecoveryPrivateSession.swift
  - Sources/PanelCtlCore/RecoveryIdentityPolicy.swift
documentation:
  - docs/display-disable-implementation-plan.md
priority: low
type: task
ordinal: 2010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-11 found production providers always refuse because the identity policy (from TASK-3) classifies matching capture-time fields as 'unsupported' and demands proof of fresh physical-sink acquisition plus unique retained-CG-ID mapping while absent. That is the full offline identity contract the canonical plan (section 2, 'Deliberately not required before the first implementation') explicitly deferred; it made TASK-9 unsatisfiable by construction. User decision 2026-10-04: adopt the plan's bounded contract instead. Record capture-time evidence and re-enable the retained ID only when current evidence matches it exactly, otherwise refuse and surface for manual action, as shipped tools do. The proposed DCP firmware/operation-7 static investigation in docs/display-provider-qualification.md was declined as the TASK-9 path (even success would close only one gap); deep identity work stays later hardening for identical-display setups. Scope: one explicitly selected non-main, non-identical external display on the TASK-1 qualified Apple Silicon host/OS. Read-only public/IOKit observations and fake writers only. No private setter (including online enable), public restoration, DDC, topology change, sleep/crash/hotplug trial, or helper arming for a live run. Do not promote syntheticPhysicalFixture or bypass refusal. Completion does not authorize TASK-9; it still needs fresh scoped human consent.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Identity policy and docs/recovery-identity-policy.md are revised to the plan contract: exact match of complete nonzero vendor/product/serial, connector/location, transport and host context between capture and current observation authorizes retained-ID re-enable for the scoped target; missing/zero fields, duplicates or identical-model peers, any mismatch, host/boot/build change or unsupported hardware/OS refuse and surface for manual action. Residual risks (cached metadata, same-port replacement, ID reuse) are documented, not claimed solved.
- [ ] #2 Production providers supply real read-only observations through existing seams: target and survivor classification (external, online, active, usable mode, non-virtual/headless), driver exclusion refusing on DisplayLink/virtual-display drivers or unknown inventory, and initial awake/lid/console state; unknown observations refuse.
- [ ] #3 Environment and lifecycle are re-observed at every mutation boundary, including recovery/enable paths (closing the TASK-11 recovery-boundary refresh gap); invalidation between observation and write refuses before writer construction or cancels the transaction.
- [ ] #4 Fake-writer tests cover match/mismatch/missing/duplicate identity, survivor loss, driver presence/unknown, asleep/lid/unknown state and boundary invalidation; focused recovery tests and warnings-as-errors builds pass with no display writes.
- [ ] #5 A no-write rehearsal on this Mac records the provider verdict and evidence for the actually connected target and survivor (either outcome, with exact reason); an independent safety review checks the providers against the plan contract with findings resolved or recorded as blockers. TASK-9's technical-gate status is updated; no live trial is authorized.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Implement bounded capture/current identity matching and real read-only host, display, driver and lifecycle observations through existing seams; retain unknown-state refusal and document residual risks.
2. Refresh identity/environment/lifecycle at disable, enable and public-restoration mutation boundaries; add fake-writer regression tests.
3. Run focused recovery tests and warnings-as-errors builds, and a no-write connected-display rehearsal.
4. Perform one independent safety review focused on false qualification and boundary invalidation; fix concrete findings and rerun affected checks.
5. Update TASK-9 technical gate and task evidence, release claim, and commit on main. No hardware writes or live helper arming.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Parked 2026-10-04 by user decision: DDC input select works (TASK-10), and public mirroring (TASK-13) is the first route to hide the display. Resume only if mirroring fails or its side effects are unacceptable, or if the signal must drop so monitors without DDC can switch inputs automatically. Away/back command: TASK-15.

User explicitly resumed TASK-12 offline in this session; prior parking decision lifted for this provider implementation only. No hardware writes authorized.

Implementation checkpoint: bounded production identity/read-only environment and lifecycle providers implemented; actual Mac17,14 arm64 26A434 no-write rehearsal matches identity but all target selections refuse unknown complete native-only driver inventory. No hardware writes or live helper arming. Parent focused recovery checks and warnings-as-errors CLI/app builds passed; full suite passed 311 tests on rerun (4 skips); initial full run had unrelated native-menu focus assertions. LSP diagnostics unknown (bounded timeout). Independent safety review 8ca963d8-65b8-4c97-a523-ab3467e6d975 identified four concrete defects: public fresh sleep ignored; inactive mirror destination wrongly blocks unmirror; changed connector semantics break legacy journals; sleep observation prematurely ends watchdog deferral. Scoped corrections/regression tests are in progress; no acceptance checked yet. Executor timeout was resumed from preserved changes; no work lost. Main advanced with unrelated TASK-22 commits, preserved.

Final validation and review: independent review 8ca963d8-65b8-4c97-a523-ab3467e6d975 found four defects, all corrected with focused regressions for fresh public sleep refusal, inactive awake mirror destinations, legacy connector compatibility, and realistic sleep/resume watchdog deferral. No second general review. Parent final swift test --disable-sandbox passed 314 tests (4 skips); CLI and app warnings-as-errors builds and git diff --check passed. Logs .build/task12-final-tests.log, task12-final-cli-build.log, task12-final-app-build.log. Required provider rehearsal passed read-only with exact driver-unknown refusal documented in docs/display-provider-qualification.md. TASK-9 technical gate updated; no hardware qualification or write approval. Files: recovery capture/identity/production providers, eligibility/lifecycle/session/reenable/watchdog, focused recovery/mirroring tests, identity/eligibility/recovery/provider/trial docs. Unknown driver inventory is valid fail-closed behavior under AC2/5, not an unfinished permission to enable writes. No worktree created; unrelated TASK-22 commits preserved. Ready for implementation commit and final status.
<!-- SECTION:NOTES:END -->
