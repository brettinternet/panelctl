# Recovery validation checkpoint

Host: macOS 27.0.1 (26A434), arm64, Apple M5 Max Mac Studio.

Completed:

- `swift test`: 158 tests passed (104 core, 54 app), including 20 recovery tests.
- `swift build -c release --product panelctl`: passed.
- `scripts/test-display-recovery.swift` against debug and release binaries:
  live read-only capture/verification and exact-mode preflight; deadline firing;
  helper survival after parent SIGKILL; rejection of concurrent operations even
  with different journals; helper SIGKILL retaining unresolved evidence; manual
  no-write verification afterward; stale-boot rejection and snapshot retention.
- `git diff --check`: passed.

The subprocess tests used only `capture`, `status`-style journal inspection,
`verify`, and `rehearse`. They did not invoke `guard`, `restore`, private
state-changing APIs, DDC power, or any display configuration writer. Restoration
ordering, idempotence, and failure behavior were exercised with an injected
writer. Actual public mode/mirroring restoration and private display reconnection
remain unqualified; do not infer hardware recovery from a successful rehearsal.

Independent review could not launch because pi-subagents failed capability
discovery with `Cannot find module '../runs/foreground/subagent-executor.js'`.
The user explicitly approved direct implementation and focused tests instead.

Test artifacts were intentionally retained in OS temporary directories with
`panelctl-recovery-integration-` prefixes. The final release run used:

```text
/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-recovery-integration-67100613-A5D2-4033-B560-A963EDB9B83C
```

No test helper remains running after the successful runs. The user-level
`~/Library/Application Support/PanelCtl/Recovery/operation.lock` file is an inert
coordination file; no launch agent, background service, or startup behavior was
installed. See [usage and remaining qualification gates](display-recovery.md).
