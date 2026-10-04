---
id: TASK-15
title: Add away/back command to hand a monitor to another computer
status: To Do
assignee: []
created_date: '2026-10-04 16:37'
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
- [ ] #1 'away' and 'back' target one resolved display, with optional input codes. Each step runs in the documented order, and a DDC step runs only when explicitly configured and a pre-read succeeds. Otherwise the step is skipped with a clear message to use the monitor's input button.
- [ ] #2 If any step fails, completed steps are reversed or the exact recovery command is reported. A failed or skipped DDC step never blocks unhiding, and hiding never proceeds if the journal capture fails.
- [ ] #3 Fake tests cover the DDC-capable path, no-DDC path, DDC failure before and after hiding, hide failure and unhide failure; focused tests and warnings-as-errors builds pass with no hardware changes.
- [ ] #4 A supervised round trip on the S2721DGF, approved by the user, is recorded; behavior on non-DDC monitors is documented as manual input switching and not claimed as tested unless observed.
<!-- AC:END -->
