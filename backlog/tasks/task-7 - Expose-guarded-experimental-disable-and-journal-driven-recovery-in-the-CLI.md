---
id: TASK-7
title: Expose guarded experimental disable and journal-driven recovery in the CLI
status: Done
assignee: []
created_date: '2026-10-04 05:03'
updated_date: '2026-10-04 07:59'
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
- [x] #1 Strict parser/help tests require one explicit target, affirmative disable consent and bounded timeout; malformed/conflicting arguments and unsupported preflight make zero mutation calls.
- [x] #2 Disable cannot run until durable intent, current identity/topology and helper readiness pass. Journal-driven status exposes offline disabled-by-us targets and refusal/recovery state; enable does not depend on online selection.
- [x] #3 Quit, signals and same-session startup recovery use the shared guarded recovery path, preserving one-shot/crash semantics. Rehearsal remains no-write and existing blackout/sleep/DDC-brightness behavior remains unchanged.
- [x] #4 Panic recovery attempts only identity-qualified journal entries. Any global CGRestorePermanentDisplayConfiguration fallback is separately explicit and warned as unverified, never an automatic response to identity refusal; no gamma reset or permanent commit is added.
- [x] #5 Docs clearly distinguish blackout, topology disable, monitor standby and input switching; show journal recovery and manual failure ladder without promising replug/reboot success or restored window/Spaces placement.
- [x] #6 End-to-end fake CLI tests exercise success, unavailable API, lost helper, missing/ambiguous target and recovery failure, with stable nonzero errors and no unguarded writer path.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add strict recovery disable syntax (one selector, --consent-disable, explicit 1–60s timeout), journal-only enable/panic, and help.
2. Compose CLI selection/startup recovery with the existing single-writer helper and lifecycle gates; production identity/physical evidence remains fail-closed, with no override or global reset.
3. Exercise parsed commands, helper failures, one-shot recovery and lifecycle integration with synthetic observations/fake writers; update usage/recovery docs.
4. Run focused/full checks and one independent safety review, fix concrete findings, commit on main and record acceptance evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered on main in 0d7e889 (Add guarded display recovery CLI). Changed CLIParser/CLIHelp, panelctl/main, new RecoveryCLI and RecoveryPrivateSession, existing RecoveryWatchdog/DisplayRecovery/RecoveryJournal/RecoveryDisable, recovery binding/lifecycle comments, RecoveryCLITests/RecoveryLeaseTests, and docs/usage.md, docs/display-recovery.md, docs/recovery-eligibility.md. No worktree created.

AC1/2/6: nine RecoveryCLITests exercise strict one-target/consent/explicit 1–60s parsing; parsed fake CLI success, unavailable identity/API, physical preflight refusal, missing/ambiguous selection, absent/lost helper, disable-completion and recovery failures; retained offline status/enable/panic/startup; journal replacement refusal under lock; production-provider refusal before writer construction; and actual executable help/status/parse/operational exit codes 0/2/1 without hardware calls. Durable disableCompleted evidence prevents a recovered failed disable from reporting success. Existing transaction/lease tests prove write-ahead staging, READY/lease failure, fresh identity/topology checks and cancellation.

AC3/4: expanded real helper IPC subprocess tests use only synthetic displays and fake writers. They cover deadline, EOF/quit, SIGINT/SIGTERM, helper death/crash windows, same-session startup one-shot recovery, survivor collapse, sleep deferral/exhaustion, and system-reenable reconciliation. A focused regression initially reproduced an EOF-versus-system-reenable race causing an unwanted public layout write, plus unclosed authority after failed layout verification. Fixed by observing reappearance on every finish path and durably closing private authority before verify-only reconciliation; both regressions now pass with zero public writes. Manual enable/panic select only staged journal intent, checked under lock. Resolved intent remains idempotent verification, never writer replay. No global reset, gamma reset, permanent commit, or DDC write was added. Rehearsal and existing public-only recovery retain their no-write/explicit-write boundaries.

AC5: help and usage/recovery docs explain blackout versus topology removal, standby and input switching; journal-only recovery, custom-path ownership, foreground bounded lease, refusal diagnostics, startup reselection, and a separately manual/unverified failure ladder. No window/Spaces, replug or reboot guarantees. Production fresh physical-sink/driver/awake-state observations remain unqualified and fail closed; no flag or journal field bypasses them. This is completion of the offline CLI task, not a usable or qualified hardware trial.

Fresh checks: focused RecoveryCLITests and RecoveryLeaseTests passed; final swift test --disable-sandbox --skip BlackoutGeometryTests.testWindowPlacementOnConnectedExternalScreens passed (160 core tests including one optional retained-ICC skip, 54 app tests). The unfiltered suite reproduced only the three previously recorded live compositor-bounds assertions in that excluded test. Both swift build --product panelctl and --product PanelCtlApp, scripts/test-release-version.sh, and git diff --check passed. LSP reports were clean/unknown, so compiler and executable tests are authoritative. No live private setter, hardware restoration, DDC write, or disruptive recovery was performed.

One independent read-only Pi/OpenRouter GPT-5.4-mini safety review completed. Its two candidate findings were rejected after checking the actual policy/engine and existing regressions: fixed five-second lifecycle expiry terminates deferred EOF (runtime-sleep-expired passes), and a resolved engine performs verification only (repeat enable emits no writer calls). No second general review. The targeted system-reenable/EOF acceptance regression and journal-selection lock check above were added and passed.

Residual risks: no qualified production physical/sink/awake-state provider; notification delivery is not atomic with hardware writes; sleep can delay timers; helper SIGKILL/OS/driver failure remains outside recovery guarantees; offline refusal is not reconnection evidence. No external blocker remains to this offline task. Next: TASK-8 offline acceptance and independent safety review; live TASK-9 still requires technical qualification and explicit scoped human approval. Claim released; no push or PR.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented guarded recovery disable, retained-journal enable/panic/status, helper lifecycle integration and startup recovery in 0d7e889. Fake CLI/real-IPC tests, both builds and release checks pass; the full suite only reproduces the known live geometry failure. System-reenable shutdown races are regression-tested. Production identity remains refused; no hardware qualification claimed.
<!-- SECTION:FINAL_SUMMARY:END -->
