---
id: TASK-57
title: Stream live app status for Stream Deck and third-party integrations
status: To Do
assignee: []
created_date: '2026-10-07 01:08'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/AppControlServer.swift
  - Sources/PanelCtlCore/AppControl.swift
  - Sources/PanelCtlApp/AppDelegate.swift
documentation:
  - docs/usage.md
ordinal: 46010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Stream Deck buttons, SwiftBar/xbar plugins, Hammerspoon and similar tools want to show live state: whether a display is hidden, a rule is waiting/blacked out, an Action is running, automation is snoozed. Today they can only poll `panelctl app status --json`, which spawns a process per poll, lags behind changes and wastes battery. The control socket is one request, one response, then close (Sources/PanelCtlApp/AppControlServer.swift). A push-based status stream lets integrations stay current cheaply without PanelCtl gaining any new unattended triggers; it is read-only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 panelctl app status --watch --json prints the current status immediately, then a new complete status document (same schema as app status --json) on its own line whenever app, rule, display or running-Action state changes; it never launches the app and exits 3 if the app is not running.
- [ ] #2 Updates are coalesced so bursts produce a bounded number of lines; identical consecutive documents are not repeated. Each document carries a monotonically increasing sequence number so consumers can detect gaps.
- [ ] #3 When the app quits or the connection drops, the watcher emits a final not-running/disconnected document and exits non-zero; it does not auto-relaunch the app or silently reconnect forever.
- [ ] #4 The stream is read-only: watchers cannot issue commands on it, and multiple concurrent watchers neither block nor slow normal control requests. A slow or stalled consumer is disconnected rather than buffering without limit.
- [ ] #5 Status requests from existing CLIs and the existing request/response protocol keep working unchanged.
- [ ] #6 docs/usage.md documents the stream with a short Stream Deck or SwiftBar example and the line-delimited JSON contract. Focused fake-backed tests cover initial snapshot, change emission, coalescing, app shutdown, consumer disconnect and concurrent watchers; no hardware writes or desktop UI are required.
<!-- AC:END -->
