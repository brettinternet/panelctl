---
id: TASK-22
title: Prepare offline experimental disconnect UI states and tests
status: Done
assignee: []
created_date: '2026-10-05 03:53'
updated_date: '2026-10-05 04:04'
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
- [x] #1 Production experimental disconnect remains unavailable with an explicit qualification-required reason; presentation clearly distinguishes disconnect from mirror hide, blackout, sleep and DDC input selection, with no silent fallback or regression to existing hide/show.
- [x] #2 Synthetic app states demonstrate scoped consent, bounded lease progress, refusal, helper failure, watchdog recovery and failed reconnect; copy never promises indefinite disconnect or proven hardware recovery.
- [x] #3 Synthetic journal-backed recovery presentation covers a non-enumerable target and app relaunch, preserving unresolved evidence and showing actionable identity-ambiguity and expired-lease reasons without guessed IDs or actual recovery writes.
- [x] #4 Fake-backed app tests cover unavailable qualification and the synthetic states above, including that production disconnect cannot be invoked through the prepared UI or automation; no live backend or display writes are used.
- [x] #5 Native UI verification uses synthetic states only. Record changed files, focused test/build results, UI observations and remaining TASK-20 integration needs; no hardware qualification or provider-contract changes are claimed.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add app-local read-only disconnect presentation and synthetic consent/lease/recovery fixtures; production stays unavailable. 2. Exercise states with fake-backed tests and native synthetic UI verification. 3. Review once, commit app changes, merge main preserving TASK-12 work, record evidence and clean owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented app-local read-only ExperimentalDisconnectPresentation/View and Settings → Displays unavailable card, plus ExperimentalDisconnectTests. No AppModel/backend/provider changes or live actions. Focused app suite: 97 tests, 2 existing opt-in keyboard/focus fixtures skipped, 0 failures; PanelCtlApp build passes with warnings-as-errors. Synthetic NSHostingView windows rendered all six states plus production and expired lease at 440pt width; PNG evidence in /tmp/panelctl-task22-native. Visual inspection confirms wrapped retained identity/journal evidence, bounded lease progress, explicit synthetic/qualification labels and disabled actions. LSP returned unknown; compiler and tests are authoritative. Independent scoped review running. TASK-20 must add a public read-only private journal/lease adapter, qualified consent/action routing and lifecycle/recovery enforcement; current app-facing API cannot expose these details. Test-only projection reloads a real synthetic RecoveryStore journal and verifies bytes/state remain unchanged, with missing target and expired lease. Worktree receipt: .git/worktrees/task-22-offline-disconnect/agent-creation.json; session 01a10a31-4e3f-772e-8040-882ccb42d478, created from f242c5b.

Delivery: implementation commit 1cfa1df fast-forward merged to main. Reran the complete app test suite on main with concurrent TASK-12 working changes preserved: 97 tests, 2 opt-in skips, 0 failures. Independent reviewer run 798f8374-97cd-46a5-8e60-923a90620486 reported no validated findings; /tmp/panelctl-task22-review.md. No additional general review pass. Worktrunk removed the verified session-owned task-22-offline-disconnect checkout and branch; its matching Herdr workspace w1V was confirmed absent after the post-remove hook. Existing recovery-enable worktree and all unrelated TASK-12 changes remain untouched. No hardware actions, qualification claims, provider-contract changes, push or PR. No remaining TASK-22 blocker; TASK-20 owns production integration and qualified safety enforcement.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Prepared a production-unavailable Settings card and read-only synthetic consent, bounded lease, refusal/helper/watchdog/reconnect states. Synthetic journal reload preserves missing-target identity and unresolved bytes across relaunch. Verified 97 app tests (2 opt-in skips), warnings-as-errors app build, native rendered fixtures and independent review. Implementation 1cfa1df merged to main; owned worktree/branch/workspace cleaned.
<!-- SECTION:FINAL_SUMMARY:END -->
