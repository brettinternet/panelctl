---
id: TASK-29
title: Add opt-in DDC monitor power control with honest manual recovery
status: Done
assignee: []
created_date: '2026-10-05 16:36'
updated_date: '2026-10-05 21:01'
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
  - docs/display-disable.md
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
- [x] #1 An explicit CLI operation targets one unambiguously resolved external monitor for DDC VCP 0xD6 power control, including off and best-effort on where the transport remains available. Supported named values and their MCCS semantics are documented from authoritative evidence; arbitrary power-value cycling is not exposed.
- [x] #2 Power-down requires explicit acknowledgment that software wake may fail, the physical power button may not suffice, and unplugging monitor power may be required. No claim guarantees harmlessness, physical recovery, topology removal or automatic restoration. Startup, wake, blackout and hide/show do not implicitly issue power commands.
- [x] #3 Identity and controller ambiguity refuse before writes. Each explicit operation issues at most one Set VCP, with bounded verification and no automatic retry or alternate-value fallback. Results distinguish already-reported state, matching readback, unverified state after transport loss, and errors; command delivery or matching readback is not proof of visible panel state. An unreachable wake target produces manual recovery guidance without guessing IDs.
- [x] #4 Fake-transport and CLI tests cover value encoding, consent, identity refusal, unsupported features, unavailable wake transport, failures before and after writing, readback mismatch and no automatic writes. Relevant tests and warnings-as-errors builds pass without hardware writes.
- [x] #5 Usage and feasibility docs distinguish planned/implemented power support from qualified hardware. A supervised qualification protocol records exact monitor/firmware/connection/host, separately approved commands, observed power behavior, DDC wake and physical recovery only when actually tested. Live trials require a present user, accessible physical power and another usable display; offline delivery never implies hardware qualification.
- [x] #6 Update docs/display-hide-ux.md in place with the planned DDC power integration into existing per-display Hide styles and Hide/Show actions, display tiles, inline results and recovery surfaces; no new top-level Power buttons, parallel menu/settings page or competing recovery flow. Clearly label planned app behavior versus shipped CLI behavior. Reconcile with the current redesign amendment and any TASK-28 rewrite rather than creating a second UX contract.
- [x] #7 The integrated design documents availability and unsupported states, power-specific consent within existing configuration, interaction with the General Experimental features gate, and best-effort Show versus manual recovery when DDC is unreachable. Existing mirror consent is not power consent; changing styles or disabling the experimental gate must not strand recovery. Explain that power-off alone need not remove the macOS desktop, preserve existing default styles and automation behavior, and do not silently combine power with input switching or topology changes. Update usage/feasibility cross-references and reconcile blanket power exclusions only within this explicit opt-in scope.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reuse DDC framing/channel and strict external-display resolution; expose only MCCS on (0x01) and off (0x04), with power-specific consent before any I/O and at most one write plus one readback.
2. Add CLI dispatch/help and fake-backed tests for parsing, consent, ambiguous identity/controller, pre/post-write failures, no-op and bounded readback.
3. Document authoritative MCCS semantics, manual recovery and separately approved qualification; amend the existing Hide/Show UX contract for planned app integration only.
4. Run offline suite and warnings-as-errors builds; one independent safety review, fix concrete findings, commit and merge to main, finalize task and clean owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Claimed for offline implementation only. Worktree /Users/brett/dev/me/panelctl/.worktrees/task-29-ddc-power, branch task-29-ddc-power, created from da7da6b49a6857747f7f9f9d86de9aa6fbc48c90. Ownership receipt .git/worktrees/task-29-ddc-power/agent-creation.json records session 01a10dd5-a50a-7226-b088-b7be5e4e7919. Existing recovery-enable worktree is unrelated and will be preserved. VESA MCCS 2.2a Table 8-9 p70 verified from https://files.lunar.fyi/mccs.pdf: on=01, DPM/DPMS off=04; 05 is separate power-button-equivalent and will not be exposed. No live DDC reads/writes authorized or planned.

Implemented CLI-only ddc-power with named on/off, API+parser consent before opening transport, one pre-read/optional Set VCP/readback, honest reported/alreadyReported/matchingReadback/unverified outcomes and manual guidance on refusal/failure. Shared DDC resolution now refuses duplicate IDs/UUIDs and invalid/missing UUIDs. Added 11 power tests and amended current app UX contract (planned only). Fresh offline validation: focused DDCPowerTests/DDCTests/CLIParserTests 46 tests passed; full suite 383 tests, 4 opt-in skips, zero failures; panelctl and PanelCtlApp warnings-as-errors builds passed; release-version checks and diff whitespace checks passed. CLI help and missing-consent exit=2 smoke checks passed without opening DDC. No hardware power reads/writes performed. Independent read-only safety review b07b83e7-248a-4bca-916c-e90c75789e9e pending. Next: consume review, address concrete findings, integrate authorized commit and finalize.

Delivered a9037f967e70a3ffb21b37c9fc421b9e8fd8d8eb (Add opt-in DDC monitor power control), fast-forward merged to main. Independent read-only reviewer b07b83e7-248a-4bca-916c-e90c75789e9e completed: no validated findings, Merge verdict OK with notes. Confirmed consent, one-shot execution, identity/controller refusal, outcome honesty, absence of implicit power callers and planned-vs-shipped docs. AC1–4 evidenced by DDCPowerTests (11), existing DDC/parser tests (46 focused total), full 383-test offline suite (4 intentional skips), both warnings-as-errors builds, release-version script and actual CLI parse/help smoke checks. AC5–7 documented in docs/ddc-power.md and the existing display-hide-ux.md contract, with usage/feasibility/exclusion cross-references; independent review confirmed boundaries and protocol. Residual limits: no monitor power-qualified, no application wall-clock deadline for underlying I2C, firmware behavior and physical recovery uncertain. These are documented, not hidden blockers to offline delivery. No live power read/write performed. Worktrunk removed owned task-29-ddc-power worktree and branch after receipt/list verification; exact workspace w26 had only idle zsh and disappeared after post-remove hook. Existing recovery-enable worktree retained untouched (not session-owned). No push. No remaining implementation step; optional future hardware qualification requires fresh per-command scoped human approval under docs/ddc-power.md.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented and merged a9037f9: CLI-only explicit DDC on/off with power-risk consent, strict identity, one-write/no-retry outcomes and manual recovery guidance. Added fake-backed tests and current-contract planned app UX/qualification docs. Verified 383 offline tests (4 skips), both warnings-as-errors builds, release-version checks and independent safety review with no findings. Worktree/branch/workspace cleaned; no hardware qualification or power commands. Claim released.
<!-- SECTION:FINAL_SUMMARY:END -->
