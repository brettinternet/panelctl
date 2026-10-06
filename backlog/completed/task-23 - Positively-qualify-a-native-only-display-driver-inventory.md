---
id: TASK-23
title: Positively qualify a native-only display driver inventory
status: Done
assignee: []
created_date: '2026-10-05 05:30'
updated_date: '2026-10-05 05:58'
labels:
  - display-disable
  - offline
dependencies:
  - TASK-12
references:
  - Sources/PanelCtlCore/RecoveryProductionProviders.swift
  - Sources/PanelCtlCore/RecoveryEligibility.swift
documentation:
  - docs/display-provider-qualification.md
  - docs/display-disable-implementation-plan.md
priority: high
type: task
ordinal: 13010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user needs the Mac DisplayPort signal to drop so monitors without DDC auto-select another input; mirror hide and DDC input select cannot do that. TASK-9 (supervised private disable trial) is technically blocked because the production driver observation (`driverObservation()` in Sources/PanelCtlCore/RecoveryProductionProviders.swift) only denylists DisplayLink/virtual names and deliberately returns `unknown` otherwise, so every target is refused with "DisplayLink, virtual or unknown driver state". Absence of a recognized name must never count as native-only. Replace that with a positive, fail-closed inventory. On Apple Silicon, DisplayLink, Sidecar and AirPlay are user-space virtual displays without an Apple framebuffer, so mapping every online CG display to exactly one Apple framebuffer is the key completeness signal; non-Apple kexts and active system extensions are secondary. Read-only observation on Mac17,14 build 26A434 (2026-10-05): 5 IOMobileFramebufferShim services, no non-Apple loaded kexts, 0 system extensions. Offline only: no private setter, DDC, topology or helper arming. Success removes only the driver technical gate; TASK-9 still needs fresh scoped human consent.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `nativeOnly` is returned only when every online CG display maps to exactly one Apple-owned framebuffer service, no non-Apple kernel extension is loaded, and no display/driver system extension is active; any unmapped, duplicate, extra, unreadable or partial evidence returns `unknown` (or `displayLink`/`virtual` when positively recognized)
- [x] #2 The inventory is refreshed synchronously at each writer boundary, like existing environment/lifecycle refresh, and stays limited to the qualified host/arch/build scope; unsupported hosts return `unknown`
- [x] #3 Fake-backed tests cover the passing path and each refusal path (unmapped virtual display, DisplayLink, third-party kext, active system extension, enumeration failure, duplicate mapping, unsupported host) without constructing a writer on refusal
- [x] #4 A fresh no-write rehearsal on the target host records the driver verdict and per-target eligibility in docs/display-provider-qualification.md, keeping historical evidence separate and disclosing residual risks; no hardware write occurs
- [x] #5 An independent safety review of the widened gate finds no unaddressed fail-open path
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a host-scoped positive inventory: complete Apple framebuffer registry enumeration, unique CoreDisplay path mapping for every online CG display, loaded-kext and system-extension observations; fail closed on partial or unexpected evidence. 2. Reuse synchronous environment refresh at every private writer boundary; add fake inventory/parser and refusal-before-writer/race tests. 3. Run no-write host rehearsal, document exact evidence and residual risks, obtain one independent safety review and correct concrete scoped findings. 4. Run focused/full checks, commit implementation, merge main, finalize backlog and clean up owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented positive host-scoped native inventory in session-owned .worktrees/task-23-native-inventory (branch task-23-native-inventory, creation receipt .git/worktrees/task-23-native-inventory/agent-creation.json; Pi session 01a10a8a-6ce3-7120-bd68-2bbd2a6833ff). Focused inventory/CLI tests passed 20 tests; full swift test --disable-sandbox and both products built with warnings-as-errors successfully. Fresh no-write rehearsal: nativeOnly, 4 online CG displays map uniquely to 5 Apple DCP slots, 269 Apple loaded kexts, 0 system extensions; three non-main targets eligible with survivor candidates. No hardware writes, helper arming or journal creation. Independent safety review in progress (workflow 39c15001-6d0e-456b-adb8-3ee5b8e060da, child c435e25d-7a13-445e-8bad-030692510e66). LSP diagnostic timeout is unknown, not clean. Next: consume review, correct concrete scoped findings, rerun affected checks, commit/merge and finalize.

Delivered 47108cd (Qualify native display driver inventory), fast-forward merged to main. Independent safety review c435e25d-7a13-445e-8bad-030692510e66 found no validated defects; one general review only. Full suite: 320 tests, four skips, zero failures; both products built with warnings-as-errors; git diff --check passed. Command timeout/stderr/oversized-output/invalid-UTF-8 branches lack direct tests, disclosed in docs. Actual post-disable registry behavior remains untested and is a TASK-9 hardware gate. Worktrunk removed the verified session-owned implementation checkout and branch; historical recovery-enable is untouched and not owned by this session. No task-level blocker remains. Next: TASK-9 fresh no-write preflight and exact scoped consent before any live write, not automatic execution.

Cleanup verified: Worktrunk deleted task-23-native-inventory checkout and branch; post-remove hook closed its exact Herdr workspace w1Y, confirmed absent from workspace list. No owned checkout/workspace retained. Existing recovery-enable remains because it was not created or adopted by this session.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented and merged host/build-scoped positive native-only driver inventory (47108cd), preserving refusal on incomplete, ambiguous or prohibited evidence and synchronous refresh at private writer boundaries. Fake tests and metadata-only host rehearsal passed; independent safety review found no defects. Four online displays mapped uniquely to five Apple DCP slots, 269 Apple loaded kexts and zero system extensions. All three non-main targets were eligible without writes. Full suite 320 tests/four skips; both warnings-as-errors builds passed. TASK-9 remains separately human-gated.
<!-- SECTION:FINAL_SUMMARY:END -->
