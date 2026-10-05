---
id: TASK-9
title: Qualify one supervised display-disable and recovery cycle
status: Done
assignee: []
created_date: '2026-10-04 05:03'
updated_date: '2026-10-05 22:01'
labels:
  - display-disable
  - human-gated
  - hardware
dependencies:
  - TASK-8
  - TASK-12
  - TASK-23
references:
  - docs/display-disable.md
  - docs/display-disable-tool-survey.md
documentation:
  - docs/display-disable.md
  - docs/display-disable-tool-survey.md
  - docs/display-disable-trial.md
priority: high
type: task
ordinal: 9
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
HUMAN GATE: this item is not autonomously executable merely because dependencies are Done. Ask the user for explicit approval of the exact target, short timeout, another verified usable physical display, presence during the test, and acceptable physical fallback. Historical target is non-main DELL S2721DGF on Mac DisplayPort with another computer on HDMI; rediscover actual identities and connection, never reuse historical numeric IDs. Technical gate: production identity/preflight must positively qualify this target and helper must be armed. If it cannot, record the exact blocker; do not call the setter or relax identity checks. Prepare evidence/template autonomously, then pause for approval. Unattended private calls, even online enable, are forbidden.

Direction: docs/display-disable-implementation-plan.md is canonical. This task is approval-gated; task creation and dependency completion do not grant live-write permission. Preserve unresolved journals and report exact blockers. No DDC power, blind IDs, permanent writes or automatic disruptive fallback.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Before any write, record scoped consent, host/OS/monitor/firmware/connection and qualification evidence, private journal location, independent helper readiness/deadline, usable surviving physical screen and agreed fallback. No concurrent topology changes or mirroring are allowed.
- [x] #2 For the approved simple cycle, record disable result, public enumeration, observed signal/standby versus no-signal message, HDMI auto-select and HPD where readable; on retained-ID enable record driver acceptance, visible output and whether input returns to DP.
- [x] #3 Verify restored connectivity/topology/exact mode and disclose HDR/color/rotation/window/Spaces limits; user-visible output matters, not just return codes. Preserve evidence and stop on the first unexplained mismatch without repeated toggling.
- [x] #4 Global restore alone, logout, reboot, hotplug and crash/sleep trials each require separate explicit approval after the simple cycle. Record each as observed or untested; same-port replug is never promised as recovery.
- [x] #5 Publish a scoped verdict: qualified only for the tested tuple and observations, or failed/blocked with follow-up work and remaining gates. Do not call the feature reliable or mark successful-cycle acceptance met on a refusal or failed recovery.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Complete: claimed on main, created receipt-owned worktree, passed no-write production preflight and five-second independent helper rehearsal. 2. Complete: recorded exact target/firmware/connection, user presence, 15-second deadline, usable survivor and manual-input fallback. 3. Complete: initial ABI-path refusal made no writes; user approved scoped offline correction, tests and one independent safety review. 4. Complete: fresh explicit consent, one corrected live cycle, user observations and no-write verification; no repeated successful toggle or disruptive fallback. 5. Complete: committed reviewed fix and scoped evidence, merged to main, reran core recovery tests, removed verified owned worktree/branch/Herdr workspace and released claim.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Preparation only: docs/display-disable-trial.md records blocked verdict and full trial evidence template. Fresh swift test --disable-sandbox --filter RecoveryCLITests/testProductionProviderRefusesBeforeConstructingAnyWriter passed (1 test, 0 failures); production inventory refuses before writer construction even with awake injected. Inspected RecoveryPrivateSession and RecoveryReenable: no qualified production identity binding, physical/driver environment or initial awake evidence. One documentation review checked template against all five criteria and existing safety contract; no code changes or hardware calls. User explicitly selected Scope an offline prerequisite; TASK-11 now tracks bounded offline provider qualification and is an additional dependency. Consent for hardware was not requested as sufficient or granted. All TASK-9 criteria remain unchecked; no journal/helper/worktree created, no existing evidence discarded. Next: TASK-11, then qualified actual target and fresh exact-target/timeout/survivor/presence/fallback consent. TASK-10 still waits on actual trial input observations. Claim released; To Do denotes blocked, not live-ready.

