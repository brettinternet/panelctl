# Recovery validation checkpoint

## ICC follow-up checkpoint

- Read-only reconstruction proved the failed trial's two ICC hash changes are
  creation-time-only; see [evidence and exact comparison limits](recovery-color-investigation.md).
- New snapshots retain both raw hashes and eligible date-independent hashes.
  Legacy journals remain strict and unchanged. All other profile bytes stay
  protected. Synthetic byte-mutation and malformed-profile tests passed.
- Offline replay of both retained real profiles passed, reproducing their old
  full hashes and matching their new date-independent fingerprints.
- Full suite: 177 tests, 2 opt-in tests skipped, 0 failures (123 core, 54 app).
  The offline replay was separately run successfully; the live trial was not
  enabled in the full suite. Release build passed. LSP remained unknown.
- Release no-write subprocess checks passed with artifacts at
  `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-recovery-integration-FCE0C4E6-661E-4439-8D60-ECF4C61E84E9`.
- Fresh read-only reviewer `17d552b3-f4e7-459d-9022-adae13177986` found no
  validated defects in the scoped ICC delta. Report: `/tmp/panelctl-icc-review.md`.
  Static review is not live qualification or emitted-color verification.
- Specifically approved origin-only timed trial passed: `(3440,-4)` →
  `(3440,12)` → `(3440,-4)`, `restored` at `deadline`, 10.52 seconds. Final
  topology/profile-content verification passed; user confirmed normal visible
  output. This qualifies only the tested origin-restoration path. See
  [the complete live evidence](recovery-origin-trial.md).
- Parent-kill trial at the same baseline has separate explicit approval,
  pending execution. No private enable/disable calls have been made.

## Previous checkpoint: recovery-enable

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
