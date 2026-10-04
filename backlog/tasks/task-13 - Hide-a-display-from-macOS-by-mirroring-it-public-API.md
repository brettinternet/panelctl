---
id: TASK-13
title: Hide a display from macOS by mirroring it (public API)
status: In Progress
assignee:
  - '@pi'
created_date: '2026-10-04 16:37'
updated_date: '2026-10-04 16:57'
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
- [ ] #4 A supervised trial approved by the user on the S2721DGF records: windows leaving it, mode/HDR/refresh effects on the mirror source, cursor and Spaces behavior, and a clean unmirror with verified restoration. Untested cases remain unsupported.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add explicit consent-gated mirror/unmirror CLI commands using existing selectors, RecoverySnapshot/Store locks, and public session-scoped configuration only. Journal target/source intent before mutation; refuse unsafe or changing topology.
2. Reuse RecoveryEngine restoration and exact verification for unmirror, preserving journals and reporting the explicit public recovery fallback on failure.
3. Add fake transaction/orchestration/parser tests for ordering, refusals, races and failures; document effects, limits and the pending supervised trial.
4. Run focused/full offline tests and warnings-as-errors builds; obtain one independent safety review, fix concrete findings, commit on main. Record AC4 blocked pending fresh scoped human trial approval.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Resumed existing TASK-13 implementation on primary main with explicit user handoff. Fresh offline validation: 11 DisplayMirroringTests passed; full suite 239 tests, 2 explicit skips (live blackout and optional retained ICC replay), zero failures; panelctl and PanelCtlApp warnings-as-errors builds passed; release-version checks and git diff --check passed. Exercised both mirror/unmirror executable help paths. PANELCTL_TEST_LIVE_BLACKOUT unset; no topology, gamma, DDC or private setter writes performed. LSP diagnostics unknown (no version-matched report); compiler/test results are authoritative. One independent read-only safety review is running before commit. AC4 remains gated on a fresh scoped supervised S2721DGF trial, not inferred from offline success.

Resumption validation: full warnings-as-errors offline suite passed (239 tests, 2 intentional skips), both products built with warnings-as-errors, release-version checks, CLI help and diff whitespace checks passed. Replacement independent read-only safety review d3042767-79a8-4d17-b7fe-e1564fcd6ec7 found no validated defects; prior review result was unavailable. AC1-3 verified with synthetic tests, not hardware qualification. User requested preparation of supervised AC4 trial; no write approval yet. Fresh read-only inventory: S2721DGF UUID 09084682-3C42-4455-AAB8-126A7431125B ID 1; main AW3423DW UUID 1FC57E99-DE7C-4DAF-B896-3B512CEE064F ID 5; macOS 27.0.1 build 26A434. Default recovery status reports no readable journal. Next: select source, record mode/HDR/refresh baseline and physical fallback, obtain exact mirror approval; separate fresh approval required for unmirror.
<!-- SECTION:NOTES:END -->
