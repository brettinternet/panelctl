---
id: TASK-44
title: Clarify Rules and Actions in the Automations tab
status: Done
assignee:
  - '@pi'
created_date: '2026-10-06 16:50'
updated_date: '2026-10-06 17:34'
labels:
  - app
  - automation
  - ui
  - reviewed
dependencies: []
references:
  - Sources/PanelCtlApp/AutomationSettingsView.swift
  - Sources/PanelCtlApp/DisplayActions.swift
  - Tests/PanelCtlAppTests/SettingsWindowTests.swift
documentation:
  - docs/usage.md
priority: medium
type: enhancement
ordinal: 34010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A UX review of Settings → Automations found that Rules (automatic idle blackout/dim) and Actions (named one-off commands run from Run, Shortcuts or Stream Deck) are both worth keeping but the presentation blurs them. The master Automation switch sits above both sections though it only governs rules; the rule editor labels its effect "Action", so rules appear to contain Actions; and an Action's "Black out" is really a Hide that persists until Show, unlike a rule's temporary blackout. Several descriptions read as engineering caveats rather than plain guidance, Action rows repeat status and use inconsistent warning styling, and the Action editor shows Remove-from-desktop setup guidance even when Black out is chosen. docs/automations.png predates the Actions section. Copy and layout only: no change to rule or action behavior, persistence, CLI JSON, or hardware paths. Offline fixtures only; no live display writes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The master Automation switch, cleanup failure/retry and paused/Resume rows appear inside the Rules section, so it is visibly scoped to rules; menu and status vocabulary ("Automation") is unchanged
- [x] #2 The rule editor's effect section and picker are titled Effect, matching the Action editor; no rule UI uses the word Action
- [x] #3 Action effects read Hide (black out), Hide (remove from desktop) and Show in the editor and list summaries, matching the Displays tab Hide/Show vocabulary; stored raw values are unchanged
- [x] #4 Rules footer reads "Rules run on their own when you’re idle. Each display can be in only one rule that’s on." and Actions footer reads "Run an action here, or from Shortcuts or Stream Deck. Actions never run on their own."
- [x] #5 The Action editor drops the Runs row, combines Display and Effect into one section using a native Picker aligned with other rows, shows Remove-from-desktop setup guidance only when that effect is selected, notes that mirror/input values are set in Displays, and its Command footer reads "Use in Shortcuts or Stream Deck. PanelCtl must be running."
- [x] #6 Settings fixtures and app tests are updated and pass; regenerated docs/automations.png shows Rules and Actions; docs/usage.md matches the new wording
- [x] #7 Action rows show a single plain status (Running…, Shown, Hidden, "Display setup changed. Edit to review.", or the blocker) with the same orange triangle icon style as rule warnings; no ⚠ character or Unavailable: prefix; a successful run, or a result that repeats the status, adds no extra result line
- [x] #8 Selecting Hide (remove from desktop) without Displays setup is allowed in the draft but Save stays blocked with the setup reason; validation and run-refusal conditions are unchanged (the disconnected-display refusal text is shortened to Display not connected)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Worktree .worktrees/task-44-automations-clarity (branch task-44-automations-clarity).
2. AutomationSettingsView: move master switch/cleanup/paused rows into Rules section; new footers; shared rowStatus for rule and action rows; suppress result lines that repeat status; rule editor Action→Effect.
3. Action editor: drop Runs row, merge Display+Effect into one section with native Picker (Remove selectable; Save blocked by existing validation), setup guidance and Set Up in Displays only under Remove, Displays note footer, new Command footer, no duplicate bottom validation.
4. DisplayActions.swift: effect titles Hide (black out)/Hide (remove from desktop)/Show and summaries; drop runsDescription.
5. AppModel.displayActionStatus: Shown/Hidden/Display setup changed. Edit to review./blocker without Unavailable prefix; disconnected blocker shortened to Display not connected.
6. Update tests and fixtures, regenerate docs/automations.png, update docs. Run swift test.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Worktree receipt: .git/worktrees/task-44-automations-clarity/agent-creation.json. Primary main has uncommitted TASK-43 changes (incl. AppModel.swift); merge may need to wait if files overlap.

Kept the master switch label "Automation" (moved into Rules) because menu items and status strings use that term; renaming it everywhere is out of scope. Used "Shown" not "Showing" because Displays uses "Showing…" for the transition. Validation: full swift test --disable-sandbox passed after rebasing onto 84f409d (Core 282 tests, App 229 tests, 0 failures). Fixture PNGs (PANELCTL_SETTINGS_FIXTURE_OUTPUT) for actions list 680/440, action editor first-use/remove/remove-setup/remove-disabled and rule editor were inspected; testDefaultDisplayActionEditorShowsMissingRemovalSetupAndNavigatesToSelectedDisplay clicks Set Up in Displays… under a Remove draft. docs/automations.png regenerated from actions-list-680. Merged 9342b31 to main fast-forward.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Clarified Rules versus Actions in Settings → Automations: master switch now lives in Rules, rule editor uses Effect, Action effects are Hide (black out)/Hide (remove from desktop)/Show, plain footers and statuses, consistent warning icons, no duplicate result lines, and a simpler Action editor that shows Remove setup guidance only when relevant. Behavior, persistence and refusal conditions unchanged. Verified with the full swift test suite and inspected Settings fixtures; docs and screenshot updated.
<!-- SECTION:FINAL_SUMMARY:END -->
