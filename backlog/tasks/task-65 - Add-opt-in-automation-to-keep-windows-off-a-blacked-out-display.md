---
id: TASK-65
title: Keep windows off a display while it is blacked out
status: Done
assignee: []
created_date: '2026-10-07 22:45'
updated_date: '2026-10-08 05:26'
labels: []
dependencies:
  - TASK-63
  - TASK-64
references:
  - Sources/PanelCtlApp/ProtectionCoordinator.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlCore/Blackout.swift
  - Sources/PanelCtlCore/EmptyDisplayMonitor.swift
  - Sources/PanelCtlApp/DisplayHidePreferences.swift
  - Sources/PanelCtlApp/DisplaySettingsView.swift
  - docs/display-hide-ux.md
type: feature
ordinal: 54010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A one-time move is not enough: apps create or reopen windows on a blacked-out monitor, where the user cannot see them. Users want an opt-in, per-display option that keeps such windows off while that display is actually blacked out. It is configured alongside the display’s Hide settings (not an Automation rule, per TASK-63), is never enabled by Hide itself, and reuses the TASK-64 mover and destination rules. Remove from desktop does not need it because macOS relocates windows. Only PanelCtl-observed blackout counts; an externally powered-off monitor is not assumed hidden.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Displays settings offer an opt-in “Keep windows off while blacked out” option per display with Automatic or a specific destination (TASK-64 eligibility). It defaults off and existing saved configurations decode as off; with it off, Hide, Actions and Automation are unchanged.
- [x] #2 While the option is on and the display is observed blacked out by any owner (manual Hide, Action or Automation rule), existing eligible windows are moved, then new or returning windows are moved within a documented bound. Armed (option on, display visible) is distinguishable from enforcing.
- [x] #3 Enforcement stops immediately when blackout ends, the option is turned off or the app quits: pending work is cancelled, observers and timers released, and windows are never moved back. On relaunch it reevaluates current state only; it never replays moves or starts blackout.
- [x] #4 No eligible destination, ambiguous identity, recovery, permission loss or topology change gives a visible paused state with a reason and no moves. It resumes without prompting once the condition clears; reconnection never guesses identities or substitutes for a specific destination.
- [x] #5 One controller per display, so no duplicate watchers. Windows that refuse moves, keep returning or are being dragged get bounded per-window backoff with no tight loops; cadence and backoff bounds are verified with a fake clock. A manual Move step during enforcement is idempotent.
- [x] #6 Enforcement never starts or extends blackout, and its moves do not count as user activity. Tests show no hide/move feedback loop or improper rearming with empty-display blackout and input restoration.
- [x] #7 Displays settings, the menu and the status stream show armed/enforcing/paused state with reason and last moved/failed counts. Docs explain ongoing enforcement, supported-window limits and how it differs from the one-shot Move step; background work never prompts for permission.
- [x] #8 Fake-backed tests cover blackout entry/exit by each owner, window creation and return, missed-event reconciliation, sleep/wake, disconnect/reconnect, permission changes, quit/relaunch and cancellation races. Native window movement needs separate explicit user approval and narrow gated tests; no hardware writes are authorized.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reuse the approved window-relocation contract and TASK-64 mover to implement opt-in preferences, one per-display controller, cancellation gates and bounded per-window retry state. 2. Integrate actual owner coverage, helper-acknowledged relocation suppression, settings/menu/status and lifecycle reconciliation without starting or extending blackout. 3. Add focused fake-clock, fake-worker and helper-policy tests and document bounds and limits. 4. Run one independent scoped safety review, fix concrete findings, rerun affected checks, commit on main and record delivery. No native UI or window movement, permission prompts or hardware writes without separate approval.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete; independent safety review pending. Initial implementation child hit 30-minute timeout; inspected and preserved partial diff, resumed same child successfully without protocol fallback. Worker reports 26 WindowRelocation, 45 EmptyDisplayMonitor/BlackoutPolicy, 40 ProtectionPreferences and 15 AutomationRules tests passing, plus swift build. Parent reran affected window/policy/Action/status/app-control suites successfully. LSP returned unknown (no version-matched report), not clean. User explicitly approved fake-backed native UI-only validation: two narrow SettingsWindow tests pass, including new toggle/destination/status test and existing removal-toggle regression. Snapshots .build/task65-ui/keep-windows-off-automatic.png and keep-windows-off-specific.png visually checked. Initial fixture failures were a SwiftUI accessibility-label lookup and host permission/menu-title assumptions; changed to deterministic native switch lookup, injected fake permission and attributed menu title. No real AX movement, permission prompt, helper launch or hardware write. No worktree created; no commit yet.

