---
id: TASK-18
title: Add optional DDC input switching to app hide and show
status: Done
assignee: []
created_date: '2026-10-04 17:13'
updated_date: '2026-10-04 22:32'
labels:
  - display-hide
  - app
dependencies:
  - TASK-17
  - TASK-15
references:
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlCore/DisplayHandoff.swift
  - Sources/PanelCtlCore/DDC.swift
  - docs/ddc-input.md
  - docs/display-handoff.md
priority: medium
type: feature
ordinal: 8010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Handing a monitor to another computer from the app means hide plus an input switch, which TASK-15 sequences in the backend (switch then hide; show then switch) with DDC strictly optional. Extend the TASK-17 hide/show action with per-display input configuration rather than adding a second handoff action. Many monitors lack DDC or ignore writes, so manual monitor-button switching must remain a first-class, clearly explained outcome. Waits on TASK-15 because its supervised round trip may still change the combined behavior. Offline implementation and fake/no-write validation only; any live DDC or topology write needs fresh scoped human approval.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Per-display configuration adds optional away (other computer) and return (Mac) input codes with clear labels, using the existing ddc-input names and codes. Input switching is opt-in; unknown, unavailable or failed DDC capability explains manual monitor-button switching, and hide-only configuration never requires DDC. Saving or loading performs no DDC write or read beyond an explicit, user-initiated capability check.
- [x] #2 Hide/show with inputs follows the TASK-15 order and confirmation shows the input change before consent. A skipped or failed DDC step never blocks showing; skipped, unverified and failed input outcomes are shown distinctly from desktop hide/show success.
- [x] #3 Recovery messages distinguish returning the desktop from returning the monitor input, show the reported input recovery command or monitor-button fallback, and do not claim the input changed when readback was unavailable.
- [x] #4 Invalid input codes, a DDC target whose identity changed since capture and stale saved inputs produce actionable validation; nothing is guessed or retried.
- [x] #5 Fake tests cover DDC-capable, no-DDC, unverified, DDC failure before hiding and after showing, and stale configuration. Native Settings conditional controls are verified with synthetic states; relevant tests and warnings-as-errors builds pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend saved per-display Hide configuration with optional validated input codes, preserving identity capture and zero-I/O load/save. 2. Reuse HandoffController sequencing through guarded app-facing entry points and expose separate desktop/input outcomes and recovery details; retain journal and identity checks. 3. Add conditional native Settings input controls and consent copy, preserving Show even when input configuration is stale. 4. Exercise synthetic Settings and fake backend/app scenarios, run warnings-as-errors builds and tests, then one independent safety review. 5. Record evidence, complete eligible criteria, and commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered on main in a6afd71 (Add optional input switching to app hide and show). AC1: fake persistence/validation/capability tests verify optional named/numeric inputs, zero I/O on load/save and explicit capability reads. AC2-4: fake guarded handoff and app tests cover ordering, no-DDC skips, unverified and failed writes, stale identity/configuration refusal, Show despite input failure, consent input disclosure and separate desktop/input recovery messages. AC5: synthetic native Settings fixture exercises conditional accessible input fields. Final verification: swift test --disable-sandbox -Xswiftc -warnings-as-errors with live-blackout, ICC evidence and foreground keyboard opt-ins unset passed; 203 core tests and 81 app tests, four expected skips (live blackout, optional ICC replay, two foreground keyboard/focus fixtures). Both swift build --product panelctl -Xswiftc -warnings-as-errors and --product PanelCtlApp passed; git diff --check passed. LSP diagnostics were unknown (no version-matched report); compiler/test evidence used instead. One independent general safety review found repeat-Show DDC and loss of input outcomes after inspection failure; both fixed with focused regressions and full suite rerun. No hardware probes/writes, private setters or live qualification performed. No remaining implementation blocker; live trials still require fresh scoped approval. Claim released; no worktree created.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Optional per-display Hide/Show input switching is delivered in a6afd71 with guarded identity and journal checks, explicit consent/capability checks, separate desktop/input recovery outcomes and manual fallback. Offline fake/native coverage and warnings-as-errors tests/builds pass; both independent review findings fixed. No hardware qualification claimed.
<!-- SECTION:FINAL_SUMMARY:END -->
