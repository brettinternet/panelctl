---
id: TASK-34
title: Coordinate multiple protection rules safely
status: Done
assignee: []
created_date: '2026-10-05 22:29'
updated_date: '2026-10-06 17:34'
labels:
  - app
  - automation
  - safety
  - reviewed
dependencies: []
references:
  - Sources/PanelCtlApp/ProtectionPreferences.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - Sources/PanelCtlApp/AppModel.swift
  - TASK-33
  - TASK-32
  - Sources/PanelCtlCore/Blackout.swift
  - Sources/PanelCtlCore/BlackoutDimming.swift
  - Sources/PanelCtlCore/EmptyDisplayMonitor.swift
  - Sources/PanelCtlCore/CLIParser.swift
  - Sources/PanelCtlCore/AppControl.swift
documentation:
  - docs/display-hide-ux.md
  - docs/development.md
priority: medium
type: feature
ordinal: 24010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Different displays need different idle and empty-display protection without independent watchers fighting over covers, brightness or global sleep. Establish the runtime and persisted rule contract before exposing multiple rules in Settings; the current single Automation form keeps working against the one migrated rule until TASK-35 ships. Initial scope is existing blackout/dimming protection and existing global sleep follow-up, not schedules, arbitrary action chains, automatic Hide/Show, input switching, power or private disconnect. The plan records settled product and architecture decisions (master switch kept, one existing helper per enabled rule, conservative combined safety, per-rule brightness journals) so implementation does not reinvent them. Offline implementation and fake-backed validation only; no hardware writes are authorized. TASK-31 and TASK-32 are separate topology work, not prerequisites: preserve the topology and recovery guarantees on main without implementing those features here.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A versioned rule set persists the master Automation switch, the global display sleep timer setting and named rules with stable IDs, unique names, per-rule enablement, display selection or All displays, idle delay, optional empty-display add-on, Black out/Dim settings, hardware brightness, Afterward behavior and playback/camera exceptions. Legacy preferences migrate once into one rule named Display protection with identical effective behavior and enabled state; the legacy key is left untouched and relaunch is idempotent; first run creates the same default rule with the current initial display selection.
- [x] #2 Two enabled rules conflict when they share a display UUID (case-insensitive) or either uses All displays. Enabling or saving a conflicting rule is refused with a message naming the other rule; disabled rules may overlap; persisted conflicts block every involved rule with a reason rather than picking a winner.
- [x] #3 For each rule, displays targeted by other enabled rules count as covered for the existing all-display limit and coverage checks, alongside manual Hides and removed displays; when enabled rules together cover every usable display, each such rule must Restore or Sleep afterward or it is refused or waits with a reason. The helper rechecks at every treatment after hotplug or missing displays. Last-visible safeguards, strict identity, mirrored-source restrictions, operation locks and unresolved recovery blocks remain effective.
- [x] #4 Each enabled rule runs in its own existing blackout helper with its own brightness journal, so it restores only its own covers and saved brightness. Any change to the enabled rule set stops all helpers, verifies cleanup and relaunches with fresh countdowns. Cleanup verification and retry cover every rule journal, journals of deleted rules and the legacy journal; any unresolved cleanup blocks all rules and Remove-from-desktop Hide. Activity, timeout, Restore, Escape, disable, deletion and Pause never show a hidden display or switch inputs.
- [x] #5 Empty-display covers keep the existing grace period and never repeat writes for unchanged observations; after Restore a display is not re-covered until it has been occupied and then empty again. A rule's Sleep follow-up sleeps all displays once; other rules treat it as display sleep and need fresh input after wake. Sleep, wake, hotplug, missing displays, helper exit and relaunch are deterministic and never replay topology, input or power operations.
- [x] #6 Existing commands keep compatible aggregate semantics: enable/disable/toggle act on the master switch only; snooze/resume and Restore act on every rule; blackout-now triggers every runnable rule and refuses when no rule is on; sleep-now is unchanged. Status keeps its top-level fields as an aggregate and adds an optional per-rule rules array; single-rule status text is unchanged. No generic action follows a mutable per-display Hide style.
- [x] #7 Fake clocks, display inventories, helpers, journals and writers cover migration, simultaneous triggers with different delays, conflicts, combined all-display safety, per-rule cleanup ownership and failure, deleted-rule journals, restart-all, global sleep, lifecycle and aggregate commands, while existing single-rule tests stay green. Full offline tests and warnings-as-errors debug and release builds pass; docs describe the rule contract, conservative combined safety and exclusions without claiming new hardware qualification.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
0. Before claiming: re-read TASK-32/TASK-31 state on main. Hidden-mirror overlay, removal pause and last-visible rules may have changed; build on main’s behavior, do not re-implement topology work. Keep the current single-form Settings UI working (it edits the one migrated rule) — the multi-rule UI is TASK-35.

