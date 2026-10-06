---
id: TASK-27
title: Let scripts hide and show displays and add per-display menu actions
status: Done
assignee:
  - '@pi'
created_date: '2026-10-05 06:07'
updated_date: '2026-10-05 10:34'
labels:
  - app
  - cli
  - display-hide
dependencies:
  - TASK-25
  - TASK-26
references:
  - Sources/PanelCtlCore/AppControl.swift
  - Sources/PanelCtlCore/CLIParser.swift
  - Sources/PanelCtlCore/CLIHelp.swift
  - Sources/PanelCtlApp/AppControlServer.swift
  - Sources/PanelCtlApp/AppDelegate.swift
priority: medium
type: feature
ordinal: 17010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user wants display hiding available to third-party automation such as a Stream Deck (approved 2026-10-05). Today `panelctl app hide/show` only reports state and returns exit 4 (confirmation required) for any change; the only working path is the raw `panelctl away/back` with both UUIDs and consent flags, which bypasses the app settings and protection handling. Scripts should perform the display saved Hide style through the running app, single-button devices need a toggle, users need an easy way to get the exact command, and the menu should offer each display Hide or Show directly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The app commands hide, show and toggle-hide with --display UUID perform the display saved style through the running app (Black out, or Remove from desktop when Experimental is on and set up), report desktop and input outcomes, and are a no-op when already in the requested state. Exit codes are 0 done or no-op, 1 refused, 3 app unavailable, 5 partial input outcome and 6 recovery needed; exit 4 is no longer used.
- [x] #2 Scripted hides never start from idle, startup, wake or reconnection, and existing refusals (unknown UUID, ineligible display, unresolved recovery, busy, last usable display) still apply.
- [x] #3 The Displays detail offers Copy command for the selected display using the full path of the CLI bundled in the app, so it works without PATH setup.
- [x] #4 The menu lists each display with Hide or Show and its state, alongside Black Out Now, Sleep Displays, Pause Automation, Settings and Quit.
- [x] #5 CLI help, usage docs and tests (parser, app control and model) cover the new verbs and exit codes; full offline tests and warnings-as-errors builds pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Protocol and CLI: add toggle-hide; --display is required for hide, show and toggle-hide. Replace confirmation-required with done (exit 0) and failed (exit 1). Display commands never launch the app or retry once request bytes are sent, and wait up to 30 s for the result.
2. Control server: receive requests off the main thread and answer a display request when its operation finishes. A concurrent request is busy, including one that waited while another Hide or Show held the main thread. An oversized Hide or Show reply keeps its outcome; only oversized status fails.
3. Model: resolve the display tile by UUID and run the same Hide or Show as its button (Black out, or Remove from desktop). No-op when already in the requested state; refuse busy, wake/sleep transitions, unknown UUIDs and blocked actions. While recovery is unresolved, only Show of a hidden display runs; anything else is recovery-needed. Map the operation result to done, partial, failed or recovery-needed; the response carries only the requested display. Status lists every display tile with a UUID, and blacked-out displays report hidden-by-panelctl.
4. Displays detail: Scripts section, after any recovery details, with a copyable toggle-hide command using the CLI bundled in the app.
5. Menu: every display with Hide or Show (dimmed with a tooltip when it can't run) and its state.
6. CLI help, docs/usage.md scripting section, and tests for parser, client and server, model, menu and copy command; full offline tests and warnings-as-errors builds.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
eb61764: scripts hide/show/toggle-hide through the app's own Hide or Show (Black out, or Remove from desktop with Experimental on), waiting up to 30 s; exit 4/confirmation-required removed, done (0) and failed (1) added. Responses carry only the requested display; status lists every display tile. Menu lists each display with its state (subtitle on macOS 14.4+, title suffix before), dimming blocked actions with the reason as tooltip. Settings > Displays > Scripts shows the toggle-hide command with the bundled CLI path. Validation: swift test --disable-sandbox (Core 226, App 121, 0 failures; 2 opt-in skips each), warnings-as-errors builds of panelctl and PanelCtlApp, Displays fixture PNGs reviewed with PANELCTL_HELPER pointing at the debug CLI. Review pass pending (reviewer run 8ce25f67).

46cbc87 fixes review run 8ce25f67: (1) a toggle that arrived while Remove from desktop held the main thread ran afterwards and undid the first; the socket now accepts off the main thread and stamps arrival, and a request received before the last Hide or Show finished is busy (chosen over moving controller calls off the main actor, which would let display-change handling interleave with a hardware operation). (2) An oversized Hide or Show reply was downgraded to refused although the desktop changed; only oversized status fails now. (3) Hide of a blacked-out display during recovery returned no-op; only Show runs during recovery. New tests (testScriptToggleThatWaitedBehindAHideIsBusy, testScriptsCanOnlyShowDuringRecovery, testOversizedOperationResponseKeepsItsResult) each failed with its fix disabled. Validation: swift test --disable-sandbox (Core 226, App 124, 0 failures; 2 opt-in skips each), warnings-as-errors builds of panelctl and PanelCtlApp, scripts/test-release-version.sh. No hardware writes.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Scripts and Stream Deck buttons can hide and show displays through the running app: panelctl app hide|show|toggle-hide --display UUID runs the display's own Hide or Show (Black out, or Remove from desktop when Experimental is on and set up), waits up to 30 s, and reports done/no-op (0), refused/busy/failed (1), app unavailable (3), partial input (5) or recovery needed (6); exit 4 is gone. Existing refusals still apply, a request that waited behind another Hide or Show is busy, and only Show runs during recovery. Settings > Displays > Scripts copies the toggle-hide command with the bundled CLI path, and the menu lists each display with Hide or Show and its state. Verified offline with the full test suite (Core 226, App 124), warnings-as-errors builds of both products, release version checks and reviewed Displays fixture PNGs; review findings fixed in 46cbc87. No hardware was exercised.
<!-- SECTION:FINAL_SUMMARY:END -->
