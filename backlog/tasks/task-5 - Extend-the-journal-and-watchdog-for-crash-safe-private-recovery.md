---
id: TASK-5
title: Extend the journal and watchdog for crash-safe private recovery
status: Done
assignee: []
created_date: '2026-10-04 05:03'
updated_date: '2026-10-04 07:15'
labels:
  - display-disable
  - offline
  - recovery
dependencies:
  - TASK-4
references:
  - Sources/PanelCtlCore/RecoveryJournal.swift
  - Sources/PanelCtlCore/RecoveryWatchdog.swift
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - scripts/test-display-recovery.swift
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
modified_files:
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - Sources/PanelCtlCore/RecoveryDisable.swift
  - Sources/PanelCtlCore/RecoveryJournal.swift
  - Sources/PanelCtlCore/RecoveryReenable.swift
  - Sources/PanelCtlCore/RecoveryWatchdog.swift
  - Tests/PanelCtlCoreTests/DisplayRecoveryTests.swift
  - Tests/PanelCtlCoreTests/RecoveryLeaseTests.swift
  - Tests/PanelCtlCoreTests/RecoveryReenableTests.swift
  - docs/display-recovery.md
  - docs/recovery-private-lease.md
  - scripts/test-display-recovery.swift
priority: high
type: feature
ordinal: 5
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The existing helper only restores public configuration and refuses missing displays. Extend that single recovery pipeline to handle a journaled private disable with the qualified identity/backend; do not create another daemon. Its READY acknowledgment is not lifetime proof. Parent, helper and manual/startup recovery must serialize through existing per-user/per-journal locks, including custom journal paths. Capture intent before mutation and cover the race where disable commits before its acknowledgment persists. Keep the initial short 1–60 second deadline/lease semantics; indefinite disconnect is outside this first delivery.

Direction: docs/display-disable-implementation-plan.md is canonical; docs/display-disable-tool-survey.md supplies evidence, not hardware qualification. Initial scope is one non-main external display, no mirroring, Apple Silicon, session-only transactions and explicit consent. Use injected/fake display writers for routine work; no live private setter, DDC write, display change, or disruptive recovery is authorized by this task. Preserve unresolved journals and fail closed on unknown identity. Record any real external blocker and the exact evidence or human approval needed; never weaken a guard to mark the task done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Durable baseline and disabled-by-us intent precede mutation; helper readiness, lease and current topology are revalidated immediately before the setter. Dead/unready helper or persistence failure prevents disable.
- [x] #2 Fault-injection tests cover parent exit/SIGINT/SIGTERM/SIGKILL, helper death before/after READY, deadline, crashes around setter/commit/journal persistence and concurrent commands/custom journals. Evidence is not lost and competing recovery writes cannot occur.
- [x] #3 Private re-enable is a journal-driven, identity-checked bounded attempt, followed by public restoration and bounded read-only convergence verification. Interrupted/failed enable attempts are not blindly replayed; return-code success alone is not restored.
- [x] #4 Legacy and verifyOnly journals never reach the private writer; unresolved evidence cannot be overwritten or discarded. Unknown identity and exhausted convergence end in needsAttention.
- [x] #5 Same-boot startup recovery and normal shutdown use the same guarded path; new boot/OS/user invalidates stale authority. Helper limitations (sleep delay, its own death, logout/reboot and driver failure) remain explicit.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend the existing helper as the sole locked writer: bounded disable request over its lease pipe, durable one-shot intent, fresh lease/deadline/topology/preflight checks before transaction stages. Keep production private seams unavailable.
2. Extend the shared recovery engine with bounded read-only convergence, immutable verifyOnly protection, one-shot recovery and locked startup/shutdown entry points.
3. Add fake-writer crash/persistence/race tests and no-write subprocess signal/helper-death coverage, preserving legacy journals and unresolved evidence.
4. Run focused/full tests and builds, perform one safety review, document residual limitations and handoff, commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented the single-writer helper protocol in RecoveryWatchdog/RecoveryDisable: parent sends a bounded request over the existing lease; helper retains both locks, persists disable intent before transaction calls, and revalidates READY/lease/deadline/topology/identity/preflight. Production private injection remains unavailable. RecoveryEngine now shares a locked manual/startup/shutdown path, enforces stored verifyOnly and retired private authority, and performs bounded read-only convergence without replaying writers.
Validation: focused Recovery filter passes 60 core tests (1 opt-in symbol test skipped) plus 1 app test. Ten RecoveryLeaseTests include actual helper subprocesses killed before/after READY, at begin/setter/before and after commit, synthetic recovery after missing acknowledgment, EOF/deadline/helper signals, persistence failures and custom-journal locking. No-write integration script passed live snapshot/rehearsal, parent SIGINT/SIGTERM/SIGKILL, helper SIGKILL, cross-journal contention and stale boot. Artifacts retained at /var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-recovery-integration-45C43DEE-5DBB-4418-8678-503338E919E6. No hardware setters or DDC writes were invoked.
Both products build; release-version checks pass; diff whitespace checks pass. Full suite has 3 failures in unchanged BlackoutGeometryTests.testWindowPlacementOnConnectedExternalScreens compositor bounds, reproduced in isolation. All tests pass when that single live-window test is excluded. LSP diagnostics unknown, not clean. One independent read-only safety review is pending (initial Claude CLI attempt lacked login; replacement reviewer uses Pi). Details and residual limits are in docs/recovery-private-lease.md. Next: resolve any concrete review findings, rerun affected checks, finalize and commit on main.

