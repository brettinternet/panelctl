---
id: TASK-75
title: Fix keep-windows-off Settings CI interactions for v0.7.0
status: In Progress
assignee:
  - '@agent'
created_date: '2026-10-08 20:06'
updated_date: '2026-10-08 20:12'
labels: []
dependencies: []
type: bug
ordinal: 63010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Main CI reports seven failures in two keep-windows-off Settings tests. Release v0.7.0 is blocked until native control interactions reliably exercise the existing bindings on the dedicated runner; no local desktop interaction or hardware writes are authorized.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Both affected Settings tests pass in dedicated-runner CI without weakening their behavior assertions
- [ ] #2 Main and v0.7.0 release CI pass and signed universal assets are published
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Use existing NSSwitch.performClick test convention, wait for selected-display rendering, validate fake-backed tests locally, then push main and tag v0.7.0 after main CI succeeds.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Main CI 37837084104 proves hidden-display pause/resume now passes with performClick and rendering waits. Remaining unhidden-display test clicks the prior display control before SwiftUI selection updates; select switches by their existing display-specific accessibility label rather than count.
<!-- SECTION:NOTES:END -->