Delivery: 160df2e on main commits trial preparation and the user-approved TASK-11 prerequisite. git diff --check passed. No push; no live qualification claimed.

TASK-11 bounded assessment and independent review confirm the technical gate remains closed: no qualified fresh acquisition/retained-CG mapping/replacement invalidation, physical target/survivor and driver classification, initial awake/lid state, or synchronous recovery-boundary environment refresh. See docs/display-provider-qualification.md. No hardware qualification or write permission. User requested a scoped investigation proposal; the document proposes one static DCP BUND/operation-7 reconstruction and producer/invalidation trace, execution approval pending. Next: obtain approval of that exact bounded scope or defer; even success requires separate mapping/preflight qualification and fresh trial consent.

2026-10-04 user decision: identity bar reverts to the canonical plan's bounded capture-evidence matching contract. Technical gate now waits on TASK-12 (plan-contract providers + no-write rehearsal), not TASK-11 AC2 or firmware research. Live trial still needs fresh scoped consent.

Parked 2026-10-04 by user decision: DDC input select works (TASK-10), and public mirroring (TASK-13) is the first route to hide the display. Resume only if mirroring fails or its side effects are unacceptable, or if the signal must drop so monitors without DDC can switch inputs automatically. Away/back command: TASK-15.

TASK-12 offline implementation now supplies bounded capture/current identity and real read-only preflight providers; independent safety review findings corrected with regressions. Fresh no-write rehearsal on Mac17,14 arm64 build 26A434 found matching connected identity, awake physical target/survivor candidates, but every target refused: DisplayLink, virtual or unknown driver state. Production scan cannot qualify a complete native-only driver inventory and deliberately returns unknown. Technical gate remains closed until complete driver inventory is positively qualified; never treat absence of recognized names as native-only. See docs/display-provider-qualification.md for current evidence and residual cached-metadata/ID-reuse risks. Prior live-work parking remains; no private setter, restoration, DDC, topology trial or helper arming occurred. Fresh exact-target/timeout/survivor/presence/fallback consent is still mandatory; no TASK-9 acceptance is claimed.

Un-parked 2026-10-05 by user decision: the Mac DP signal must drop so monitors without DDC auto-select another input; mirror hide/DDC do not cover that. Remaining technical gate (complete native-only driver inventory) is tracked by TASK-23. Key open question for the trial: whether private disable actually drops the DP signal (HDMI auto-select per AC2) or only enters standby; if standby only, this route does not meet the goal. Still human-gated; no write permission implied.

Fresh 2026-10-05 no-write preflight on 8ce614e: Mac17,14/arm64/26A434, identity eligible, nativeOnly, awake, no mirroring; DELL S2721DGF ID 1 UUID 09084682-3C42-4455-AAB8-126A7431125B on USB-C@3/DP eligible. Two provider tests and CLI build passed. Five-second independent no-write helper rehearsal verified (task-9-rehearsal-20261005.json, helper 92803). User explicitly approved one 15-second cycle, confirmed usable main Dell AW3423DW survivor, awake HDMI source, physical presence and no concurrent changes; fallback stop and manual DP selection only. Firmware M3T101 supplied by user. No writes yet. Owned worktree .worktrees/task-9-supervised-trial, branch task-9-supervised-trial; Git-local agent-creation.json records session 01a10aad-8e5a-7226-b088-b77fdd31b225, creation commit 8ce614e. Evidence in docs/display-disable-trial.md; private journal will be task-9-cycle-20261005.json in existing private Recovery directory. Next: one approved cycle and physical observations, no repeated toggling.

The single approved command refused before journal creation/helper arming/private calls: unverified ABI image for CGSConfigureDisplayEnabled. Read-only dlopen/dlsym/dladdr and Mach-O UUID observation proves both expected UUIDs match, but dyld returns CoreGraphics.framework/Versions/A/CoreGraphics and SkyLight.framework/Versions/A/SkyLight while code compares unversioned paths. Evidence retained in private Recovery/task-9-evidence-20261005. User explicitly approved offline resolver fix with tests/review, then ask before retry; no further live attempt currently authorized.

