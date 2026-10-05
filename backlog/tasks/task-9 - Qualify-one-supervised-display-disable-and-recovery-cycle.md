---
id: TASK-9
title: Qualify one supervised display-disable and recovery cycle
status: To Do
assignee: []
created_date: '2026-10-04 05:03'
updated_date: '2026-10-05 04:26'
labels:
  - display-disable
  - human-gated
  - hardware
dependencies:
  - TASK-8
  - TASK-12
references:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
  - docs/recovery-validation.md
  - docs/display-disable-trial.md
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: low
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
- [ ] #1 Before any write, record scoped consent, host/OS/monitor/firmware/connection and qualification evidence, private journal location, independent helper readiness/deadline, usable surviving physical screen and agreed fallback. No concurrent topology changes or mirroring are allowed.
- [ ] #2 For the approved simple cycle, record disable result, public enumeration, observed signal/standby versus no-signal message, HDMI auto-select and HPD where readable; on retained-ID enable record driver acceptance, visible output and whether input returns to DP.
- [ ] #3 Verify restored connectivity/topology/exact mode and disclose HDR/color/rotation/window/Spaces limits; user-visible output matters, not just return codes. Preserve evidence and stop on the first unexplained mismatch without repeated toggling.
- [ ] #4 Global restore alone, logout, reboot, hotplug and crash/sleep trials each require separate explicit approval after the simple cycle. Record each as observed or untested; same-port replug is never promised as recovery.
- [ ] #5 Publish a scoped verdict: qualified only for the tested tuple and observations, or failed/blocked with follow-up work and remaining gates. Do not call the feature reliable or mark successful-cycle acceptance met on a refusal or failed recovery.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Completed: inspected production provider defaults and reran refusal-before-writer test.
2. Completed: prepared docs/display-disable-trial.md with pending consent/evidence fields and exact technical blockers.
3. Completed: user chose to scope an offline prerequisite; created TASK-11. Release claim and commit preparation.
4. Blocked: resume the supervised cycle only after real provider qualification and fresh scoped consent; no acceptance claimed for unperformed hardware work.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Preparation only: docs/display-disable-trial.md records blocked verdict and full trial evidence template. Fresh swift test --disable-sandbox --filter RecoveryCLITests/testProductionProviderRefusesBeforeConstructingAnyWriter passed (1 test, 0 failures); production inventory refuses before writer construction even with awake injected. Inspected RecoveryPrivateSession and RecoveryReenable: no qualified production identity binding, physical/driver environment or initial awake evidence. One documentation review checked template against all five criteria and existing safety contract; no code changes or hardware calls. User explicitly selected Scope an offline prerequisite; TASK-11 now tracks bounded offline provider qualification and is an additional dependency. Consent for hardware was not requested as sufficient or granted. All TASK-9 criteria remain unchecked; no journal/helper/worktree created, no existing evidence discarded. Next: TASK-11, then qualified actual target and fresh exact-target/timeout/survivor/presence/fallback consent. TASK-10 still waits on actual trial input observations. Claim released; To Do denotes blocked, not live-ready.

Delivery: 160df2e on main commits trial preparation and the user-approved TASK-11 prerequisite. git diff --check passed. No push; no live qualification claimed.

TASK-11 bounded assessment and independent review confirm the technical gate remains closed: no qualified fresh acquisition/retained-CG mapping/replacement invalidation, physical target/survivor and driver classification, initial awake/lid state, or synchronous recovery-boundary environment refresh. See docs/display-provider-qualification.md. No hardware qualification or write permission. User requested a scoped investigation proposal; the document proposes one static DCP BUND/operation-7 reconstruction and producer/invalidation trace, execution approval pending. Next: obtain approval of that exact bounded scope or defer; even success requires separate mapping/preflight qualification and fresh trial consent.

2026-10-04 user decision: identity bar reverts to the canonical plan's bounded capture-evidence matching contract. Technical gate now waits on TASK-12 (plan-contract providers + no-write rehearsal), not TASK-11 AC2 or firmware research. Live trial still needs fresh scoped consent.

Parked 2026-10-04 by user decision: DDC input select works (TASK-10), and public mirroring (TASK-13) is the first route to hide the display. Resume only if mirroring fails or its side effects are unacceptable, or if the signal must drop so monitors without DDC can switch inputs automatically. Away/back command: TASK-15.

TASK-12 offline implementation now supplies bounded capture/current identity and real read-only preflight providers; independent safety review findings corrected with regressions. Fresh no-write rehearsal on Mac17,14 arm64 build 26A434 found matching connected identity, awake physical target/survivor candidates, but every target refused: DisplayLink, virtual or unknown driver state. Production scan cannot qualify a complete native-only driver inventory and deliberately returns unknown. Technical gate remains closed until complete driver inventory is positively qualified; never treat absence of recognized names as native-only. See docs/display-provider-qualification.md for current evidence and residual cached-metadata/ID-reuse risks. Prior live-work parking remains; no private setter, restoration, DDC, topology trial or helper arming occurred. Fresh exact-target/timeout/survivor/presence/fallback consent is still mandatory; no TASK-9 acceptance is claimed.
<!-- SECTION:NOTES:END -->
