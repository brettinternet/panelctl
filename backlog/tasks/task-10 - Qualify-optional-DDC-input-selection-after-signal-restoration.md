---
id: TASK-10
title: Add explicit DDC input selection as a standalone monitor-switch path
status: In Progress
assignee:
  - '@pi'
created_date: '2026-10-04 05:03'
updated_date: '2026-10-04 16:20'
labels:
  - display-disable
  - ddc
  - human-gated
dependencies: []
references:
  - docs/ddc-input.md
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: high
type: feature
ordinal: 10
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Goal: let this Mac hand the multi-input monitor (DELL S2721DGF on DisplayPort, other computer on HDMI) to the other computer. The private display-disable path (TASK-12 then TASK-9) needs a private setter, identity matching, crash recovery and a supervised trial, and still only works if the monitor's input auto-select follows the dropped signal (unobserved). The survey identifies DDC VCP 0x60 input select as a lower-risk standalone alternative that never changes macOS topology. User decision 2026-10-04: try this first, before TASK-12/TASK-9, and park those if 0x60 works and leaving the display attached in macOS is acceptable. Reframed from the earlier post-TASK-9 follow-up; TASK-9 dependency removed. Known limitation: macOS still treats the display as attached, so windows stay on it (it is not a substitute for disable, and must not be reported as one). Reuse the existing IOAVService DDC transport from ddc-luminance. DDC 0xD6 power remains excluded. Offline code and fake-transport tests are autonomous; every real 0x60 write (and the first real read on the target) requires fresh scoped human approval with the monitor's physical input button as fallback.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An explicit CLI command reads the current input (VCP 0x60) and, only with an explicit value (MCCS name or numeric 1..255), writes it once to one resolved external display; no automatic, blind or cycling writes, no power/link control, and an unreadable current input or ambiguous controller mapping refuses before any write.
- [ ] #2 Results distinguish already-selected (no write), verified, and unverified-after-write (readback lost, expected when the monitor leaves the Mac's input); a readback of a different input is an error with a switch-back hint. Output never claims topology change or display disable.
- [ ] #3 Fake-transport tests cover request encoding, reply parsing without continuous-range assumptions, unsupported feature, transport loss before and after the write, ambiguous controller mapping, readback mismatch and already-selected; focused tests and warnings-as-errors builds pass without hardware writes.
- [ ] #4 A monitor-specific qualification record documents usage, value codes, limitations and fresh observations from a human-approved supervised trial on the target (read current input, switch to HDMI, switch back to DP from the Mac); untested behavior stays unsupported and only observed results are recorded.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Generalize DDC.swift transport/reply helpers by VCP code (shared DDCError; luminance behavior unchanged except refusing ambiguous controller mappings).
2. Add DDCInput: read current 0x60 low byte; select(value) reads first, skips if already selected, writes once, polls read-only for verification; injectable channel for fake tests.
3. Add 'panelctl ddc-input --display <selector> [--set <dp1|dp2|hdmi1|hdmi2|1..255>] [--json]' parser/help/main wiring.
4. Fake tests for AC3; focused tests and warnings-as-errors builds.
5. docs/ddc-input.md usage, codes, limitations and qualification record template; commit on main.
6. Request scoped approval for the supervised trial; record observations only after it.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Offline slice: DDC.swift now shares framing/transport by VCP code (DDCLuminanceError renamed DDCError; ambiguous controller mappings refuse, which also applies to ddc-luminance). Added DDCInput (read low byte of 0x60; select reads first, skips if already selected, writes once, read-only polls 12x250ms; verified/unverified/mismatch) and 'panelctl ddc-input'. Docs: docs/ddc-input.md with unqualified hardware record. Validation: swift test --disable-sandbox, 174 core tests (2 skipped) + 54 app tests, 0 failures (.build/task10-tests.log); panelctl and PanelCtlApp builds with -warnings-as-errors passed; git diff --check clean; LSP unknown (timed out). No real DDC read or write performed. Fresh read-only 'panelctl list': target DELL S2721DGF uuid 09084682-3C42-4455-AAB8-126A7431125B id=1, non-main. Next: scoped human approval for supervised trial.
<!-- SECTION:NOTES:END -->