One independent scoped review completed with seven accepted findings: restored latch must outrank suppression; terminal shutdown must reject queued callbacks; uncertain writes need conservative provenance; new/replaced helper generations need fresh acknowledgment; provenance limits must not silently evict live evidence; current acknowledgment must survive eviction; returning-window retries must reset only after stable off-source observation. Parent rechecked affected source and resumed the same executor for bounded corrections and targeted race/barrier/capacity regressions. Task remains In Progress; no acceptance criteria checked and no commit until these fixes and affected checks complete. No second general review planned.

Delivered implementation/tests/docs in e07e702 (Keep windows off blacked-out displays) on main. All seven independent-review findings corrected and regression-tested; no second general review. Parent fix verification caught the initially incomplete overflow fallback: now uncertain geometry or provenance overflow disables window-only rearming for the helper session, while real pointer occupancy still rearms. Tests feed unknown geometry and still-visible oldest/newest overflow windows, disappearance, pointer activity and later restoration through the policy, not just initial latch assertions. Documented this conservative fallback, 64-window pass bound and helper acknowledgment limit.

Final parent verification: swift test --disable-sandbox --filter WindowRelocationTests|EmptyDisplayMonitorTests|BlackoutPolicyTests|AppStatusStreamTests|AppControlTests|DisplayActionAppTests|ProtectionPreferencesTests|AutomationRulesTests passed 219 tests (36 window relocation, 49 blackout/empty policy, 17 app control, 6 status stream, 56 Actions, 40 protection preferences, 15 Automation rules). swift build --disable-sandbox and staged git diff --check passed. Native UI-only validation previously approved in this session passed two narrow SettingsWindowTests; Automatic/specific destination snapshots visually checked. LSP unknown, not claimed clean.

AC evidence: legacy preference/off independence and native toggle/destination fixture (1); manual/Action/helper and multiple-owner/controller fake-clock lifecycle tests (2); terminal queued-tick/helper callbacks and in-flight setter cancellation/stale-completion tests, no-replay relaunch (3); strict selector/recovery gates, sleep and permission revocation during enumeration, exact-identity reconnect (4); shared manual/enforce serialized worker, stable AX identity and returning-window/drag fake-clock backoff tests (5); current-helper acknowledgment barrier/missing ack/replacement tests, keyboard/timeout latch precedence and uncertain/overflow provenance regressions (6); settings/menu/native fixture plus typed snapshot/status-stream checks and docs (7); combined race/lifecycle/fake subprocess helper coverage above (8). New helper tests launch only synthetic Python fixtures, never the real blackout helper. No real AX movement, permission prompt, DDC/private setter or hardware write. Real native movement remains a separately approved validation activity, not claimed. No remaining task blocker or resumable implementation step; claim released. No push, PR, worktree or retained workspace.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added opt-in per-display keep-off enforcement with strict coverage/identity gates, bounded retries, shutdown cancellation and helper-acknowledged empty-policy safety. Settings, menu and status expose state/reasons/counts. Implementation committed as e07e702 on main. 219 focused fake-backed tests, two approved native UI-only tests and build pass. Seven independent-review findings fixed, including conservative uncertain/overflow provenance handling. No real window movement or hardware writes.
<!-- SECTION:FINAL_SUMMARY:END -->
