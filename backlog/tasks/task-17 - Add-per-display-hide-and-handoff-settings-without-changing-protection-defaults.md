---
id: TASK-17
title: Add hide and show for one configured display to the app
status: To Do
assignee: []
created_date: '2026-10-04 17:13'
updated_date: '2026-10-04 21:16'
labels:
  - display-hide
  - app
dependencies:
  - TASK-16
  - TASK-13
references:
  - Sources/PanelCtlApp/SettingsView.swift
  - Sources/PanelCtlApp/AppDelegate.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/ProtectionPreferences.swift
  - Sources/PanelCtlCore/DisplayMirroring.swift
  - Sources/PanelCtlCore/DisplayHandoff.swift
  - docs/display-mirroring.md
priority: medium
type: feature
ordinal: 7010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hiding an external desktop is CLI-only today, requiring UUIDs, consent flags and a remembered journal path. Deliver the first usable app slice of the approved TASK-16 contract: configure a display once (target and explicit mirror source), hide and show it from the approved surfaces, and recover from the journal, with no DDC. This replaces the earlier split between a settings-only task and a controls task, because saved configuration without an action is unverifiable dead UI. Reuse MirrorController/HandoffController, their locks and the shared recovery journal; do not build a parallel recovery path. Protection selection and defaults stay unchanged. Protection is paused while hidden, and blackout already refuses mirror-set displays, so the OLED mirror source (AW3423DW in the recorded setup) is unprotected for the whole hide; the confirmation must say so (contract amendment 2026-10-04). Re-enabling overlay blackout on the source is TASK-21, not this task. Offline implementation and fake/no-write validation only. Native UI checks use fixture state, not a live app with real protection active. After offline acceptance, one supervised app Hide/Show round trip on the S2721DGF to AW3423DW tuple is recommended, because protection quiesce, overlay teardown and app recovery paths are not covered by the CLI trials. It is optional, not an acceptance gate, and needs fresh scoped approval for the Hide and, separately, for the Show. Untested behavior is recorded honestly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Per-display hide configuration lives in the approved place in existing navigation, separate from protection selection: target identity and an explicit eligible mirror source. Nothing is guessed; saving, editing, loading or migrating settings performs no topology write, existing installations keep their protection behavior and launch at login never implies hide.
- [x] #2 Users can hide and show one configured eligible non-main external display from the approved surfaces, seeing target and source before the approved confirmation. Backend eligibility, locks and journal-before-write guarantees are reused; busy actions cannot be submitted twice or race CLI operations.
- [x] #3 Show uses the journaled target and captured topology, not the current selection. Identity refusal, restoration mismatch and partial failure keep the journal and show an actionable next step without reporting success; journals created by panelctl mirror/away are recognized.
- [x] #4 Observed state is rendered separately from saved configuration and protection status. Journal-owned hidden or unavailable targets keep a show/recovery action that works with Settings closed, after relaunch and with the menu icon hidden; missing displays keep intelligible configuration but never bind to a different display.
- [x] #5 The approved coexistence and lifecycle behavior for protection, Restore, snooze, quit/relaunch, sleep/wake and hotplug is implemented. The app does not fight system restoration, silently re-hide, clear unresolved journals or escalate to global reset/logout/reboot.
- [ ] #6 Tests cover legacy preference migration, per-display independence, stale/missing targets, duplicate requests, backend refusal, interruption and partial failure with fake writers. Native menu and Settings flows are verified with synthetic states for layout, keyboard navigation and accessible labels; relevant tests and warnings-as-errors builds pass.
- [x] #7 The Hide confirmation states that while hidden PanelCtl cannot black out the mirror source or any other display, so an OLED source stays lit until Show or macOS display sleep; protection status shows the same pause.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Implement the approved docs/display-hide-ux.md contract in existing app navigation with per-display preferences, shared backend/journal coordination and conservative protection suspension. 2. Add fake-writer/state/lifecycle tests and native fixture verification without real protection or display writes; run focused tests and warnings-as-errors builds. 3. Perform one independent safety-focused review of identity, journal retention, protection quiescence and consent; fix concrete findings and rerun affected checks. 4. Refresh provider/repository state, record evidence and any unverified UI criteria, commit on main and release claim. No live hardware trial, push or PR.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Resumed on main by the sole backlog agent at user request. Preserving the existing claim and approved plan. Implementation delegated to one executor, followed by one read-only independent safety review; parent will validate and commit. Offline fake/no-write operations only; no live display writes authorized.

Current session confirmed no active subagent fleet and no source changes; resuming the existing claim with user authorization. One executor will implement the approved contract, then one independent safety review. Parent owns final verification, backlog updates and commits on main.

Resumed by the current sole backlog agent on main with explicit user authorization to take over in-progress work and commit. Existing changes are task metadata only. Continuing the recorded offline implementation and one independent review plan; no hardware writes.

Current turn resumes TASK-17 on main with explicit sole-agent handoff. Delegating implementation for context isolation and one independent review focused on journal identity, quiescence, consent and lifecycle safety. Parent retains provider state and commit ownership; fake/no-write validation only.

Resuming the existing TASK-17 claim on main under the explicit sole-agent handoff. Source tree has no implementation changes; preserving prior task metadata. Current run will implement offline, obtain one independent safety review, validate and commit; no live display operations.

Current session takes over TASK-17 under the explicit sole-agent handoff. One implementation writer followed by one independent safety review; parent owns backlog and commit. Preserve existing metadata and use offline/fake-only validation.

User approved consolidating concurrent TASK-17 runs in this session. Interrupted nine older executor runs after verifying their task/cwd; preserved all source edits. Current executor made no edits before detecting collision. Review was stopped without findings because implementation was incomplete. Next: reconcile preserved implementation with one writer, run offline checks, then resume safety review and commit.

Delivery: implementation committed on main as 312d191 (Add guarded app display hide and recovery). User explicitly approved committing while leaving the foreground GUI acceptance gate open. Claim released; To Do is resumable but NOT dependency-ready completion. AC6 remains unchecked. Parent reran swift test --disable-sandbox -Xswiftc -warnings-as-errors: 202 core tests (2 existing optional skips), 73 app tests (2 foreground fixture skips), zero failures; both PanelCtlApp and panelctl warnings-as-errors builds and git diff --check passed. LSP diagnostics were unknown, not clean. One independent safety review found four concrete defects; fixed retained helper cleanup failure, locked confirmed identity revalidation, actual helper rearm, and unknown input history for imported journals, with targeted regression coverage. Fixed a demonstrated 440pt picker overflow. Native app-local Arrow Down/Return menu selection, Settings identity/accessibility controls, confirmation gating and long-content fixtures passed. Opt-in foreground run authorized by user still skipped Escape and success/error focus because XCTest did not become frontmost; no keys were sent outside the fixture. Background process-targeted and app-local modal probes had already timed out. Next resumable step: arrange foreground GUI XCTest host and rerun the two native checks with PANELCTL_RUN_NATIVE_DISPLAY_KEYBOARD_FIXTURES=1; grant Accessibility only if runtime preflight reports denied access. See docs/development.md for command and unverified Xcode route; a dedicated GUI test-host target may be needed if package XCTest cannot activate. No live display writes, DDC, private setters or human VoiceOver qualification. No worktree was created and nothing pushed.
<!-- SECTION:NOTES:END -->
