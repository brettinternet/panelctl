---
id: TASK-14
title: Report DDC availability per display in probe
status: To Do
assignee: []
created_date: '2026-10-04 16:37'
labels:
  - ddc
dependencies: []
references:
  - Sources/PanelCtlCore/Probe.swift
  - Sources/PanelCtlCore/DDC.swift
  - docs/feasibility.md
  - docs/ddc-input.md
priority: medium
type: feature
ordinal: 4010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user has four external monitors and believes only two support DDC. Known: S2721DGF reads and selects inputs (TASK-10); AW3425DW reads luminance; AW3423DW luminance read failed; K272HUL untested. Users need a quick way to see which displays answer DDC before using ddc-luminance, ddc-input or the away/back command. A successful read does not prove writes are safe (docs/feasibility.md), so this reports readability only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 panelctl probe (text and JSON) reports, per active external display, whether Get VCP reads of input (0x60) and luminance (0x10) succeed, plus the failure reason (no controller, ambiguous mapping, unsupported, transport error). It sends only Get VCP requests and never writes values.
- [ ] #2 Built-in or inactive displays and non-arm64 hosts report not-applicable without a DDC attempt; one display's failure does not stop the probe of the others.
- [ ] #3 Fake-channel tests cover each outcome; focused tests and warnings-as-errors builds pass. Output and docs state that a successful read is not write qualification.
- [ ] #4 Running it on the user's real monitors requires the user's approval; observed results are recorded in docs/feasibility.md with the date and build.
<!-- AC:END -->
