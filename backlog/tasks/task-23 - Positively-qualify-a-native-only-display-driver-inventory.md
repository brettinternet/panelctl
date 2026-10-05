---
id: TASK-23
title: Positively qualify a native-only display driver inventory
status: To Do
assignee: []
created_date: '2026-10-05 05:30'
updated_date: '2026-10-05 05:30'
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
- [ ] #1 `nativeOnly` is returned only when every online CG display maps to exactly one Apple-owned framebuffer service, no non-Apple kernel extension is loaded, and no display/driver system extension is active; any unmapped, duplicate, extra, unreadable or partial evidence returns `unknown` (or `displayLink`/`virtual` when positively recognized)
- [ ] #2 The inventory is refreshed synchronously at each writer boundary, like existing environment/lifecycle refresh, and stays limited to the qualified host/arch/build scope; unsupported hosts return `unknown`
- [ ] #3 Fake-backed tests cover the passing path and each refusal path (unmapped virtual display, DisplayLink, third-party kext, active system extension, enumeration failure, duplicate mapping, unsupported host) without constructing a writer on refusal
- [ ] #4 A fresh no-write rehearsal on the target host records the driver verdict and per-target eligibility in docs/display-provider-qualification.md, keeping historical evidence separate and disclosing residual risks; no hardware write occurs
- [ ] #5 An independent safety review of the widened gate finds no unaddressed fail-open path
<!-- AC:END -->
