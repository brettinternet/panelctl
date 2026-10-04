---
id: TASK-1
title: Verify the display-enable ABI offline on the target OS
status: To Do
assignee: []
created_date: '2026-10-04 05:03'
labels:
  - display-disable
  - offline
  - first
dependencies: []
references:
  - Sources/PanelCtlCore/Probe.swift
documentation:
  - docs/display-disable-implementation-plan.md
  - docs/display-disable-tool-survey.md
priority: high
type: spike
ordinal: 1
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First recommended task. Cross-tool agreement establishes a likely CGError(CGDisplayConfigRef, CGDirectDisplayID, C bool) signature, not the ABI on the current host. Bound this investigation to the actual CoreGraphics CGSConfigureDisplayEnabled re-export and SkyLight SLSConfigureDisplayEnabled implementation/call boundary; use read-only shared-cache extraction/disassembly (xcrun dyld_info or ipsw if available), never invoke either setter. Historical host was macOS 27.0.1 build 26A434 on M5 Max; record the actual host rather than assuming it is unchanged. Existing recovery-enable branch has a true-only transport but explicitly lacks local ABI proof. Do not reopen the full identity/firmware investigation. Deliver a concise reproducible ABI evidence note, not a disable implementation.

Direction: docs/display-disable-implementation-plan.md is canonical; docs/display-disable-tool-survey.md supplies evidence, not hardware qualification. Initial scope is one non-main external display, no mirroring, Apple Silicon, session-only transactions and explicit consent. Use injected/fake display writers for routine work; no live private setter, DDC write, display change, or disruptive recovery is authorized by this task. Preserve unresolved journals and fail closed on unknown identity. Record any real external blocker and the exact evidence or human approval needed; never weaken a guard to mark the task done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Evidence records actual OS build, architecture, framework/cache identity, exact tools/commands, symbol addresses or offsets and relevant disassembly excerpts without checking in Apple binaries or private serial dumps.
- [ ] #2 The configuration-pointer argument, 32-bit display ID, boolean representation, calling convention and 32-bit CGError return are each established or explicitly unknown; CGS re-export and SLS fallback relationship are explained.
- [ ] #3 A go/no-go conclusion defines the exact supported binding for TASK-4. Unresolved ABI facts keep the backend unavailable; symbol resolution alone is not marked verification.
- [ ] #4 No state-changing call or surveyed application is executed; stop at the inspected function and directly necessary call sites, documenting unavailable tooling/evidence instead of expanding research.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->