Delivery: implementation committed on main as c1433d26b8dbab223480626d4ced1aec2804942d (Add crash-safe private recovery lease). One independent read-only review completed using openrouter/openai/gpt-5.4. Its concrete pre-staging false-authority finding was fixed: successful setter staging must be durably recorded before completion, and private recovery requires that marker. Actual fake-helper crash regressions now introduce a later unrelated disappearance after death before staging and prove startup refuses with no private writer. Staging-save failure cancels before commit; old version-2 intent without staging evidence refuses. No further general review was run.
Final verification after correction: swift test --disable-sandbox --filter Recovery passed 61 core tests (1 opt-in symbol test skipped) and 1 app test; swift test --disable-sandbox --skip BlackoutGeometryTests.testWindowPlacementOnConnectedExternalScreens passed; swift build --product panelctl and --product PanelCtlApp passed; scripts/test-release-version.sh and git diff --check passed. The unfiltered suite remains affected by the separately reproduced, unchanged live-window geometry test (3 compositor-bounds assertions); no unrelated fix was made. Final no-write subprocess check passed, with retained artifacts at /var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-recovery-integration-C0839259-2602-4E97-8253-FCDEC4CEE218.
AC evidence: #1 ordering/fresh lease and persistence refusal tests; #2 actual helper death/staging/commit subprocess tests plus parent signal/custom-journal integration; #3 bounded delayed/exhausted convergence and no-replay tests; #4 legacy, missing staged intent, immutable verifyOnly, unknown identity, archive/unresolved retention and retired-authority tests; #5 shared locked startup/shutdown recovery tests and existing OS/boot/user refusals. Residual limits: helper death after any liveness check, sleep delay, logout/reboot/driver failure, noncooperating display apps, and unavoidable staging-to-commit uncertainty; fresh identity remains mandatory. Production private backends remain uninstalled and no real private setter/DDC/live restoration was invoked.
No remaining TASK-5 blocker. Handoff: TASK-6 implements physical/lifecycle preflight; TASK-7 wires the internal guarded helper/recovery path into the CLI. Hardware qualification still requires explicit TASK-9/TASK-10 approval. No push, PR or worktree was created. Claim released at completion.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Completed offline crash-safe recovery infrastructure in c1433d2: single locked helper writer, durable staged disable evidence, one-shot identity-checked recovery, immutable rehearsal authority and bounded read-only convergence. Independent review finding fixed and exercised with actual fake-helper crashes. Focused recovery tests, no-write subprocess checks, builds and release checks pass. Full suite passes excluding the unchanged failing live-window geometry test; no hardware qualification claimed. Production identity/preflight/CLI and explicitly approved hardware trials remain subsequent tasks.
<!-- SECTION:FINAL_SUMMARY:END -->
