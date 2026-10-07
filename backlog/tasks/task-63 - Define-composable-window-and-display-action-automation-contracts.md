---
id: TASK-63
title: Define composable window and display action/automation contracts
status: To Do
assignee: []
created_date: '2026-10-07 22:44'
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
Window relocation must be separate from blackout: the user explicitly wants to black out a display without necessarily moving its windows, and optionally keep relocating windows while that display is blacked out. Future window/monitor operations should fit the same coherent action and automation concepts without each adding an unrelated lifecycle. Current saved Actions have ordered display-only steps, prohibit repeated display targets, and identify steps by target; Automation rules currently carry protection-specific settings. Establish a reviewed design contract before extending these models, not a speculative generic workflow engine. This task delivers a repository design document and concrete compatibility/behavior examples, not runtime implementation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A design document distinguishes an explicitly invoked one-shot action from a trigger/condition-driven automation with an owned running lifetime. Move windows and Hide/Show are independent effects; neither implicitly enables the other. Define how a user composes them and independently enables, disables and stops ongoing relocation.
- [ ] #2 Specify stable action, rule and step identity; typed effect-specific inputs; persistent display references rather than numeric IDs; versioned saved-data migration; and safe rejection/preservation of unsupported data. Existing Actions, protection rules, UUIDs, CLI commands and defaults retain their behavior.
- [ ] #3 Define ordered composition and effect-aware validation so Hide and Move may reference the same monitor without allowing contradictory or unsafe operations. Define preflight versus execution-time revalidation, partial results, safe skips, unexpected failure, cancellation, retry/idempotency and no implicit rollback of already-moved windows. Preserve TASK-62 identity and recovery refusals.
- [ ] #4 Define ongoing automation ownership, conflict arbitration and cleanup across overlapping rules, manual actions, snooze, disable, show/restore, quit/restart, display changes and Accessibility permission changes. Include prevention of window ping-pong, stale queued moves and feedback into empty-display blackout.
- [ ] #5 Define UI and app-control/status contracts for one-shot results versus installed/running/paused/stopped automation, actionable permission requests and partial or unsupported window outcomes; background evaluation never prompts repeatedly or steals focus.
- [ ] #6 Demonstrate the contracts with existing Hide/Show, one-shot Move windows, and Keep windows off a blacked-out display. Describe the bounded extension points another window/monitor effect would use, without implementing unused triggers, plugins, scripting, or a general workflow engine. Record a test matrix and resolved behavior choices in the design document.
<!-- AC:END -->
