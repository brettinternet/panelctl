---
id: TASK-57
title: Stream live app status for Stream Deck and third-party integrations
status: Done
assignee: []
created_date: '2026-10-07 01:08'
updated_date: '2026-10-07 03:02'
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
- [x] #1 panelctl app status --watch --json prints the current status immediately, then a new complete status document (same schema as app status --json) on its own line whenever app, rule, display or running-Action state changes; it never launches the app and exits 3 if the app is not running.
- [x] #2 Updates are coalesced so bursts produce a bounded number of lines; identical consecutive documents are not repeated. Each document carries a monotonically increasing sequence number so consumers can detect gaps.
- [x] #3 When the app quits or the connection drops, the watcher emits a final not-running/disconnected document and exits non-zero; it does not auto-relaunch the app or silently reconnect forever.
- [x] #4 The stream is read-only: watchers cannot issue commands on it, and multiple concurrent watchers neither block nor slow normal control requests. A slow or stalled consumer is disconnected rather than buffering without limit.
- [x] #5 Status requests from existing CLIs and the existing request/response protocol keep working unchanged.
- [x] #6 docs/usage.md documents the stream with a short Stream Deck or SwiftBar example and the line-delimited JSON contract. Focused fake-backed tests cover initial snapshot, change emission, coalescing, app shutdown, consumer disconnect and concurrent watchers; no hardware writes or desktop UI are required.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a version-gated read-only subscription and sequenced status frames without changing legacy requests.
2. Connect model notifications to coalesced snapshots; bound socket writes and close watchers on shutdown.
3. Add CLI watch parsing/output, fake-backed transport/lifecycle tests and integration documentation.
4. Run focused checks and one independent review, fix concrete defects, commit implementation and completion evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented version-3 read-only status subscriptions, per-connection sequence numbers, 100 ms coalescing/deduplication, bounded nonblocking sockets, shutdown/disconnect terminal frames, CLI watch parsing/NDJSON output and usage documentation. Focused validation so far: AppControlServerTests 7 passed; AppControlTests + CLIParserTests 42 passed; AppStatusStreamTests 6 passed; two existing fake-backed model status/Action regressions passed. CLI missing --json exits 2. No hardware writes or interactive UI. Independent review running (workflow 97f20bdb-378d-4e35-b869-5ca76ee0419d); next step is consume findings, fix concrete scoped defects and commit.

Delivered on main in commit 166ce1a (Stream live app status over the control socket).
Acceptance evidence: AppControlTests.testWatchUnavailableEmitsOneSequencedDocumentAndNeverLaunches and CLIParserTests.testAppStatusWatchRequiresJSONAndRejectsMutatingCommands prove no-launch/unavailable and CLI parsing. AppStatusStreamTests.testInitialChangesCoalescingDeduplicationConcurrentWatchersAndShutdown proves immediate complete snapshots, changed snapshots, bounded burst coalescing, deduplication, sequences, two watchers plus a concurrent legacy status request, and terminal shutdown. ConsumerDisconnectAndAdditionalCommandsRemoveWatcher, StalledConsumerIsDisconnectedWithoutBlockingHealthyWatcher, OversizedSnapshotDisconnectsRatherThanTruncatingEvidence, AbruptDropAfterInitialFrameEmitsNextSequenceAndNeverReconnects and LegacyServerDropProducesFinalDisconnectedDocument cover socket lifecycle and bounded read-only behavior.
Verification: swift test --disable-sandbox --filter AppControlServerTests (7 passed); filter AppStatusStreamTests (6 passed); AppControlTests and CLIParserTests (42 passed); DisplayActionAppTests.testActionLeaseBlocksCompetingEntryPointsAndKeepsRequestsStaleAfterFinish (1 passed); AutomationRulesTests.testAggregateStatusAndMasterControlsCoverMultipleEnabledRules (1 passed). Total 57 distinct focused tests passed. CLI invocation without --json confirmed exit 2; git diff --check passed. LSP clean for AppControl.swift, CLIParser.swift, main.swift, AppDelegate.swift and AppControlServer.swift; new stream file diagnostic report was unknown, so successful Swift build/tests are authoritative.
Single independent reviewer pass f7803d49-784d-49c7-991d-32dc6300d082: no validated findings. Residual limitation: model notification wiring was source-reviewed, not directly exercised end-to-end by new stream fixtures; existing fake model status/Action tests passed. No native UI or hardware writes performed. docs/usage.md documents NDJSON, sequences, coalescing, terminal behavior, limits and a Stream Deck/jq example.
No remaining blocker or resumable implementation step. Claim released by Done status and clearing the temporary assignee. No worktree created; no push or PR requested.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added panelctl app status --watch --json: sequenced read-only NDJSON snapshots, coalescing/deduplication, bounded consumers and terminal disconnect handling without launches/retries. Existing request/response behavior preserved. Delivered in 166ce1a; 57 focused tests passed and independent review found no validated defects. Documentation includes a Stream Deck example.
<!-- SECTION:FINAL_SUMMARY:END -->
