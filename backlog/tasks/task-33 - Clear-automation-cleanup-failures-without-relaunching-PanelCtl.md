---
id: TASK-33
title: Clear automation cleanup failures without relaunching PanelCtl
status: Done
assignee: []
created_date: '2026-10-05 20:15'
updated_date: '2026-10-05 20:39'
labels:
  - app
  - protection
  - display-hide
dependencies: []
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - Sources/panelctl/main.swift
  - Sources/PanelCtlCore/Blackout.swift
  - TASK-17
  - TASK-21
documentation:
  - docs/display-hide-ux.md
priority: high
type: bug
ordinal: 23010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On 2026-10-05 the user's app (started 12:46) reported 'Automation suspended while desktop is hidden · cleanup needs attention: Automation cleanup could not be verified; retry automation cleanup before hiding a display' with no display hidden. In that state every Remove-from-desktop Hide is refused ('Automation cleanup needs attention … Check Automation, then try again') and automation stays off, so the OLED gets no idle protection, yet nothing in the app clears it. AppModel.protectionQuiescenceFailure is cleared only by a successful quiescence when a Remove-from-desktop Hide or Show starts, or when a journal appears outside the app. Hide is refused while it's set, Show needs a journal, and Retry Automation and turning automation off and on go through reconcileProtection, which keeps the helper stopped while the failure is set. ProtectionService also keeps its own unresolvedCleanupFailure until a helper that can change brightness reports a clean stop, and no such helper runs. Only quitting and reopening PanelCtl clears both. The status line also says a desktop is hidden when none is. Likely trigger, not confirmed: logs show a Show at about 13:29:08 (current.json updated at 13:29), then six app helper launches within 7 seconds (13:29:10–13:29:17) living about 0.25, 2.4, 0.24, 2.5, 0.26 and 7.9 seconds, consistent with display-change restarts ending helpers before they report a stopped status. ProtectionService records any exit without a cleanup report as 'could not be verified', even for a helper that never changed brightness. The app's own logger recorded nothing then. Keep the TASK-17 rule: Hide refuses when PanelCtl can't confirm brightness was restored.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 When automation cleanup can't be confirmed, the menu and Settings offer the retry the message asks for. It clears the block only when a cleanup run confirms brightness was restored, keeps the reason when it fails, and works with no display hidden. Relaunching is never the only way out.
- [x] #2 A helper that exits or is stopped before it could change brightness or cover a display doesn't leave a cleanup failure. A helper that may have changed either still blocks Hide until cleanup is confirmed.
- [x] #3 The cause of the 2026-10-05 occurrence is identified and covered by a fake-helper regression test; if it was the restarts after Show, those restarts no longer leave a cleanup failure.
- [x] #4 Status text describes the actual state: it doesn't claim a desktop is hidden when none is, and a cleanup problem that blocks Hide is visible with its retry wherever the block is shown.
- [x] #5 Fake-helper tests cover a cleanup failure from Hide, from Show and from a helper ended early; retry success and failure; and relaunch. The full offline suite and warnings-as-errors builds pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Use the existing locked luminance journal to verify cleanup after early helper exits; add a cleanup-only helper retry that cannot start automation or cover displays. 2. Wire retry and truthful status through AppModel, menu and Settings, retaining unresolved evidence across relaunch. 3. Add fake-helper and journal regressions for Hide/Show, early restarts and retry outcomes; run the offline suite and warnings-as-errors builds, then one independent safety review. 4. Commit implementation, merge to main, finalize task evidence and remove the owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause: the missing stopped-report path unconditionally latched unknown cleanup, including pre-status exits and rapid restarts, while both the app guard and service latch prevented Retry Automation from ever running cleanup. The observed 2026-10-05 message identifies that path; historical post-Show restart timing remains correlation, not proof of the exact signal/event. Six-restart and immediate-exit fake-helper regressions reproduce and cover the defect without claiming a live replay.
Implementation: reuse the existing luminance lock/journal as read-only proof after process death; nonempty, locked or malformed evidence still refuses. Explicit cleanup-only retry restores journaled exact-UUID brightness originals without overlay, Hide, Show or input switching. Failures survive relaunch; menu and both Settings tabs offer retry even with automation off/no hidden journal. Also fixed repeated dim after a failed journal persist so an unpersisted original can never authorize a later hardware write.
Verification: swift test --disable-sandbox passed 230 core + 142 app tests, zero failures, four expected skips (live blackout, retained ICC artifacts, two optional screenshot suites). Separately ran SettingsWindowTests.testDisplaysFixtureSnapshots with PANELCTL_SETTINGS_FIXTURE_OUTPUT and inspected the rendered cleanup Displays/Automation PNGs; retry and reason are visible with no hidden desktop. CLI and app debug AND release builds passed -Xswiftc -warnings-as-errors; scripts/test-release-version.sh and git diff --check passed. Logs: /tmp/panelctl-task33-final-suite.log, /tmp/panelctl-task33-final-{cli,app,release}.log, /tmp/panelctl-task33-release-{cli,app}.log; native fixture PNGs /tmp/panelctl-task33-settings/. LSP returned unknown (no version-matched diagnostic report); compiler/tests are the validation evidence. No live display, brightness, DDC or private writes were executed.
One independent reviewer pass (run b1194061-53ce-4b10-a17b-b76dd62e6a06) found shutdown relaunch and dropped concurrent-quiescence callbacks. Both reproduced in fake-helper tests before correction; corrected tests and full suite passed. Review artifact: /Users/brett/.pi/agent/sessions/--Users-brett-dev-me-panelctl--/subagent-artifacts/outputs/c7f8b08a-3f12-4967-b827-eece09ff0beb/cleanup-safety-review.md.
Delivery: implementation commit 111ccb1f2e26c6afc749f7b479e3eefb9391b174 fast-forwarded into main. Session-owned task-33-cleanup worktree and branch removed using Worktrunk; associated Herdr w24 workspace closed by post-remove hook. Existing recovery-enable checkout is unrelated and retained untouched. No push. No remaining implementation blocker or resumable step.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added safe automation-cleanup retry without relaunch, truthful status and persistent refusal until verified restoration. Covered early restarts, Hide/Show failure, retry outcomes, relaunch and shutdown races with fake helpers. Full offline suite, native Settings fixtures and debug/release warnings-as-errors builds passed; 111ccb1 merged to main and owned worktree cleaned up.
<!-- SECTION:FINAL_SUMMARY:END -->
