---
id: TASK-35
title: Manage named protection rules in the Automations tab
status: To Do
assignee: []
created_date: '2026-10-05 22:29'
updated_date: '2026-10-05 22:42'
labels:
  - app
  - automation
  - ui
dependencies:
  - TASK-34
references:
  - Sources/PanelCtlApp/AutomationSettingsView.swift
  - Sources/PanelCtlApp/SettingsWindowController.swift
  - Sources/PanelCtlApp/AppDelegate.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Tests/PanelCtlAppTests/SettingsWindowTests.swift
documentation:
  - docs/display-hide-ux.md
  - docs/usage.md
priority: medium
type: feature
ordinal: 25010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The current Automation form represents one global configuration. Users need to see which protection is configured for each display and why a rule is active or blocked without learning a workflow-builder UI or cluttering the menu. Build the user-facing multiple-rule experience on the coordinated runtime and validator from TASK-34 using plain native Settings patterns: a rule list with switches and a sheet editor that saves explicitly. The plan fixes layout, wording, defaults and explicit exclusions so the result stays small. Keep display hardware setup and recovery in Displays, and keep General preferences separate. Scheduled triggers, arbitrary action chains and unattended topology/input/power/private-disconnect actions are out of scope. Native UI fixture inspection and offline validation are required; no live hardware writes are authorized.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Settings labels the tab Automations (Cmd-2 unchanged). It keeps the master Automation switch with the aggregate status and existing cleanup retry, shows Resume while paused, and lists rules with name, an effect/target/afterward summary, a per-rule switch, an Edit button and truthful status (off, watching, active, paused, waiting or blocked with reason). The migrated rule appears without enabling or changing anything. The global display sleep timer setting appears only when a rule ends with Sleep all displays.
- [ ] #2 Add Rule and Edit open a sheet with Name, On, When, Displays, Action, Afterward, Pause while and Advanced sections built from the existing controls; changes apply only on Save, Cancel discards, and Return or Escape map to Save or Cancel. Validation comes from the TASK-34 validator: blocking problems (empty or duplicate name, conflicts naming the other rule, missing all-display limit) disable Save while the rule is on, while waiting conditions show a note. New rules default to no displays and Stay black until activity. Delete asks for confirmation.
- [ ] #3 Summaries name the actual effect (Black out or Dim) rather than Hide. Missing saved targets remain visible with reasons and stable target identities survive renaming. Turning on a conflicting or invalid rule from the list is refused inline with the reason, without an alert. Blocked causes that live in Displays offer direct navigation there; Automations adds no Displays setup or recovery controls.
- [ ] #4 Pause, Resume, the master switch, per-rule switches and Restore have stated scope: Pause, Resume and Restore stay global in the menu and app commands, and the menu gains no rule list. Black Out Now is titled for the enabled rules’ effects and is disabled with a reason when no rule is on. Turning off or deleting a running rule verifies its automation-owned cleanup without showing Hides or switching inputs; cleanup failure remains visible and retryable even with every rule off or deleted.
- [ ] #5 Native keyboard and accessibility navigation covers the rule list, row switches (labelled per rule), editor, validation and recovery navigation. Rendered fixtures at 680 and 440 pt widths are inspected for migrated single-rule, multiple-rule, active, missing-target, conflicting-rule, cleanup-failure and editor states; tests cover editing, cancel, persistence, refusals and summaries with fake services.
- [ ] #6 Full offline tests and warnings-as-errors builds pass. Update the existing UX contract, usage documentation and add an Automations screenshot rendered from fixtures, distinguishing shipped protection rules from deferred manual actions and unavailable unattended hardware actions.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
0. Before claiming: confirm TASK-34 is Done and read its final contract (validation API, per-rule status, coordinator). Use that model-side validation; the view must not reimplement rules. Re-check TASK-32 state for recovery/overlay wording.

## Decisions (settled; do not reopen without the user)

- Tab: rename `SettingsTab.automation` title to **Automations** (keep enum case, Cmd-2, `timer` symbol). No new tabs.
- Native macOS Settings patterns only: grouped `Form`, rows with switches, `Edit…` buttons and a **sheet** editor with Cancel/Save. No master-detail split, no inline expanding rows, no drag reorder, no colors/icons per rule, no onboarding.
- Edits apply only on **Save** (unlike today’s live form), so a half-edited rule never reaches the running helper and conflicts are explained before enablement.
- Restore stays global (menu and `app restore`); Pause stays global and menu-only. No per-rule Restore/Pause/Black Out Now buttons.
- No rule list in the menu bar menu.

## Automations tab layout

```
[existing recovery banner, if any]
Section (no header)
  Automation                                   [switch]   ← master; subtitle = aggregate statusSummary
  ⚠ problem text + [Retry Automation Cleanup]             ← existing, unchanged
  "Paused until 3:00 PM"                     [Resume]     ← only while snoozed
Section "Rules"
  Display protection                       [Edit…] [switch]
  Black out after 5 min · DELL AW3423DW · sleep all displays after 30 min
  Watching for inactivity
  Desk dimming                             [Edit…] [switch]
  Dim after 10 min · DELL S2721DGF · until activity
  ⚠ Can’t turn on: DELL S2721DGF is also in “Display protection”.  
  [Add Rule…]
  footer: Rules run automatically. A display can be in only one rule that’s on.
Section "Display sleep"   ← only when some rule ends with Sleep all displays
  Use PanelCtl’s display sleep timer           [switch]   ← existing text, global setting
(TASK-36 later adds an "Actions" section below Rules)
```