## Decisions (settled; do not reopen without the user)

- Vocabulary: user-facing "rule" = automatic protection; "action" (TASK-36) = manual. Never "workflow", "scene" or "automation" for a single rule. The existing **Automation** master switch and menu strings stay.
- Master switch stays: `AutomationPreferences.isEnabled` is the existing Automation on/off (menu Turn On/Off, `app enable|disable|toggle`). Each rule also has its own `isEnabled`. A rule runs only when master is on, it is on, not snoozed and not blocked.
- Global, not per-rule: master on/off, snooze (Pause Automation), and "Use PanelCtl’s display sleep timer" (`keepDisplaysAwake`; it holds a Mac-wide display-awake assertion, so a per-rule value would lie). Everything else in today’s `ProtectionPreferences` is per rule.
- A rule keeps today’s trigger shape: an inactivity delay is always required; "Also black out empty displays" is an optional add-on for the same targets. No empty-only rules, schedules or other triggers.
- Conflicts: two **enabled** rules conflict if their selections share a display UUID (case-insensitive) or either uses All displays. Disabled rules may overlap (lets users keep alternatives). No priorities, no winner. Hand-edited/corrupt persisted conflicts block every involved rule with a reason.
- Combined safety is conservative and static: for a rule, every display targeted by another enabled rule counts as already covered (exactly like a PanelCtl-hidden display) for the all-display limit and "would cover every shown display" checks. Rule of thumb shown to users: "When your rules together cover every display, each must Restore or Sleep under Afterward." The helper rechecks at every treatment against current displays (hotplug/missing displays make it dynamic). Empty-display pointer safety still uses only real Hides (siblings are not "hidden": moving the pointer always uncovers an empty-display cover).
- Runtime architecture: **one existing blackout helper process per enabled rule**, owned by a new app-side `ProtectionCoordinator` that wraps `[RuleID: ProtectionService]` and exposes the aggregate API `AppModel` already uses (`hasManagedProcess`, `canReceiveControl`, `sendControl`, `disable`, `disableForDisplayHide`, `retryCleanup`, `shutdown`, aggregate state, `unresolvedCleanupFailure`) plus per-rule state. Rejected: rewriting `BlackoutController` into a multi-rule engine (its blocking cycle loop and hardened sleep/lock/rearm handling are high regression risk) and app-level hidden priorities.
- Any change to the effective enabled rule set (save, enable, disable, delete, master, snooze, display-hide quiescence) stops **all** helpers, verifies cleanup, then relaunches with fresh countdowns. Editing only a disabled rule restarts nothing. This matches today’s "edit preferences restarts the watcher".
- Brightness journals: each rule helper uses its own luminance journal `~/Library/Application Support/PanelCtl/Automation/‹rule-uuid›/blackout-luminance.json` (own lock). Cleanup verification and Retry Automation Cleanup cover every rule journal, journals of deleted rules and the legacy default journal. Any unresolved cleanup blocks all rules and Remove-from-desktop Hide (TASK-33 behavior unchanged). A deleted rule’s directory is removed only after its journal is verified empty.
- Sleep follow-up stays global: whichever rule reaches its Sleep deadline first sleeps all displays; other helpers see display sleep (existing `screensAsleep` suspension) and require fresh input after wake. Nothing re-sleeps on wake.
- Escape on an automation cover = Restore (all rules), as today. Restore/activity/timeout/disable/delete/Pause never show a Hide or switch inputs.

## Steps

