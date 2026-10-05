---
id: TASK-29
title: Add opt-in DDC monitor power control with honest manual recovery
status: To Do
assignee: []
created_date: '2026-10-05 16:36'
updated_date: '2026-10-05 16:38'
labels:
  - ddc
  - power
dependencies: []
references:
  - Sources/PanelCtlCore/DDC.swift
  - Sources/PanelCtlCore/CLIParser.swift
  - 'https://github.com/kfix/ddcctl/issues/89'
  - TASK-28
documentation:
  - docs/feasibility.md
  - docs/ddc-input.md
  - docs/display-disable-implementation-plan.md
  - docs/display-hide-ux.md
  - docs/usage.md
priority: medium
type: feature
ordinal: 19010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
User requests planning DDC power support: inability to wake over DDC is acceptable when the user can restore power physically, rather than a blanket reason to exclude the feature. Deliver CLI-first experimental power control, with power semantics distinct from input selection, macOS topology hiding and private disconnect, but not a competing product interaction model. Current support remains input and luminance only. Manual recovery is not guaranteed: ddcctl issue 89 reports an LG requiring power removal and physical-button faults on other hardware; the original report mixed power and another command, so causality and permanent damage are unproven. This is future work, not authorization to implement or run hardware commands in the planning session. Offline implementation can be picked up separately; any real power read/write trial needs fresh scoped approval. Existing private-disconnect exclusions remain intact; this task is the separate opt-in power scope. App implementation and unattended automation are deferred, but documenting how power fits the current app design is part of this task, not deferred. User direction: extend the existing per-display Hide-style configuration, display tiles, Hide/Show actions, inline outcomes and recovery presentation; do not introduce separate Power buttons, a parallel menu, a new settings page or a second recovery workflow. Use the current design amendment in docs/display-hide-ux.md and the TASK-24 through TASK-28 redesign as the baseline, not superseded sections. CLI-first delivery must not imply a standalone future power UI.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An explicit CLI operation targets one unambiguously resolved external monitor for DDC VCP 0xD6 power control, including off and best-effort on where the transport remains available. Supported named values and their MCCS semantics are documented from authoritative evidence; arbitrary power-value cycling is not exposed.
- [ ] #2 Power-down requires explicit acknowledgment that software wake may fail, the physical power button may not suffice, and unplugging monitor power may be required. No claim guarantees harmlessness, physical recovery, topology removal or automatic restoration. Startup, wake, blackout and hide/show do not implicitly issue power commands.
- [ ] #3 Identity and controller ambiguity refuse before writes. Each explicit operation issues at most one Set VCP, with bounded verification and no automatic retry or alternate-value fallback. Results distinguish already-reported state, matching readback, unverified state after transport loss, and errors; command delivery or matching readback is not proof of visible panel state. An unreachable wake target produces manual recovery guidance without guessing IDs.
- [ ] #4 Fake-transport and CLI tests cover value encoding, consent, identity refusal, unsupported features, unavailable wake transport, failures before and after writing, readback mismatch and no automatic writes. Relevant tests and warnings-as-errors builds pass without hardware writes.
- [ ] #5 Usage and feasibility docs distinguish planned/implemented power support from qualified hardware. A supervised qualification protocol records exact monitor/firmware/connection/host, separately approved commands, observed power behavior, DDC wake and physical recovery only when actually tested. Live trials require a present user, accessible physical power and another usable display; offline delivery never implies hardware qualification.
- [ ] #6 Update docs/display-hide-ux.md in place with the planned DDC power integration into existing per-display Hide styles and Hide/Show actions, display tiles, inline results and recovery surfaces; no new top-level Power buttons, parallel menu/settings page or competing recovery flow. Clearly label planned app behavior versus shipped CLI behavior. Reconcile with the current redesign amendment and any TASK-28 rewrite rather than creating a second UX contract.
- [ ] #7 The integrated design documents availability and unsupported states, power-specific consent within existing configuration, interaction with the General Experimental features gate, and best-effort Show versus manual recovery when DDC is unreachable. Existing mirror consent is not power consent; changing styles or disabling the experimental gate must not strand recovery. Explain that power-off alone need not remove the macOS desktop, preserve existing default styles and automation behavior, and do not silently combine power with input switching or topology changes. Update usage/feasibility cross-references and reconcile blanket power exclusions only within this explicit opt-in scope.
<!-- AC:END -->
