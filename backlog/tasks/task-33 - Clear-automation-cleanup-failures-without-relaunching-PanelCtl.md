---
id: TASK-33
title: Clear automation cleanup failures without relaunching PanelCtl
status: To Do
assignee: []
created_date: '2026-10-05 20:15'
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
- [ ] #1 When automation cleanup can't be confirmed, the menu and Settings offer the retry the message asks for. It clears the block only when a cleanup run confirms brightness was restored, keeps the reason when it fails, and works with no display hidden. Relaunching is never the only way out.
- [ ] #2 A helper that exits or is stopped before it could change brightness or cover a display doesn't leave a cleanup failure. A helper that may have changed either still blocks Hide until cleanup is confirmed.
- [ ] #3 The cause of the 2026-10-05 occurrence is identified and covered by a fake-helper regression test; if it was the restarts after Show, those restarts no longer leave a cleanup failure.
- [ ] #4 Status text describes the actual state: it doesn't claim a desktop is hidden when none is, and a cleanup problem that blocks Hide is visible with its retry wherever the block is shown.
- [ ] #5 Fake-helper tests cover a cleanup failure from Hide, from Show and from a helper ended early; retry success and failure; and relaunch. The full offline suite and warnings-as-errors builds pass.
<!-- AC:END -->