Row content:
- Title = name. Summary (secondary, ≤2 lines, tail-truncated): `‹Black out|Dim› after ‹idle›[ or when empty] · ‹targets› · ‹afterward›`. Targets: "All displays", one or two names joined with ", ", else "‹first› and N others"; missing saved targets append " (unavailable)". Afterward: "until activity" | "restore after 30 min" | "sleep all displays after 30 min".
- Status line (secondary text, no dots/colors for normal states): "Off" for a rule switched off, otherwise reuse `ProtectionRuntimeState.label` text ("Automation off", "Automation paused", "Watching for inactivity", "Blackout active"/"Dimming active", …), shortening only the playback state to "Paused for media or camera"; waiting for displays reads "Waiting: ‹display› unavailable". Blocked/needs-attention states use the existing orange `exclamationmark.triangle.fill` + selectable reason. When the cause lives in Displays (recovery, removed display, cleanup tied to hide), add an inline `Review in Displays…` button using `navigation.showDisplays(selecting:)`. No second recovery workflow.
- Row switch: `labelsHidden`, accessibility label "Turn on ‹name›". Turning on a conflicting/invalid rule is refused: switch stays off, the row status shows "Can’t turn on: ‹reason›" until the next change. No alert.
- No rules: section shows "No rules." and `Add Rule…`; master can still be on (status "No rules on").

## Rule editor sheet

```
New Rule / Edit Rule                                 (sheet, ~520 pt wide, scrollable Form)
  Name   [Display protection        ]   ← focused for new rules
  On     [switch]
When
  Start after                  [5 minutes ▾]
  Also black out empty displays [switch]    (existing subtitle)
Displays
  All displays [switch]        footer: Includes displays you connect later.
  ‹display› [switch]  subtitle "3440 × 1440 · Main" or "Also in “Desk dimming”"
  Unavailable display rows (existing behavior: visible with reason; switch off to forget)
Action
  Action [Black out | Dim]; Dim → Dark overlay, Darkness (existing)
Afterward
  Afterward picker + Restore/Sleep after; Keep displays black during activity (existing)
  footer when Sleep: Sleeps every display, including displays in other rules.
Pause while
  An app keeps the display awake / A camera is in use (existing)
Advanced
  Lower hardware brightness + Brightness (existing text)
───────────────────────────────────────────────────────────────
[Delete Rule…]      ⚠ ‹first blocking message›        [Cancel] [Save]
```

- Section names map to the AC groups: When, Displays, Action, Afterward (= end behavior), Pause while (= exceptions). Reuse existing control text and the existing `AutomationSettingsView` helpers (move them into the editor; don’t fork copies).
- Defaults for a new rule: name "New Rule" (dedupe "New Rule 2"…), On, no displays selected, Afterward = Stay black until activity (local; a new rule must not silently sleep every display), other values = current defaults.
- Validation is live from TASK-34’s validator. Save is disabled only for blocking errors when On (empty/duplicate name always blocks); waiting conditions (display unavailable/hidden) show as a note and allow Save. A rule switched Off may be saved while overlapping another rule.
- Delete Rule… (edit only) → alert "Delete “‹name›”?" message "Any blackout or dimming from this rule ends. Hidden displays stay hidden." buttons Delete (destructive) / Cancel. A cleanup failure after delete stays in the top section with Retry Automation Cleanup.
- Keyboard: Return = Save (default), Escape = Cancel; standard Tab order.
- Rename never changes the rule ID or target UUIDs.

## Menu

Structure unchanged. Status line = aggregate summary. Black Out Now title: all enabled rules Black out → "Black Out Now"; all Dim → "Dim Now"; mixed → "Black Out and Dim Now". With master on and no rules on, the item is disabled with tooltip "Turn on a rule in Settings → Automations." Restore tooltip: "Ends blackout or dimming from every rule. Hidden displays stay hidden."

## Steps

1. Rename tab; split `AutomationSettingsView` into the tab list and `ProtectionRuleEditor` sheet backed by a draft `ProtectionRule` copy; Save commits through one AppModel method that validates and persists.
2. Row summary/status formatting as pure functions on the model (unit-tested), not in views.
3. Menu title/tooltip changes in `AppDelegate`.
4. Tests with fake services: add/edit/rename/delete persistence, Cancel discards, conflicting enable refused, Save disabled reasons, delete of active rule triggers verified cleanup, cleanup failure visible with all rules deleted/disabled, migrated rule unchanged, keyboard: Return/Escape in sheet, switch accessibility labels.
5. Fixtures (`SettingsWindowTests`, `PANELCTL_SETTINGS_FIXTURE_OUTPUT`) at 680 and 440 pt widths: migrated single rule, multiple rules watching/active, missing target, conflicting rule, cleanup failure, editor new/conflict. Inspect every PNG for truncation, clipping and orphaned controls.
6. Docs: `docs/display-hide-ux.md` (tab name, rules, shipped vs deferred manual actions vs unavailable unattended hardware actions, keyboard section), `docs/usage.md` (three tabs text, add an Automations screenshot rendered from fixtures with the fake-fixture caption). Full suite, warnings-as-errors debug+release builds, `git diff --check`.

## Do not add

Rule duplication, import/export, reordering, per-rule colors/icons, schedules, trigger pickers, a menu rule list, per-rule Restore/Pause, completion dialogs, or any Displays setup/recovery controls inside Automations.
<!-- SECTION:PLAN:END -->
