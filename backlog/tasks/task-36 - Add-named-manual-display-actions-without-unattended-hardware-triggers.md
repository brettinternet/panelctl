---
id: TASK-36
title: Add named manual display actions without unattended hardware triggers
status: To Do
assignee: []
created_date: '2026-10-05 22:30'
labels:
  - app
  - automation
  - display-hide
  - cli
dependencies:
  - TASK-35
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/AppControlServer.swift
  - Sources/PanelCtlCore/AppControl.swift
  - TASK-27
  - TASK-29
  - TASK-32
documentation:
  - docs/display-hide-ux.md
  - docs/display-handoff.md
  - docs/usage.md
priority: medium
type: feature
ordinal: 26010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Users want reusable display actions alongside protection rules, including handing a monitor to another computer, without converting safe idle protection into topology or input writes. Add deliberately invoked named actions in Automations, clearly distinguished from automatic protection. Reuse the existing Displays setup, app control and Hide/Show recovery rather than creating another hardware or recovery path. Initial scope is one exact display per action, with explicit blackout Hide, Remove from desktop with optional configured input handoff, or Show. Multi-display scenes, arbitrary sequences, schedules, idle/empty-triggered removal or input switching, DDC power and private disconnect remain deferred. TASK-31/TASK-32 remain separate work and must not be duplicated or assumed complete. Delivery is offline only; new hardware qualification requires separately scoped human approval.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Users can create, name, edit and delete single-display manual actions in Automations, with an explicit Manual shortcut trigger, Run control and a copyable bundled-CLI invocation using a stable action ID for Shortcuts or Stream Deck. No unattended trigger can select topology/input actions; startup, login, wake and reconnection never execute them.
- [ ] #2 Saved actions disclose the exact target and effect, including mirror source and optional away input for removal. Hardware setup stays in Displays. A material setup or Hide-style change invalidates the affected saved action until reviewed; it cannot silently change blackout into removal, input switching or power. Execution rechecks the reviewed configuration and identity.
- [ ] #3 Manual actions reuse the current experimental consent, eligibility, last-visible safety, automation cleanup, operation serialization and journal recovery checks. Unsupported targets, busy state and unresolved recovery report actionable refusals; no bypass, queued execution, automatic retry, fallback method or guessed identity is introduced.
- [ ] #4 Hide and Show are explicit desired-state operations: already-achieved state is a no-op without another input write. Show follows the actual outstanding Hide/recovery evidence rather than current setup, including after configuration changes or experimental features are disabled. Existing per-display Show and recovery stay available if a saved action is edited or deleted.
- [ ] #5 Activity, protection Restore and Pause All do not undo a manual Hide or switch a monitor back from another computer. Show is deliberate. Results distinguish desktop outcome, input outcome and recovery needed, and an unavailable or lost response never triggers automatic resend.
- [ ] #6 The named-action command uses the running app and existing app-control error conventions; existing per-display hide/show/toggle-hide commands remain compatible. CLI help and docs explain command copying, state inspection after uncertain results, and the distinction between deliberately invoked commands and unattended built-in triggers.
- [ ] #7 Fake-backed model, app-control, parser and UI tests cover configuration drift, stable IDs, repeated requests, contention, cleanup failure, missing targets, consent, partial input outcomes, deletion with outstanding recovery and absence of automatic hardware execution. Native UI fixtures are inspected; full offline tests and warnings-as-errors builds pass. Existing docs distinguish implemented actions from hardware-qualified combinations and retain power/private-disconnect exclusions.
<!-- AC:END -->
