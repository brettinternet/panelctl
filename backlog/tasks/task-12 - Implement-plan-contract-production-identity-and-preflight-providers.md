---
id: TASK-12
title: Implement plan-contract production identity and preflight providers
status: To Do
assignee: []
created_date: '2026-10-04 15:50'
updated_date: '2026-10-04 15:50'
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
priority: high
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
