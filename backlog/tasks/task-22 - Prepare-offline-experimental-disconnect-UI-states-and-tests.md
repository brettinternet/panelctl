---
id: TASK-22
title: Prepare offline experimental disconnect UI states and tests
status: To Do
assignee: []
created_date: '2026-10-05 03:53'
labels:
  - display-hide
  - app
  - offline
dependencies:
  - TASK-17
references:
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Tests/PanelCtlAppTests/DisplayHideAppTests.swift
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-recovery.md
priority: low
type: task
ordinal: 12010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Split from TASK-20 by user request so bounded app presentation and fake-backed tests can proceed in parallel with TASK-12 without waiting for hardware qualification. Deliver app-local unavailable/consent/lease/recovery presentation using synthetic states and existing app patterns. Production private disconnect remains unavailable; this task neither wires a live private backend nor claims a qualified configuration. Scope is Sources/PanelCtlApp and Tests/PanelCtlAppTests, with delivery evidence in task notes. Do not change PanelCtlCore production identity, eligibility, lifecycle, private-session, re-enable, watchdog or provider code/tests owned by TASK-12, or shared qualification documents. If an existing seam is insufficient, record the integration need for TASK-20 rather than changing the provider contract. TASK-20 retains qualification-dependent production integration and end-to-end safety enforcement. This new offline slice is not subject to the historical parking of TASK-20; it is unclaimed and dependency-ready after TASK-17. No private setter, DDC, mirror/unmirror, topology changes, live helper arming or disruptive recovery is authorized.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Production experimental disconnect remains unavailable with an explicit qualification-required reason; presentation clearly distinguishes disconnect from mirror hide, blackout, sleep and DDC input selection, with no silent fallback or regression to existing hide/show.
- [ ] #2 Synthetic app states demonstrate scoped consent, bounded lease progress, refusal, helper failure, watchdog recovery and failed reconnect; copy never promises indefinite disconnect or proven hardware recovery.
- [ ] #3 Synthetic journal-backed recovery presentation covers a non-enumerable target and app relaunch, preserving unresolved evidence and showing actionable identity-ambiguity and expired-lease reasons without guessed IDs or actual recovery writes.
- [ ] #4 Fake-backed app tests cover unavailable qualification and the synthetic states above, including that production disconnect cannot be invoked through the prepared UI or automation; no live backend or display writes are used.
- [ ] #5 Native UI verification uses synthetic states only. Record changed files, focused test/build results, UI observations and remaining TASK-20 integration needs; no hardware qualification or provider-contract changes are claimed.
<!-- AC:END -->