1. Persistence (`ProtectionPreferences.swift`, new `AutomationPreferences`): versioned Codable `‹version: 1, isEnabled, keepDisplaysAwake, rules: [ProtectionRule]›` under a new defaults key (e.g. `automationRules`). `ProtectionRule = ‹id: UUID, name, isEnabled, settings›`; reuse `ProtectionPreferences` field set/decoding for `settings` rather than duplicating fields. Migration: if the new key is absent, decode legacy `blackoutPreferences` (including its legacy-key fallbacks), create one rule named "Display protection" with `isEnabled = true`, master = legacy `isEnabled`, global `keepDisplaysAwake` = legacy value; write the new key; never modify or delete the legacy key. No legacy prefs: same default rule with today’s first-run initial-display selection (`didChooseDisplays` logic). Names: trimmed, non-empty, unique case-insensitively. Snooze key unchanged.
2. Validation (pure, model-side, reused later by TASK-35’s editor): `validate(rule, in: ruleSet, displays, hiddenUUIDs)` returning blocking errors (conflict naming the other rule, all-display limit with siblings counted as covered, existing range errors) vs waiting conditions (`waitsForDisplays`). Extend `commandArguments` to take sibling UUIDs. Add messages, e.g. conflict: "DELL S2721DGF is also in “Desk dimming”. Remove it from one rule, or turn one off."; combined coverage: "With “Desk dimming”, this covers every display. Choose Restore or Sleep under Afterward."
3. Helper flags (internal, hidden from help like existing `--panelctl-*`): `--panelctl-rule ‹uuid›` selects the rule-scoped luminance journal (path derived in core, never an arbitrary path); repeated `--panelctl-other-rule-display ‹uuid›` counts as covered for the all-screens safety, `coversAllDisplays` and limit checks, is never covered by this helper, and is not used for the empty-display pointer check. Parser tests for duplicates/conflicts with `--display`, mirroring `--panelctl-hidden-display` validation. Public `panelctl blackout` behavior unchanged.
4. Empty-display retrigger: after Restore, a display’s empty cover is not reapplied until that display has been observed occupied (window or pointer) and then empty again for the existing 1 s grace; repeated identical observations never re-issue window or DDC writes. Pure `EmptyDisplayPolicy` tests with a fake clock.
5. `ProtectionCoordinator` (app): owns per-rule `ProtectionService`s (each with its rule journal for `cleanupIsVerified`), launches helpers only for runnable rules, aggregates state, fans out `blackoutNow`/`restore`, waits for all on `disableForDisplayHide`/shutdown, and reports per-rule blocked reasons (conflict, invalid, waiting for displays, cleanup). While a display is removed, all rules pause except the source-only overlay for the one rule containing that source (existing TASK-21 rules; follow TASK-32 if it has landed).
6. AppModel wiring with minimal churn: replace the single `service` with the coordinator; `preferences` access becomes the rule set; keep existing single-rule status strings byte-identical when exactly one rule is enabled. Aggregate semantics:
   - `enable|disable|toggle`, menu Turn On/Off: master only; per-rule flags untouched.
   - `snooze|resume`, Pause/Resume: all rules.
   - `blackout-now`: refuse with "No rules are on. Turn one on in Settings → Automations." if none enabled (master unchanged); otherwise turn master on, cancel snooze, trigger every runnable rule; blocked rules listed in `detail`.
   - `restore`, Escape: every rule’s treatment.
   - `sleep-now`: unchanged.
   - `status`: existing top-level fields become aggregate (`enabled` = master; `state` = highest-priority rule state: failed/cleanup then blackedOut then sleeping then waitingForPlayback then waitingForDisplays then waitingForInput then waiting; `nextAction`/`secondsRemaining` = soonest across rules). Add optional `rules: [‹id, name, enabled, state, summary, detail?, displays: [uuid], nextAction?, secondsRemaining?›]`; protocol stays 1 (additive).
   - Multi-rule `statusSummary`: master off "Automation off"; snoozed unchanged; zero enabled "No rules on"; one enabled = today’s text; several = top state label + " · ‹rule name›" when one rule is in it, else " · N rules". `detail` = first blocked/waiting rule’s reason.
7. Tests (fake clocks, inventories, helpers, journals): migration (each legacy field incl. legacy dimming keys, enabled/disabled, idempotent relaunch, legacy key untouched, first run); conflicts incl. All displays, case-insensitive UUIDs, persisted conflicts; combined coverage with siblings/hidden/removed/hotplug; simultaneous triggers with different idle delays; per-rule journals and cleanup failure in one rule blocking all; deleted-rule journal retry; restart-all on rule-set change; global sleep from one rule; aggregate commands and status JSON; single-rule behavior regression (existing ProtectionPreferencesTests stay green).
8. Docs: `docs/display-hide-ux.md` (automation sections) and `docs/usage.md` (status JSON `rules`, command semantics) describe the rule contract, conservative combined safety and exclusions. No hardware qualification claims. Run `swift test --disable-sandbox`, debug+release builds of both products with `-Xswiftc -warnings-as-errors`, `scripts/test-release-version.sh`, `git diff --check`. One independent safety review focused on cleanup ownership and combined all-display safety.

## Do not add

Per-rule snooze, per-rule Restore/Black Out Now controls or commands, rule priorities/ordering semantics, a multi-rule helper engine, new trigger types, schedules, Hide/Show or input/power actions in rules, new Settings UI (TASK-35).

