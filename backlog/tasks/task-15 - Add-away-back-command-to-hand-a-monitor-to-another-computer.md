---
id: TASK-15
title: Add away/back command to hand a monitor to another computer
status: Done
assignee: []
created_date: '2026-10-04 16:37'
updated_date: '2026-10-04 18:14'
labels:
  - display-hide
  - ddc
dependencies:
  - TASK-13
references:
  - docs/ddc-input.md
  - Sources/PanelCtlCore/DDC.swift
priority: medium
type: feature
ordinal: 5010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user wants one action to hand a multi-input monitor to another computer and one to take it back. Today that takes ddc-input plus a separate way to hide the display, done in the right order. Hiding comes from TASK-13 (mirroring). Many monitors lack DDC or ignore writes (the AW3423DW failed a luminance read), so DDC must be an optional, capability-dependent step, never a requirement. Order: away = DDC switch (if available) then hide; back = unhide then DDC switch (if available). This keeps a DDC-capable monitor reachable by DDC throughout. Without DDC, the command still hides/unhides and tells the user to use the monitor's input button. With mirroring the Mac keeps sending a signal, so such monitors will not switch inputs automatically. TASK-12/TASK-9 (private disable, signal drop) stay parked as the possible later route for that case.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 'away' and 'back' target one resolved display, with optional input codes. Each step runs in the documented order, and a DDC step runs only when explicitly configured and a pre-read succeeds. Otherwise the step is skipped with a clear message to use the monitor's input button.
- [x] #2 If any step fails, completed steps are reversed or the exact recovery command is reported. A failed or skipped DDC step never blocks unhiding, and hiding never proceeds if the journal capture fails.
- [x] #3 Fake tests cover the DDC-capable path, no-DDC path, DDC failure before and after hiding, hide failure and unhide failure; focused tests and warnings-as-errors builds pass with no hardware changes.
- [x] #4 A supervised round trip on the S2721DGF, approved by the user, is recorded; behavior on non-DDC monitors is documented as manual input switching and not claimed as tested unless observed.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend the existing mirror controller closure seams so optional DDC runs after durable capture and before hiding, or after verified unhiding, under the existing locks; bind back to the journal target.
2. Add strict away/back CLI parsing, help and manual-input/recovery documentation. Reuse DDC input parsing and one-write selection; print exact input recovery before writes.
3. Exercise fake ordered handoffs, skip/failure paths, journal refusal and target binding; run warnings-as-errors tests/builds and one independent safety review.
4. Commit offline work on main. Request fresh scoped consent for the required supervised S2721DGF round trip; leave AC4 pending until observed and record any blocker.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Resumed existing main changes with explicit user handoff. Offline verification: 47 focused tests passed; complete swift test --disable-sandbox -Xswiftc -warnings-as-errors passed with live blackout and ICC replay opt-ins unset; panelctl and PanelCtlApp warnings-as-errors builds passed; git diff --check passed. LSP diagnostics unknown (bounded wait), compiler checks authoritative. One independent safety review found a duplicate DDC pre-read could abort optional handoff; fixed by sharing the validated pre-read with DDCInput.select, preserving standalone read-first behavior. Added initial-read failure and lost-readback regression cases and reran full tests/builds. No hardware writes performed. User requested preparation of supervised trial; AC4 pending exact scoped approval and observation. Fresh read-only discovery: S2721DGF UUID 09084682-3C42-4455-AAB8-126A7431125B ID1, 1440x2560 165Hz rotation270; AW3423DW source UUID 1FC57E99-DE7C-4DAF-B896-3B512CEE064F ID5 main 3440x1440 175Hz. macOS27.0.1 build26A434 M5 Max. Current target input read is 0x0F; existing default journal is restored.

Completed supervised S2721DGF round trip on 2026-10-04 using implementation commit 0308e43. User explicitly approved one away after confirming presence, HDMI1 other-computer input, usable AW3423DW source, both HDR off and physical/manual fallback; separately approved one back after confirming visible handoff. Away verified HDMI1 then mirroring. Back verified restoration then DP1; separate recovery verify passed. User confirmed restored visible Mac output, arrangement, windows/Spaces and HDR with no unexpected residual changes. Journal 1508F303-6EC8-4F99-A149-EAD7A816DBDD retained restored at default path. No retries/private/gamma/fallback writes. Full observed evidence and qualification limits in docs/display-handoff.md. Final help/docs updated and 47 focused tests, both warnings-as-errors builds and diff check passed again. Independent review finding fixed and regression-tested; no remaining task blocker or resumable step. Unrelated concurrent edits to TASK-16/17/18 left untouched.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented and committed optional-DDC away/back CLI in 0308e43 with durable journal ordering, strict target binding, manual-input skips and exact recovery instructions. Full offline suite and warnings-as-errors builds passed; one independent safety review correction regression-tested. Separately approved S2721DGF HDMI1/DP1 round trip passed API and user-visible verification; journal restored. Non-DDC hardware remains untested, documented as manual-input switching. All four acceptance criteria met.
<!-- SECTION:FINAL_SUMMARY:END -->
