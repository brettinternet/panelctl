---
id: TASK-28
title: Update docs and screenshot for the redesigned app
status: To Do
assignee: []
created_date: '2026-10-05 06:07'
labels:
  - docs
  - app
  - display-hide
dependencies:
  - TASK-24
  - TASK-25
  - TASK-26
  - TASK-27
references:
  - docs/display-hide-ux.md
  - docs/usage.md
  - README.md
  - docs/settings.png
priority: low
type: docs
ordinal: 18010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
docs/display-hide-ux.md describes the superseded flows: per-operation confirmations, the old Displays page layout and headless confirmation-required behavior. README and docs/usage.md show the old sidebar window and OLED wording. After the Settings redesign tasks the documentation must describe the shipped app so users and future agents are not misled.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 docs/display-hide-ux.md is rewritten as the current contract for Hide styles, the Experimental flag and consent, inline results, recovery presentation, scripting and the remaining safety boundaries, keeping still-valid coexistence and recovery rules.
- [ ] #2 README and docs/usage.md describe the Displays, Automation and General tabs, Hide styles, the Experimental flag and Stream Deck or CLI usage; docs/settings.png shows the new Settings window.
- [ ] #3 In-app Learn more links point at the updated documentation sections.
<!-- AC:END -->
