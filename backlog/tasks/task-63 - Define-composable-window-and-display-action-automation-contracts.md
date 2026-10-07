---
id: TASK-63
title: Record window-relocation design decisions before implementation
status: Done
assignee: []
created_date: '2026-10-07 22:44'
updated_date: '2026-10-07 23:55'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/DisplayActions.swift
  - Sources/PanelCtlApp/ProtectionPreferences.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlCore/AppControlDisplayStatus.swift
  - backlog/tasks/task-62 - Skip-safely-unavailable-display-Action-steps.md
  - docs/window-relocation.md
type: task
ordinal: 52010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Window relocation must stay separate from blackout: users black out displays without moving windows, and optionally keep windows off a blacked-out display. Current Actions have display-only steps whose identity derives from the target UUID and which forbid repeated displays; Automation rules (ProtectionRule) are protection-specific and compile to blackout-helper CLI arguments, so they are not the home for window enforcement. PanelCtl requests no TCC permission today; Accessibility is new. Settle the few decisions TASK-64/65 share in a short docs/window-relocation.md, not a generic workflow engine. Per-effect edge-case behavior belongs in TASK-64/65 acceptance criteria, not here.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Step model: Move windows is a new DisplayActionEffect with a typed payload (destination Automatic or a DisplayIdentityReference) following the reviewedRemoval pattern. Specify DisplayActionSet versioning/migration, rejection of unknown effects without losing other saved Actions, and step identity no longer derived from target UUID alone. A display may appear once per effect class (Hide/Show vs. Move), so Hide + Move on one display is valid. Existing Actions, UUIDs, CLI and alignedStepResults behavior are unchanged.
- [x] #2 Execution principal: all Accessibility calls run in the app process, never in the blackout helper or standalone CLI; `panelctl app run-action` executes through the app. AX work runs off the main thread with a per-app messaging timeout so a hung app cannot stall UI, blackout or app control.
- [x] #3 Window enumeration and attribution use public APIs only (per regular running app kAXWindowsAttribute; no _AXUIElementGetWindow or SkyLight). A window belongs to the display holding the largest share of its frame. Document the coordinate space and whether the permission-free CGWindowList sample gates AX work.
- [x] #4 Result shape: extend AppControlActionStepResult with moved/skipped/failed counts and reason codes (no window titles). Map outcomes (nothing to move, partial, permission missing, no destination) onto existing outcomes and TASK-62 skip/refusal semantics. Moves are never rolled back.
- [x] #5 Keep-off ownership: an opt-in per-display option in DisplayHideConfiguration, enforced by one app-owned controller per display while that display is observed blacked out by any owner (manual Hide, Action or Automation rule). Not an Automation rule; Automation snooze/disable affect it only by ending blackout. Specify how the app observes helper-owned blackout state, the reconciliation cadence and that its moves are not user activity for idle or empty-display detection.
- [x] #6 List the fake seams (window source, window mover, permission, clock) and the test matrix TASK-64/65 use, and name what another window effect would add (effect case, payload, executor, reason codes). Explicitly exclude new triggers, scripting and plugins.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Inspect current Action persistence/results, helper membership reporting and empty-display policy. 2. Obtain approval for the shared design choices, then document the bounded TASK-64/65 contract in docs/window-relocation.md. 3. Review all six criteria against the document and repository evidence, validate documentation, record delivery and commit on main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User approved the shared design direction in-session: v3 storage and independent step UUIDs, unsupported Actions preserved but not executable, app-only AX workers with 250 ms per-element timeout, conservative CG visibility gate, one-second keep-off reconciliation/backoff and partial-stop/no-rollback semantics. Drafted docs/window-relocation.md. Documentation-only validation: local link and section assertions passed; git diff --check clean. Independent criterion/safety verification is pending; no native UI, window movement or hardware writes performed.

Delivered design in commit b92a979 (Document window relocation contract) on main. Independent verifier completed one criterion/safety review: PASS for all six criteria, no findings. Evidence: section 1 covers AC1; section 2 AC2/3; section 3 AC4; section 4 AC5; section 5 AC6. Local-link/section assertions and staged git diff --check passed, including the new document. No executable source changed, so Swift tests and LSP checks were not applicable. No native interaction or hardware writes. No remaining TASK-63 blocker; implementation resumes under TASK-64 after TASK-66 signing prerequisite, and TASK-65 after TASK-64. No additional task started.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Recorded the approved window-relocation contract in docs/window-relocation.md: migration/composition, app-only public AX execution, honest results, keep-off ownership and fake-test matrix. Independent verification passed all six design criteria with no findings; documentation checks passed. Design committed as b92a979 on main. Implementation and native validation remain separate tasks.
<!-- SECTION:FINAL_SUMMARY:END -->
