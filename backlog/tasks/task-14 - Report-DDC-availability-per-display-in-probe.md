---
id: TASK-14
title: Report DDC availability per display in probe
status: Done
assignee: []
created_date: '2026-10-04 16:37'
updated_date: '2026-10-04 17:08'
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
- [x] #1 panelctl probe (text and JSON) reports, per active external display, whether Get VCP reads of input (0x60) and luminance (0x10) succeed, plus the failure reason (no controller, ambiguous mapping, unsupported, transport error). It sends only Get VCP requests and never writes values.
- [x] #2 Built-in or inactive displays and non-arm64 hosts report not-applicable without a DDC attempt; one display's failure does not stop the probe of the others.
- [x] #3 Fake-channel tests cover each outcome; focused tests and warnings-as-errors builds pass. Output and docs state that a successful read is not write qualification.
- [x] #4 Running it on the user's real monitors requires the user's approval; observed results are recorded in docs/feasibility.md with the date and build.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reuse DDCChannel Get VCP transport to collect independent input/luminance outcomes per inventory display, skipping ineligible displays and architectures.
2. Add structured JSON and text availability plus explicit read-not-write-qualification warning; document behavior.
3. Exercise fake-channel success/refusal/failure/skip paths and output, run focused tests and warnings-as-errors builds, and perform one scoped review.
4. Request approval for read-only real-monitor probing; record dated build/results if approved, otherwise persist the gate. Commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered implementation and documentation in 9676d51 on main. Modified Probe.swift, CLIHelp.swift, ProbeTests.swift, docs/ddc-input.md and docs/feasibility.md. Reused DDCChannel; only Get VCP callbacks are invoked. Fake tests verify feature/display failure isolation, opening failure categories, no Set VCP, architecture/display skips, JSON serialization and text rendering. Verification: swift test --disable-sandbox --filter "ProbeTests|DDCTests|CLIParserTests" passed 37 tests; swift build --product panelctl -Xswiftc -warnings-as-errors and swift build --product PanelCtlApp -Xswiftc -warnings-as-errors passed; git diff --check passed. LSP diagnostics were unknown (no version-matched report), not claimed clean. One scoped manual review checked selectors, transport reuse, skips and output; no outstanding defects. User explicitly approved one read-only probe of all active external monitors. Ran .build/debug/panelctl probe --json once at 2026-10-04T17:07:01Z on arm64 macOS 27.0.1 build 26A434; exit 0. AW3425DW and K272HUL read both features; S2721DGF returned invalid-payload replies; AW3423DW returned IOReturn -535740416. Date, binary hash, build and identities/results recorded in docs/feasibility.md separately from historical evidence. No monitor values or topology changed; no retries. Successful reads are not write qualification; failures are not permanent capability verdicts. No remaining blocker or resumable step for TASK-14. Claim released; no worktree created, no push.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added per-display input/luminance DDC readability and failure reasons to probe text/JSON, with ineligible-display skips and read-not-write-qualification warnings. Delivered in 9676d51; 37 focused tests and both warnings-as-errors builds pass. Approved single hardware probe and dated build/results recorded in docs/feasibility.md. All acceptance met.
<!-- SECTION:FINAL_SUMMARY:END -->
