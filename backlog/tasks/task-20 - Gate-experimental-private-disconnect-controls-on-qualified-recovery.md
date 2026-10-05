---
id: TASK-20
title: Gate experimental private disconnect controls on qualified recovery
status: Done
assignee: []
created_date: '2026-10-04 17:13'
updated_date: '2026-10-05 20:25'
labels:
  - display-hide
  - app
dependencies:
  - TASK-9
  - TASK-12
  - TASK-17
  - TASK-22
references:
  - docs/display-recovery.md
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - docs/display-disable.md
priority: medium
type: feature
ordinal: 10010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mirror hide does not drop the Mac display signal. Users seeking signal removal need an honest, separately gated experimental disconnect path rather than a misleading hide label or silent backend fallback. TASK-22 now owns independently deliverable app-local synthetic UI states and fake-backed presentation tests; reuse that work here rather than duplicating it. This task retains qualification-dependent production backend integration, recorded-qualification availability, actual consent/lease/journal/watchdog enforcement and fake UI/core integration coverage of those boundaries. It is blocked on TASK-12 production providers, TASK-9 qualified trial evidence, TASK-17 app recovery flow and TASK-22 offline presentation; their completion alone is not blanket hardware or automation approval. Keep mirror hide/handoff independently deliverable. Offline implementation and fake/no-write validation only. This task does not authorize live mirror/unmirror, DDC or private setter writes. Any hardware validation needs fresh scoped human approval; record untested behavior honestly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Expose experimental disconnect only for configurations supported by recorded qualification evidence, with explicit unavailable reasons otherwise. Clearly distinguish it from mirror hide, blackout, sleep and DDC input selection; never switch methods silently.
- [x] #2 Each disconnect requires explicit scoped consent and the existing bounded lease, eligible remaining physical screen, qualified identity/lifecycle preflight, journal and watchdog. The app does not weaken backend refusals or promise indefinite disconnect.
- [x] #3 Journal-driven reconnect/status remains available for non-enumerable displays and app restart. Identity ambiguity, expired leases, helper failures and unresolved restoration show actionable recovery without guessed IDs or discarded evidence.
- [x] #4 Private disconnect is excluded from idle/empty-display automation, startup, wake and automatic re-disconnect. Any future unattended support requires a separate scoped decision and qualification task; panic/global restoration remains separately warned and explicitly approved.
- [x] #5 Fake UI/core integration tests cover unavailable qualification, lease progress, refusal, watchdog recovery, relaunch and failed reconnect. Native UI verification uses synthetic states; any live trial is separately approved and recorded with exact scope and limitations.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Complete: added the narrow TASK-9 qualification adapter, one-use 30-second selection consent and fixed 15-second helper lease; integrated separate manual controls and retained-journal recovery in Displays; exercised fake core/app boundaries and native synthetic rendering; fixed the single independent safety-review finding with a mutation-proven regression; committed f1c5583, merged 37bf06f, revalidated main, and removed the verified owned worktree/branch/workspace.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Parked 2026-10-04 with TASK-12/TASK-9 (user decision: mirroring is the first hide route). App dependency is now TASK-17, which owns app journal recovery after the TASK-17/18 re-slice. Resume only if those tasks are resumed and qualified.

User-approved split: TASK-22 may proceed independently alongside TASK-12, scoped to app-local synthetic presentation and fake-backed tests with production disconnect unavailable. TASK-20 remains qualification-gated and owns integrating those states with production recovery plus AC5 UI/core boundary tests; TASK-22 completion does not satisfy hardware qualification or authorize writes. Earlier parking notes do not block TASK-22. Existing acceptance criteria remain intact.

Un-parked 2026-10-05 with TASK-9: signal drop for non-DDC monitor auto-switch is a confirmed user need. Still gated on TASK-9 qualified evidence (which now waits on TASK-23). If TASK-9 shows disable does not drop the signal, reassess this task rather than shipping it.

