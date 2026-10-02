# Recovery validation checkpoint

## Current checkpoint: recovery-enable

- Full `swift test`: 169 tests discovered/executed by XCTest, 1 gated live test
  skipped, 0 failures (115 core, 54 app).
- `swift build -c release --product panelctl`: passed.
- Focused recovery tests: 31 total, 1 live test skipped, 0 failures. Private
  backend testing uses injected inventories/writers only.
- Release no-write subprocess checks passed; artifacts retained at
  `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-recovery-integration-5AB3D0D0-FCE6-4B19-8C63-04EC7F6A497A`.
- Fresh independent verifier successfully launched this time (run
  `b0ae6f4a-4c1a-41e5-b9e7-3986392338d1`), re-ran the focused suite with live
  variables unset and found no safety blockers. Report:
  `/tmp/panelctl-reenable-verification.md`.
- LSP returned unknown (no version-matched diagnostics); compiler/tests above
  are the validation evidence, not an inferred clean LSP result.
- `git diff --check`: passed. No recovery helper remains running.

**Live qualification failed safely, and is stopped.** One specifically approved
origin write moved DELL S2721DGF from `(3440,-20)` to `(3440,-4)`. Intermediate
verification saw unexpected ICC hash changes on two other displays, so no
restoration write or live parent-kill trial ran. User confirmed all four displays
visibly working and chose to continue safe work only. A final read-only snapshot
still showed `(3440,-4)` and the same post-trial hashes; verification against the
original journal still refused. Neither exact restoration nor window placement
is claimed. See [the trial evidence and remaining gate](recovery-origin-trial.md).

[Re-enable groundwork](recovery-reenable.md) is injection-only: a true-only,
session-scoped backend with write-ahead/no-replay tests, **not** a qualified
private reconnection path. Current-host enumeration exposed an offline ghost ID;
no offline hardware-to-ID provider is qualified. No private enable/disable call,
DDC/power/link command, permanent write, or startup behavior was introduced or
invoked. Production missing-display recovery still fails closed.

## Previous checkpoint (before the origin trial)

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