Offline fix uses exact Versions/A install names without path normalization or broader origin acceptance. Nine binding tests and 96 core recovery tests (one skip) passed; both products build with warnings-as-errors. Independent review 135a6828-9610-49b3-ba58-9b579084edde found no validated defects. Full suite has app protection failures, representative reproduced unchanged on main; broad recovery-name app test filter also crashes, disclosed separately. User now explicitly approved one corrected 15-second attempt with same Dell/M3T101/DP target, physical presence, usable AW3423DW survivor, awake HDMI source, no concurrent changes, stop/manual-DP fallback. No hardware success claimed.

Delivered resolver fix 2431c17 and trial evidence 12e455e, merged to main as f0efa13 (main advanced independently with release-script/backlog commits, preserved via non-fast-forward merge). Changed Sources/PanelCtlCore/RecoveryDisplayBinding.swift, Tests/PanelCtlCoreTests/RecoveryDisplayBindingTests.swift, docs/display-disable.md, docs/display-disable-trial.md, and this task. Corrected live command at 2026-10-05 19:47 UTC exited 0. Journal F602F78F-CDD1-4E82-912F-787B5ED90001 at ~/Library/Application Support/PanelCtl/Recovery/task-9-cycle-20261005.json, helper 67898, armed before disable, deadline 19:47:22.727, disable completed and retained-ID enable attempted, restored by sampled 19:47:27.086, authority closed. User observed HDMI auto-selection; monitor stayed on HDMI on recovery; manual DP selection restored normal portrait Mac output and survivor remained usable. No-signal/standby message uncertain. HPD High/Active/link-rate metadata unchanged while ID 1 absent from public enumeration, so electrical link shutdown not claimed. Exact topology/modes verified, and separate recovery verify exited 0 without writes. Qualified only for this physical Dell S2721DGF/M3T101, Mac17,14/arm64/26A434, USB-C@3/DP tuple and one cycle, with manual input return. No reliability, automatic DP return, HDR/color/windows/Spaces restoration, or disruptive recovery claims.

Verification: swift test --disable-sandbox --filter RecoveryDisplayBindingTests passed 9; swift test --disable-sandbox --filter PanelCtlCoreTests\.(Recovery|DisplayRecovery) passed 96 with one skip before and after integration; swift build --product panelctl -Xswiftc -warnings-as-errors and equivalent PanelCtlApp build passed; git diff --check passed. Full suite not green: app protection assertions fail; representative testPartialMembershipUpdatesModelAndRestoreWithoutFullLifecycle reproduced on unchanged main. Broad recovery-name filter also crashed in app DisplayHideAppTests:1882; core-qualified filter passes. These unrelated app-test issues remain disclosed, not fixed. One independent reviewer found no validated scoped defect. Test logs, post-verify JSON and raw trial evidence retained in private Recovery/task-9-evidence-20261005-corrected; earlier refused evidence and rehearsal retained separately. Cleanup: verified Git-local receipt against current Worktrunk listing; exact Herdr w22 contained only an idle zsh; Worktrunk deleted checkout and branch, post-remove hook closed w22, subsequent workspace list confirmed absence. No owned worktree/workspace retained. Existing recovery-enable untouched as unowned. Remaining gates: separate approval for any new cycle, global restore, logout/reboot, hotplug/crash/sleep or DDC trial. Next separately requested work may consume the scoped observations for TASK-20; automatic DP focus remains a separate solution. No push.

Post-completion review: docs/feasibility.md still called private disable unqualified; updated to the scoped one-tuple trial verdict (6b65525). Full suite (241 core + 147 app tests, 4 skips) and warnings-as-errors builds pass.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Completed one explicitly approved supervised cycle on DELL S2721DGF/M3T101, Mac17,14/26A434, USB-C@3/DP. HDMI auto-selection worked; retained-ID recovery and exact topology/modes verified; visible Mac output required manual DP input selection. Corrected exact framework install-name validation without weakening ABI guards (2431c17), documented evidence (12e455e), merged f0efa13. Independent safety review clean; 96 focused recovery tests pass, one skip; both products build. Existing app-suite failures disclosed. Journal/evidence retained; owned worktree, branch and workspace removed. Scoped qualification only, no further hardware permission.
<!-- SECTION:FINAL_SUMMARY:END -->