Implemented in receipt-owned .worktrees/task-20-qualified-disconnect (branch task-20-qualified-disconnect, base 3125efa; session 01a10dab-1196-7226-b088-b78d5f820480). Adapter reuses private session/watchdog/journal, narrows qualification to recorded Dell unit/connector/host/build, fixed 15-second per-operation consent, read-only restart polling, explicit retained-journal reconnect and no automation command. Native synthetic/fake-backed controls rendered at 440pt; no live app or hardware writes. Focused integration/presentation and 96 recovery tests passed; both products warnings-as-errors build. Fresh full suite passed 228 core + 131 app tests, four opt-in skips total (historical TASK-9 failures did not reproduce). One independent safety review running (workflow 06c21278-a455-4ec3-9ea8-5124ee12e360, child 8ce94bff-7d4b-4f03-bb8b-96a280e8c35d). Additional consent-race/gate-off recovery regressions pending final rerun. No acceptance checked until review and delivery.

Delivery: f1c5583 implements TASK-20; merge 37bf06f preserves concurrent main commits 04f5e89 and 1acd2bb. Changed DisplayDisconnect.swift, RecoveryWatchdog.swift, app model/settings/controls/presentation, integration tests and development/disable/Hide docs. AC1: qualification tests refuse changed host/build/unit/connection before backend work; per-operation firmware attestation covers the unobservable M3T101 field, and native controls distinguish private disconnect from mirror/blackout/sleep/DDC. AC2: tests prove consent cancellation, expiry, one-use consumption, revalidation after identity/journal changes, survivor refusal and helper failure without writes. AC3: fake real-engine lease/recovery tests prove retained absent-target status across relaunch, no polling writes, watchdog restoration, failed reconnect evidence retention and no private-enable replay; changed journal confirmation refuses and reconnect works with Experimental off. AC4: command decoding rejects private disconnect/reconnect automation aliases; startup/refresh/expiry tests never start another lease, and no global reset/logout/reboot path exists. AC5: 14 app integration/presentation tests, including native synthetic cards and fake-backed production controls at 440pt, pass. Rendered fixture inspected; no real app launch or live hardware write.

Independent review 8ce94bff-7d4b-4f03-bb8b-96a280e8c35d found one P1: watchdog recapture could adopt different private transport evidence because public snapshot verification does not compare it. Fixed by retaining the qualified expectedSnapshot as journal baseline; existing helper identity policy now refuses drift before writer construction. testWatchdogRecaptureRetainsQualifiedTransportAndHelperRefusesDrift exercises the actual start/journal boundary with a nonexistent helper and fake session; reverting the fix produced three expected assertion failures, restoring it passes. No second general review was performed. Final full swift test --disable-sandbox passed both before and after merge: 228 core + 134 app tests, four opt-in skips, zero failures. Both swift build --product panelctl -Xswiftc -warnings-as-errors and equivalent PanelCtlApp build pass on main; git diff --check passes. LSP diagnostics were unknown, not claimed clean. Logs: /tmp/panelctl-task20-main-tests.log, /tmp/panelctl-task20-main-cli.log, /tmp/panelctl-task20-main-app.log; synthetic PNGs /tmp/panelctl-task20-fixtures. Historical TASK-9 app-test failures are not fresh failures.

Cleanup verified against Git-local agent-creation.json and Worktrunk listing: owned checkout .worktrees/task-20-qualified-disconnect and branch deleted together by wt remove --foreground; exact Herdr workspace w23 contained only an idle shell, post-remove hook closed it and subsequent workspace listing confirmed absence. No owned checkout/workspace retained; pre-existing recovery-enable is unowned and untouched. Claim released. Offline task complete with no remaining delivery blocker. Residual limits: new app path has not been live-qualified; only the recorded physical Dell/firmware/host/build/connector trial supplies historical evidence, manual DP return is required, electrical signal shutdown/repeated reliability are unproven, and cached-metadata identity limitations remain. Next live operation requires separate fresh scoped human approval; none granted or performed here. No push.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented narrowly qualified, explicitly consented 15-second app disconnect with existing watchdog/journal recovery, absent-target/relaunch status and no automation entry. Fixed the independent review transport-recapture defect with a mutation-proven regression. f1c5583 merged as 37bf06f; 362 tests pass with four opt-in skips and both warnings-as-errors builds pass on main. Native UI checked using fakes only. Owned worktree, branch and workspace removed; no live writes or push.
<!-- SECTION:FINAL_SUMMARY:END -->
