---
id: TASK-69
title: Deliver valid status-stream frames larger than the socket buffer
status: Done
assignee: []
created_date: '2026-10-08 05:43'
updated_date: '2026-10-08 05:53'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/AppStatusStream.swift
  - Tests/PanelCtlAppTests/AppStatusStreamTests.swift
type: bug
ordinal: 57010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Review of TASK-57: AppStatusStream writes each frame with one nonblocking send and disconnects on any partial write. macOS AF_UNIX stream sockets default to an 8 KiB send buffer (measured on macOS 27.0.1: a fresh 16 KiB send accepts only 8,192 bytes), so a healthy watcher is dropped whenever a valid status document exceeds ~8 KiB — e.g. several displays/rules or a long rule name — far below the advertised 1 MiB frame limit.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A healthy watcher that has not yet started reading receives a complete valid frame larger than the default socket buffer and stays subscribed.
- [x] #2 A stalled consumer is still disconnected with bounded buffering and never blocks the main actor or other watchers.
- [x] #3 Focused AppStatusStreamTests cover the large-frame and stalled-consumer cases.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Size each watcher's kernel send buffer to the frame limit at subscribe so one complete frame always fits when the consumer is current; partial writes then mean a real backlog and still disconnect. Refuse the subscription if the buffer cannot be sized. Add a large-frame regression and keep the stalled-consumer test meaningful.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered in 4181779. AppStatusStream.subscribe sets each watcher's SO_SNDBUF to the 1 MiB frame limit (subscription refused if that fails), so a complete frame always fits while the consumer is current; a partial write still means an unread backlog and disconnects. Kernel buffering stays bounded at one frame per watcher (64 watchers max). Offline measurement on macOS 27.0.1: default AF_UNIX send buffer 8,192 bytes; with SO_SNDBUF 1 MiB a 1,048,064-byte nonblocking send is fully accepted. New testValidFrameLargerThanDefaultSocketBufferReachesWatcherBeforeItReads (~1 MiB frame, reader not yet reading) and the stalled-consumer test (now ~200 KB frames so backlog exceeds one frame) both fail on the previous source and pass now; AppStatusStreamTests 7/7. docs/usage.md stream limits updated. No hardware writes or UI.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Status-stream watchers now receive valid frames up to the 1 MiB limit instead of being dropped above the 8 KiB default socket buffer; stalled consumers are still disconnected with bounded buffering. Red-to-green AppStatusStreamTests regressions.
<!-- SECTION:FINAL_SUMMARY:END -->
