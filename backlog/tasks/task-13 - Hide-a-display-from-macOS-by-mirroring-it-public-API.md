---
id: TASK-13
title: Hide a display from macOS by mirroring it (public API)
status: To Do
assignee: []
created_date: '2026-10-04 16:37'
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
- [ ] #1 An explicit command mirrors one resolved non-main external target onto an explicitly chosen or documented source display, and unmirrors it. It journals the topology before any change (reusing recovery capture), refuses existing mirrors, the main or built-in display, and ambiguous selectors, and never touches gamma, DDC, or private display APIs.
- [ ] #2 Unmirroring restores the captured arrangement, modes and main display, with verification. On mismatch or failure, the existing recovery restore path is reported as the fallback, and the journal is kept.
- [ ] #3 Fake configuration tests cover refusal cases, the journal-before-change order, verification mismatch and failure cleanup; focused tests and warnings-as-errors builds pass with no real topology changes.
- [ ] #4 A supervised trial approved by the user on the S2721DGF records: windows leaving it, mode/HDR/refresh effects on the mirror source, cursor and Spaces behavior, and a clean unmirror with verified restoration. Untested cases remain unsupported.
<!-- AC:END -->
