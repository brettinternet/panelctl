---
id: TASK-13
title: Hide a display from macOS by mirroring it (public API)
status: Done
assignee: []
created_date: '2026-10-04 16:37'
updated_date: '2026-10-04 17:03'
labels:
  - display-hide
  - mirror
  - human-gated
dependencies: []
references:
  - docs/ddc-input.md
  - docs/display-disable-tool-survey.md
  - docs/display-recovery.md
  - Sources/PanelCtlCore/DisplayRecovery.swift
priority: high
type: spike
ordinal: 3010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When the DELL S2721DGF is switched to HDMI with ddc-input (TASK-10), macOS still treats it as a separate screen, so windows and the cursor can hide on it. The user wants it gone from the Mac's usable desktop while it shows the other computer. The private disable path (TASK-12, then TASK-9) is heavy and blocked on identity matching. User decision 2026-10-04: try the public CGConfigureDisplayMirrorOfDisplay path first. Mirroring makes the target a mirror of another display, so windows migrate and it is no longer a separate desktop. Because DDC has already moved the monitor's input, the survey's zero-gamma blackout is unnecessary and must not be used (it risks leaving a screen blank). The existing recovery capture/verify/restore already journals and restores mirroring and modes; reuse it instead of a new framework. Risks to observe: mode, HDR or refresh changes on the mirror source, window and Spaces placement, and clean unmirror. Offline work and fake tests are autonomous. Every real mirror/unmirror needs fresh scoped human approval, with recovery restore as the documented fallback.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An explicit command mirrors one resolved non-main external target onto an explicitly chosen or documented source display, and unmirrors it. It journals the topology before any change (reusing recovery capture), refuses existing mirrors, the main or built-in display, and ambiguous selectors, and never touches gamma, DDC, or private display APIs.
- [x] #2 Unmirroring restores the captured arrangement, modes and main display, with verification. On mismatch or failure, the existing recovery restore path is reported as the fallback, and the journal is kept.
- [x] #3 Fake configuration tests cover refusal cases, the journal-before-change order, verification mismatch and failure cleanup; focused tests and warnings-as-errors builds pass with no real topology changes.
- [x] #4 A supervised trial approved by the user on the S2721DGF records: windows leaving it, mode/HDR/refresh effects on the mirror source, cursor and Spaces behavior, and a clean unmirror with verified restoration. Untested cases remain unsupported.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add explicit consent-gated mirror/unmirror CLI commands using existing selectors, RecoverySnapshot/Store locks, and public session-scoped configuration only. Journal target/source intent before mutation; refuse unsafe or changing topology.
2. Reuse RecoveryEngine restoration and exact verification for unmirror, preserving journals and reporting the explicit public recovery fallback on failure.
3. Add fake transaction/orchestration/parser tests for ordering, refusals, races and failures; document effects, limits and the pending supervised trial.
4. Run focused/full offline tests and warnings-as-errors builds; obtain one independent safety review, fix concrete findings, commit on main. Record AC4 blocked pending fresh scoped human trial approval.

5. Completed with fresh per-operation human approvals: observed one S2721DGF/AW3423DW mirror/unmirror cycle, verified restoration, and recorded the bounded qualification in docs/display-mirroring.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Resumed existing TASK-13 implementation on primary main with explicit user handoff. Fresh offline validation: 11 DisplayMirroringTests passed; full suite 239 tests, 2 explicit skips (live blackout and optional retained ICC replay), zero failures; panelctl and PanelCtlApp warnings-as-errors builds passed; release-version checks and git diff --check passed. Exercised both mirror/unmirror executable help paths. PANELCTL_TEST_LIVE_BLACKOUT unset; no topology, gamma, DDC or private setter writes performed. LSP diagnostics unknown (no version-matched report); compiler/test results are authoritative. One independent read-only safety review is running before commit. AC4 remains gated on a fresh scoped supervised S2721DGF trial, not inferred from offline success.

Resumption validation: full warnings-as-errors offline suite passed (239 tests, 2 intentional skips), both products built with warnings-as-errors, release-version checks, CLI help and diff whitespace checks passed. Replacement independent read-only safety review d3042767-79a8-4d17-b7fe-e1564fcd6ec7 found no validated defects; prior review result was unavailable. AC1-3 verified with synthetic tests, not hardware qualification. User requested preparation of supervised AC4 trial; no write approval yet. Fresh read-only inventory: S2721DGF UUID 09084682-3C42-4455-AAB8-126A7431125B ID 1; main AW3423DW UUID 1FC57E99-DE7C-4DAF-B896-3B512CEE064F ID 5; macOS 27.0.1 build 26A434. Default recovery status reports no readable journal. Next: select source, record mode/HDR/refresh baseline and physical fallback, obtain exact mirror approval; separate fresh approval required for unmirror.

Implementation committed on main as e42b28a. Supervised-trial preparation: user selected main Dell AW3423DW (UUID 1FC57E99-DE7C-4DAF-B896-3B512CEE064F) as source, confirmed source HDR off and presence with another usable screen, and accepted manual Displays-settings correction as fallback. Read-only system report: source 3440x1440 at 175 Hz; S2721DGF 1440x2560 at 165 Hz, rotation 270. Exact mirror approval still required; no topology writes yet.

Supervised AC4 cycle completed 2026-10-04 on e42b28a, M5 Max/macOS 27.0.1 build 26A434. User explicitly approved one S2721DGF-to-main-AW3423DW mirror, then separately one unmirror. Mirror verified; user observed windows migrate, no hidden cursor desktop, usable Spaces/source, HDR still off. Source stayed 3440x1440/175 Hz; target mirrored at 3440x1440/165 Hz with rotation 270 unchanged. Unmirror exact-snapshot verification and separate recovery verify passed; all original modes/arrangement/main returned, user confirmed visible restoration. Journal 45D19BD5-13A5-4328-BAE3-E5E4196BCF6D retained at default path in restored state. No DDC, gamma, private setter, fallback or repeat writes. Trial evidence documented in docs/display-mirroring.md. Other tuples and crash/hotplug/HDR-on cases remain unsupported; all future writes require fresh scoped approval. No remaining TASK-13 blocker or resumable step; claim released.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Delivered public session-scoped mirror/unmirror with durable journal, strict refusals and verified restoration in e42b28a. Offline suite: 239 tests, 2 intentional skips, zero failures; both warnings-as-errors builds and release-version checks passed. Independent safety review found no validated defects. One separately approved S2721DGF/AW3423DW mirror/unmirror cycle passed machine verification and user observations; journal retained. Qualification limited to that recorded setup.
<!-- SECTION:FINAL_SUMMARY:END -->
