---
id: TASK-1
title: Verify the display-enable ABI offline on the target OS
status: Done
assignee: []
created_date: '2026-10-04 05:03'
updated_date: '2026-10-04 05:33'
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
- [x] #1 Evidence records actual OS build, architecture, framework/cache identity, exact tools/commands, symbol addresses or offsets and relevant disassembly excerpts without checking in Apple binaries or private serial dumps.
- [x] #2 The configuration-pointer argument, 32-bit display ID, boolean representation, calling convention and 32-bit CGError return are each established or explicitly unknown; CGS re-export and SLS fallback relationship are explained.
- [x] #3 A go/no-go conclusion defines the exact supported binding for TASK-4. Unresolved ABI facts keep the backend unavailable; symbol resolution alone is not marked verification.
- [x] #4 No state-changing call or surveyed application is executed; stop at the inspected function and directly necessary call sites, documenting unavailable tooling/evidence instead of expanding research.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Record changed files, validation commands/results, residual risks and handoff evidence; preserve existing checked criteria and never claim unperformed hardware qualification.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Record actual host and available read-only inspection tools; locate the CoreGraphics re-export and SkyLight implementation. 2. Inspect only the setter and directly necessary call boundary; document each ABI fact or unknown with reproducible commands. 3. Record the TASK-4 go/no-go binding gate, validate evidence and safety scope, and commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Fresh host evidence: macOS 27.0.1 build 26A434, arm64 M5 Max. Added docs/display-enable-abi.md with cache/framework UUIDs, bounded setter/producer/validator disassembly, exact commands and canonical C/Swift binding. Compile-only clang and swiftc checks passed; no fixture was linked or run. Canonical plan links the note. Independent verifier is checking ABI overclaims before finalization. No display state change, panelctl command, surveyed app, private setter, or DDC operation executed.

Explicit user handoff to this session: verify existing TASK-1 evidence and commit only TASK-1 changes; preserve concurrent TASK-2 work.

Handoff verification completed directly in this session (earlier pending verifier result was not used). Reproduced host/tool/hash/framework/cache identity and CGS-to-SLS exports; reread complete setter plus bounded begin/validator disassembly using the documented ipsw commands; compared SDK typedefs; reran both documented clang -S and swiftc -emit-assembly commands successfully and inspected canonical 0/1 argument lowering. One item-scoped evidence review found no concrete defect. No source changes or live operations; no application tests needed for this documentation-only task. git diff --check passed. Delivered docs/display-enable-abi.md and canonical-plan link in commit 23baf12 on main. Residual limits: only arm64 build 26A434/images recorded; private source typedef spelling and noncanonical boolean values remain unknown/unsupported; hardware behavior is unqualified and live writes remain forbidden. No remaining TASK-1 blocker. TASK-4 consumes the binding evidence after TASK-3; TASK-2 remains owned by its existing session and its uncommitted changes were preserved. Claim released on completion.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Verified local canonical C/Swift display-enable call ABI without executing a setter. Commit 23baf12 contains reproducible UUID/export/disassembly evidence, successful compile-only checks and TASK-4 fail-closed handoff. All four criteria verified; no hardware qualification claimed.
<!-- SECTION:FINAL_SUMMARY:END -->