Execution: TASK-31 and TASK-32 are Done on main 77f32b3; preserve their multi-removal/source-overlay behavior. Implement the settled plan in protection-rules, run offline checks and one fresh-context safety review, then commit, merge main and clean up as requested.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Claimed by Pi session 01a10f0e-254f-717a-9b32-5857fc1f067d. Worktrunk created /Users/brett/dev/me/panelctl/.worktrees/protection-rules, branch protection-rules, from 77f32b3ab751a485d802d92bf7956a7d11c303a1. Ownership receipt: .git/worktrees/protection-rules/agent-creation.json; original session transcript /Users/brett/.pi/agent/sessions/--Users-brett-dev-me-panelctl--/2026-10-06T02-32-27-728Z_01a10f0e-254f-717a-9b32-5857fc1f067d.jsonl. Existing recovery-enable checkout is unrelated and will remain untouched. Offline only; no hardware writes.

Implementation child e3b8621c-7a1a-4b12-935a-953f3fd1fba5 hit its 1800000ms timeout; process terminal observed. Workflow a383bb7c failed before review. Partial implementation retained in owned protection-rules at base 77f32b3; snapshot /tmp/panelctl-task34-timeout.diff plus /tmp/panelctl-task34-timeout-ProtectionCoordinator.swift. No commit/merge or review yet. Resume same implementation child to finish tests/docs/validation, then one safety review.

Implementation completed in protection-rules without hardware writes. Worker evidence: full offline suite 270 core + 169 app tests passed; one preceding transient journal-read failure passed isolated and full rerun. Both products debug/release warnings-as-errors builds and release-version script passed. Parent diff check passed; ProtectionPreferences LSP clean, ProtectionCoordinator diagnostics unknown (bounded report timeout). Single read-only safety review running as 638011f6-a98b-4be7-b091-e62c892630a3. User requested fewer UI test runs: do not repeat full UI suite unnecessarily; use targeted non-UI checks for fixes/integration. Main advanced to 55bec52 with concurrent Settings/release and strict mirror-source changes; preserve these during integration.

Single independent safety review BLOCKED merge with nine validated findings: owned live journal locks misclassified as cleanup failure; missing sibling coverage in source overlays; fail-open journal enumeration; queued blackout survives Restore; mixed-mode Escape focus; incomplete aggregate mirror-source selection; duplicate hidden/sibling flags; missing-display refresh loop; stale global sleep marker. Parent checked underlying implementation evidence. Same worker resumed as af8b6737-d78f-49d8-a94a-c74bc79852b9 for concrete fixes/regressions only. No second general review planned. Per user request, fixes use focused non-UI tests and compiler builds, not full UI/fixture reruns. Review report: /Users/brett/.pi/agent/sessions/--Users-brett-dev-me-panelctl--/subagent-artifacts/outputs/638011f6-a98b-4be7-b091-e62c892630a3/reports/task34-safety-review.md.

Delivered implementation afba306, integrated current main in 54f3c8b and fast-forwarded main to that tested commit. All nine review findings corrected with targeted regressions; no second general review. Final parent integration run passed 91 core + 58 non-UI app/model tests; both products passed debug and release warnings-as-errors builds, release-version checks and diff check. Earlier full offline suite passed 439 tests; full UI suite intentionally not repeated after fixes per user request. AppModel LSP clean; DisplaySleep diagnostics unknown, compiler checks passed. Migration/conflicts/aggregate commands: AutomationRulesTests; cleanup, queue cancellation, focus, mirror coverage and settled refresh: AutomationSafetyTests; stale marker/global sleep: DisplaySleepTests; argument safety/rearm: parser/preferences/empty policy tests. Worktrunk removed owned protection-rules checkout and branch after receipt/list verification; unrelated recovery-enable retained untouched. No hardware writes or push. No remaining implementation blocker.

Cleanup confirmed: post-remove hook closed exact Herdr workspace w2C for the owned checkout; refreshed workspace list contains no protection-rules checkout. Claim released and TASK-34 Done. All session-owned attempts reconciled; only unrelated recovery-enable remains.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added versioned named protection rules, per-rule helper/journal ownership, conservative combined safety and aggregate app controls/status while retaining the single-rule Settings form. Implementation afba306 integrated into main at 54f3c8b. One independent safety review found nine issues, all fixed with regression coverage. Full offline suite passed before corrections; final targeted 149 tests and debug/release warnings-as-errors builds passed. No hardware writes; UI suite not repeated per request.
<!-- SECTION:FINAL_SUMMARY:END -->
