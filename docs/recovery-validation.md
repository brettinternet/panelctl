# Recovery validation checkpoint

## Authorized execution follow-through

- The unchanged connected-screen geometry test passed standalone, in the full
  suite, with all nine geometry tests, and in ten bounded standalone repetitions.
  The historical 90% failure was not reproduced; no production fix is claimed.
- `29f2bcd` retains the strict first-sample assertion, adds failure-only paired
  bounds/timing context and guarantees temporary-window cleanup on thrown errors.
  A temporary synthetic first-sample mismatch exercised the diagnostics and
  failed as expected; it was removed before final validation.
- Full suite after the edit: **205 tests, 203 passed, two intentional skips,
  zero failures**. Origin-trial and retained ICC-replay variables unset.
  Warnings-as-errors build-tests passed. Release panelctl, PanelCtlApp and
  observe-recovery-identity builds passed; release-version checks passed.
  LSP unknown, not clean. Logs: `/tmp/panelctl-recovery-final-tests.log`,
  `/tmp/panelctl-recovery-final-warnings.log`.
- [Static binary inspection](recovery-identity-binary.md) establishes additional
  transport/cache facts, not a qualified recovery identity. Actual selected
  monitor shutoff/restoration remains blocked and is **not completed**.
- No origin/configuration/mode/power/connection change, private interface call,
  device client, or observer run occurred. Only the permitted test windows were
  shown. No push or merge. Independent follow-up review is tracked in the
  [integration record](recovery-integration-review.md).

## Original static integration review

[Parent and independent review](recovery-integration-review.md) found no validated
source-level blocker in the gated groundwork. Production private re-enable
remains blocked. The origin-trial handler is compiled into the helper despite
its test-only creator; no authorization bypass was demonstrated. The unresolved
full-suite geometry failure prevents an unconditional validation recommendation.
No tests/builds or live operations were run, and no merge or push occurred.

## Static geometry follow-up — no rerun

[Static investigation](blackout-geometry-investigation.md) narrows the retained
failure to an exact 90% center-preserving compositor/model bounds discrepancy.
The conversion preserves size, and the relevant source/test are unchanged from
main. Root cause is not proven; no conversion fix or origin correction is
justified. The full-suite failure remains open. No tests, windows, observer runs,
or display operations were performed for this follow-up.

## Driver-facing source and observer boundary follow-up

- [Targeted DCP/framebuffer research](recovery-connector-binding.md#driver-facing-source-follow-up-2026-10-03-utc)
  distinguishes IOAV EDID retrieval from proof of fresh acquisition; Wine joins
  via online CG metadata. Clamless reports framebuffer IDs can differ from CG
  IDs. Neither supplies a qualified offline Dell binding; neither was run.
- Five new offline tests, 28 observer tests total. A regression failed before
  the four-line fix: output failure during interest-registration recording no
  longer retains the service or reads the next iterator entry.
- Focused suite: 67 tests, 65 passed, two intentional skips, no failures. Live
  approval and optional ICC replay variables unset. Both release products build.
  LSP clean for the changed tests, unknown for the collector.
- No observer run, device transaction or display mutation. The existing full-suite
  geometry failure below remains unresolved; the live-window test was not rerun.
- Private source copies and logs are linked in the research record. Existing
  checkout retained; no push, PR, merge, new worktree or journal backfill.

## Connector-binding and offline failure-test follow-up

- [Source research and evidence](recovery-connector-binding.md): no qualified
  fresh, independent offline connector-to-CG-ID contract found. Synthetic
  dictionary-only matching fixture confirmed absent serial/location can match.
- `d5a8323`: ten additional offline collector tests; all 23 observer tests pass.
  Focused recovery/identity/ICC suite: 60 passed, two intentional skips, zero
  failures; release panelctl/observer builds pass. LSP unknown.
- Full suite ran 200 tests but is **not green**: two bounds assertions failed in
  the existing connected-screen window-placement test. Cause unestablished;
  test not retried or modified. Details/logs in the research record. Do not
  describe this follow-up as a full-suite pass.
- No further observer recording, display configuration writer, guard/restore,
  origin trial, device-client/DDC transaction or disconnect experiment. The full
  suite's existing window-placement test created temporary test windows.

## Bounded observer checkpoint

- [Read-only lifetime observer](recovery-identity-observer.md) implemented with
  existing recovery operation lock and fresh verify-only baseline journal.
- 13 focused offline tests pass, including queue/output bounds, readiness,
  failed callback removal, summary publication failure and service-read errors.
  Independent review found four issues; fixes passed follow-up review.
- At `001846a`, full suite: 190 tests, 188 passed, two intentionally skipped,
  zero failures. Trial/replay variables unset. Both release builds pass; LSP
  unknown. No recovery guard/restore or origin trial ran.
- One 60.012-second passive control passed, with 37 records, six valid initial
  iterator drains, nine initial services and no subsequent callbacks received.
  Two inventories and before/after snapshots matched exactly, including raw ICC
  hashes. Artifact permissions and lock release independently verified.
- No disconnect/state change; no private enable qualification. See the observer
  record for private artifact paths, context and interpretation limits.

## Read-only offline identity checkpoint

- [Service-lifetime research](recovery-offline-identity.md) confirms registered,
  active framebuffer objects are insufficient physical identity evidence. The
  unidentified offline ID 4 has one too. Private re-enable remains blocked.
- Diagnostic now retains independent bounded registry inventories, context,
  API statuses and same-object path relookup in private artifacts. Two read-only
  reports matched; Dell remained active/non-main/external at `(3440,-4)`.
- Script typecheck and direct JSON/permissions/correlation assertions passed.
  Full suite: 177 tests, 175 passed, 2 skipped (live origin and optional ICC
  replay), zero failures, with trial/replay variables explicitly unset. Release
  build passed. LSP unknown. No production recovery code or tests changed.
- No display writes or manufactured disconnect, no helper left running, no
  journal edits. Exact missing transition/freshness evidence and rejection rules
  are documented; further live experimentation needs separate approval.

## ICC follow-up checkpoint

- Read-only reconstruction proved the failed trial's two ICC hash changes are
  creation-time-only; see [evidence and exact comparison limits](recovery-color-investigation.md).
- New snapshots retain both raw hashes and eligible date-independent hashes.
  Legacy journals remain strict and unchanged. All other profile bytes stay
  protected. Synthetic byte-mutation and malformed-profile tests passed.
- Offline replay of both retained real profiles passed, reproducing their old
  full hashes and matching their new date-independent fingerprints.
- Final full suite with retained-byte replay enabled: 177 tests, 1 gated live
  test skipped, 0 failures (123 core, 54 app). Live activation variables were
  explicitly unset. Release build passed. Logs: `/tmp/panelctl-color-final-tests.log`
  and `/tmp/panelctl-color-final-release.log`. LSP remained unknown.
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
- Separately approved parent-kill trial also passed recovery verification:
  owned XCTest parent killed itself only after the helper verified the move;
  independent helper persisted `restored`/`parent-exit`; separate read-only
  verification passed; user confirmed normal visible output. Intentional test
  process death produced expected runner exit 1, not an ordinary XCTest pass.
- Both follow-up trials restored their approved current baseline `(3440,-4)`.
  Neither restored the first failed trial's `(3440,-20)`; that journal remains
  unresolved and unmodified. No private enable/disable calls have been made.
  Mode/mirror restoration, offline identity, and private reconnection remain
  unqualified. No helper remains running.

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
