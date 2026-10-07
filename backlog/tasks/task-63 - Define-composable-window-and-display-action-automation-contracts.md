---
id: TASK-63
title: Record window-relocation design decisions before implementation
status: To Do
assignee: []
created_date: '2026-10-07 22:44'
updated_date: '2026-10-07 22:52'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/DisplayActions.swift
  - Sources/PanelCtlApp/ProtectionPreferences.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlCore/AppControlDisplayStatus.swift
  - backlog/tasks/task-62 - Skip-safely-unavailable-display-Action-steps.md
type: task
ordinal: 52010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Window relocation must stay separate from blackout: users black out displays without moving windows, and optionally keep windows off a blacked-out display. Current Actions have display-only steps whose identity derives from the target UUID and which forbid repeated displays; Automation rules (ProtectionRule) are protection-specific and compile to blackout-helper CLI arguments, so they are not the home for window enforcement. PanelCtl requests no TCC permission today; Accessibility is new. Settle the few decisions TASK-64/65 share in a short docs/window-relocation.md, not a generic workflow engine. Per-effect edge-case behavior belongs in TASK-64/65 acceptance criteria, not here.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Step model: Move windows is a new DisplayActionEffect with a typed payload (destination Automatic or a DisplayIdentityReference) following the reviewedRemoval pattern. Specify DisplayActionSet versioning/migration, rejection of unknown effects without losing other saved Actions, and step identity no longer derived from target UUID alone. A display may appear once per effect class (Hide/Show vs. Move), so Hide + Move on one display is valid. Existing Actions, UUIDs, CLI and alignedStepResults behavior are unchanged.
- [ ] #2 Execution principal: all Accessibility calls run in the app process, never in the blackout helper or standalone CLI; `panelctl app run-action` executes through the app. AX work runs off the main thread with a per-app messaging timeout so a hung app cannot stall UI, blackout or app control.
- [ ] #3 Window enumeration and attribution use public APIs only (per regular running app kAXWindowsAttribute; no _AXUIElementGetWindow or SkyLight). A window belongs to the display holding the largest share of its frame. Document the coordinate space and whether the permission-free CGWindowList sample gates AX work.
- [ ] #4 Result shape: extend AppControlActionStepResult with moved/skipped/failed counts and reason codes (no window titles). Map outcomes (nothing to move, partial, permission missing, no destination) onto existing outcomes and TASK-62 skip/refusal semantics. Moves are never rolled back.
- [ ] #5 Keep-off ownership: an opt-in per-display option in DisplayHideConfiguration, enforced by one app-owned controller per display while that display is observed blacked out by any owner (manual Hide, Action or Automation rule). Not an Automation rule; Automation snooze/disable affect it only by ending blackout. Specify how the app observes helper-owned blackout state, the reconciliation cadence and that its moves are not user activity for idle or empty-display detection.
- [ ] #6 List the fake seams (window source, window mover, permission, clock) and the test matrix TASK-64/65 use, and name what another window effect would add (effect case, payload, executor, reason codes). Explicitly exclude new triggers, scripting and plugins.
<!-- AC:END -->
