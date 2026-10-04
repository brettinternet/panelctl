# Display-disable offline acceptance (TASK-8)

Fresh checkpoint: 2026-10-04, macOS 27.0.1 build 26A434, Apple Silicon,
Apple Swift 6.4 (swiftlang-6.4.0.34.1). Baseline: `be3142c` plus TASK-8 changes.
This supersedes historical test counts, not the historical evidence itself.
The [implementation plan](display-disable-implementation-plan.md) remains canonical.

**This is offline evidence, not permission or readiness for a hardware trial.**
Production physical-sink identity and physical/awake/driver providers still refuse.
No private setter, public restoration, DDC write, global reset, logout or reboot
was invoked. Rehearsal observes actual displays but never changes them.

## Commands and results

Logs are retained locally under `.build/task8/` (not committed).

| Check | Command | Result |
| --- | --- | --- |
| Full suite | `env -u PANELCTL_TEST_LIVE_BLACKOUT -u PANELCTL_FAKE_HELPER_JOURNAL -u PANELCTL_FAKE_HELPER_FAULT swift test --disable-sandbox` | 217 tests: 163 core + 54 app; zero failures, two skips |
| Focused recovery | `swift test --disable-sandbox --filter 'Recovery\|DisplayRecovery'` | 79 core recovery tests, zero failures, one skip |
| Debug CLI/app | `swift build --disable-sandbox --product panelctl` and `swift build --disable-sandbox --product PanelCtlApp` | Both passed |
| Release CLI/app | Same build commands with `-c release` | Both passed |
| Intel release CLI/app | Same release commands with `--triple x86_64-apple-macosx13.0 --scratch-path .build/task8-x86_64` | Both passed |
| Release version | `scripts/test-release-version.sh` | Passed |
| No-write integration | `swift scripts/test-display-recovery.swift /Users/brett/dev/me/panelctl/.build/debug/panelctl` and same with `.build/release/panelctl` | Both passed, all scenarios below |

The full suite explicitly skips the connected-screen blackout-window test unless
`PANELCTL_TEST_LIVE_BLACKOUT=1`. Before TASK-8 this test displayed opaque windows
by default. Other geometry tests construct unshown windows; dimming tests use
fake DDC writers. Optional retained ICC-artifact replay also skipped because
`PANELCTL_ICC_EVIDENCE_DIR` was unset. Neither skip is a hardware pass.
Initial LSP reports for the changed tests were unknown; subsequent source/lease-test
reports were clean. Compiler/tests are the acceptance authority.

SwiftPM on this toolchain uses `out/Products`, not triple-named binary directories;
use `swift build ... --show-bin-path`. Universal binaries were assembled with:

```sh
xcrun lipo -create .build/release/panelctl .build/task8-x86_64/out/Products/Release/panelctl -output .build/task8/panelctl-universal
xcrun lipo -create .build/release/PanelCtlApp .build/task8-x86_64/out/Products/Release/PanelCtlApp -output .build/task8/PanelCtlApp-universal
xcrun lipo -archs .build/task8/panelctl-universal
xcrun lipo -archs .build/task8/PanelCtlApp-universal
```

Both report `x86_64 arm64`. No app was installed or launched. An initial assumed
triple-directory path produced arm64-only output; the corrected commands above
replaced it and the final architecture checks passed. This host's `lipo
-verify_arch` rejected the invocation; `-archs` supplied the actual evidence.

An additional Intel `swift test --triple x86_64-apple-macosx13.0 --scratch-path
.build/task8-x86_64 --filter ...` compiled but failed discovery because the native
helper could not load an Intel-only test bundle. Running the built bundle under
Rosetta succeeded. After corrections, rebuild and the expanded selection below
passed 18 tests with zero failures:

```sh
swift build --disable-sandbox --build-tests --triple x86_64-apple-macosx13.0 --scratch-path .build/task8-x86_64
arch -x86_64 /usr/bin/xcrun xctest -XCTest 'PanelCtlCoreTests.RecoveryDisplayBindingTests,PanelCtlCoreTests.RecoveryEligibilityTests,PanelCtlCoreTests.RecoveryCLITests/testProductionProviderRefusesBeforeConstructingAnyWriter,PanelCtlCoreTests.RecoveryLeaseTests/testLeaseLossAtEveryDisableBoundaryPreventsCompletion,PanelCtlCoreTests.RecoveryLeaseTests/testCommitIntentSaveFailureAndLegacyStagingCannotAuthorizeRecovery,PanelCtlCoreTests.RecoveryLeaseTests/testManualSystemReenableRetiresAuthorityBeforeFailedVerification' .build/task8-x86_64/out/Products/Debug/PanelCtlCoreTests.xctest
```

This covers explicit Intel rejection before library loading, physical eligibility
rejection, and production refusal before writer construction. It does not qualify
private disable on Intel. The full Intel suite was not run. The current SDK's
XCTest/Testing libraries emit macOS-14-minimum linker warnings for the macOS-13
test target; cross-compilation is not an actual macOS-13 runtime qualification.

## Fake-writer failure matrix

All entries below use injected writers/observations, never Apple private setters.
Tests live in `Tests/PanelCtlCoreTests/`.

| Boundary / risk | Executed coverage |
| --- | --- |
| Dynamic symbol/ABI | `RecoveryDisplayBindingTests`: framework/symbol fallback, image UUID/origin rejection, unavailable OS/Intel rejection before loading, C-convention fake and handle lifetime |
| Transaction lifetime | Binding/Reenable tests inject failure before begin, at begin, before setter, at setter, before completion and at completion in both directions; cancellation only for unconsumed transactions; session scope only |
| Disable persistence | `RecoveryLeaseTests`: initial save failure prevents begin; successful setter followed by failed staging save cancels; completion-intent save failure cancels and revokes in-memory authority; failed completion and post-completion acknowledgment retain recoverable completion-attempt intent |
| Actual process crash windows | Lease subprocess matrix kills the fake helper before READY, after READY, at begin/setter, before completion and after completion; persisted target and staging govern startup recovery, never a guessed ID |
| Re-enable persistence | `RecoveryReenableTests`: intent failure prevents enable; crash before/after enable preserves one-shot budget; final persistence failure retains original baseline and attempt; consumed completion error never cancels or replays |
| Identity | Reenable/DisplayRecovery tests reject recycled ID, replaced sink, duplicates, missing serial/connector, stale/unqualified evidence, changed boot/build/user, extra/missing displays and identity races |
| Topology/lifecycle | `RecoveryEligibilityTests` invalidates selection at all real transaction validation boundaries; excludes virtual/headless/DisplayLink/unknown screens, main/built-in/mirrored target, survivor loss, closed lid and Intel; fixed sleep/wake deferral budget |
| Command chain | `RecoveryCLITests`: strict consent/timeout/selector parsing, injected command-to-helper-to-writer flow, failure exits, absent-target status, journal-only enable/panic, startup recovery requiring fresh selection, journal ID recheck under lock |
| Runtime recovery races | Lease tests exercise EOF, signals, deadline, topology collapse, deferred sleep and exhaustion; system re-enable and changed-layout/EOF races durably close authority and never redisable or write layout to fight the OS |
| Concurrent recovery | Lease tests and live no-write script prove per-user operation lock plus journal lock; different custom journals cannot bypass serialization |
| Public/legacy safety | DisplayRecovery tests cover verify-only, archives, permissions/corruption, legacy strictness, write-ahead public restoration, identity revalidation and bounded convergence without repeated writes |

Persistence faults are injected by releasing the test store's lock; process-death
checks use real subprocesses and fake display state. These prove application
ordering, not power-loss durability or actual filesystem/driver failure behavior.
External display utilities do not share PanelCtl's locks.

## No-write subprocess evidence

Both debug and release runs used only capture/verify/rehearse plus direct journal
inspection. Passed: unresolved capture protection, deadline verification,
independent helper survival after parent SIGINT/SIGTERM/SIGKILL (lease EOF),
concurrent operation rejection, helper SIGKILL retaining unresolved evidence,
manual verify afterward, and stale-boot refusal with preserved journal.
The script retains artifacts; no unresolved real journal was discarded.

- Debug (final): `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-recovery-integration-A411E983-7693-4DD9-BFC2-E655DBCE9D19`
- Release (final): `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-recovery-integration-4031DCC9-E5B3-4687-8BF8-B2986E8259D1`

Earlier successful runs are also retained at suffixes
`0008BA64-2F1A-42D0-83CC-A004C4BCBB3C` (debug) and
`8E9AAA39-7CB9-40B7-A83C-E8C5CA23EFB2` (release).

## Independent safety review

One independent read-only Codex `gpt-6-sol` high-effort review traced all production
private entry points, the transaction backend and journal/lease protocol. Raw
report: `.build/task8/review-sol.txt`. Failed launch attempts (Claude unauthenticated;
unsupported Codex model) did not review code. No second general review was run.

The reviewer identified two concrete defects. Both were reproduced with fake
writers before changing production code (two tests, six failing assertions in
`.build/task8/regressions-before.log`), then corrected and rechecked:

1. Manual/startup recovery could observe the target online, fail layout repair or
   verification, and leave private authority open for a later disappearance.
   `RecoveryEngine.finish` now durably closes authority on observing the retained
   ID online and forces verify-only on that and later attempts. Identity mismatch
   still refuses; observing a recycled ID can only remove permission, never grant
   it. The regression rejects layout writes and later private enable.
2. Final validation could cancel a staged disable while leaving sufficient
   evidence for later enable. `disableCommitStarted` now records completion-attempt
   intent only after final validation. Recovery requires both staging and this
   marker; staging-only old journals refuse without being discarded. Tests revoke
   the lease at all four validation boundaries and then simulate unrelated target
   loss. They also cover failed completion-intent persistence (disk and in-memory
   helper paths), legacy staging, and cancellation of the pre-completion callback.

The fresh suites, both architectures, builds and no-write rehearsals above were
rerun after these corrections; `git diff --check` passed. No assertion was removed
to hide a failure: the pre-commit crash with an already-online target now explicitly
expects `verified`, not a restoration write.

Trace: consent-gated parser → CLI → locked helper → private session → disable →
transaction → dynamic binding. Enable/panic/startup and helper EOF/deadline/signals/
eligibility recovery converge on the locked engine → retained-ID re-enable →
private session → transaction/binding. Public layout repair is allowed only after
our own recovery, not after observing an external re-enable. Completion consumes
the transaction even on error; the scope remains session-only. No app startup
private writer or global fallback was added.

Residual limits: journal persistence and display completion are not atomic; a
crash or filesystem failure around completion-intent persistence is uncertain,
not proof of a completed disable. Physical providers and initial-awake qualification
remain deliberately unavailable in production. The reviewer did not qualify
hardware, and neither do the regression tests.

## Pre-trial gates — not hardware qualification

- Offline tests/builds/rehearsals above establish protocol behavior only. READY
  acknowledges startup, not ongoing helper health or reconnect capability.
- **Blocked:** independently qualified, fresh hardware-to-retained-ID identity
  for the actual target, including its offline state. Current refusal-only
  production providers cannot pass this gate. Cached CG metadata/HPD/location or
  synthetic evidence must not be substituted; no force flag or numeric ID sweep.
- **Blocked:** fresh physical survivor, driver, awake/lid and lifecycle evidence
  at mutation boundaries. Exactly one selected non-main external display, no
  mirroring, Apple Silicon, another verified usable physical screen.
- **Required:** explicit TASK-9 scoped human approval, user present, exact target,
  bounded deadline and journal/helper recovery arrangements, accepted manual
  failure ladder and color/HDR/rotation limitations. Green TASK-8 is not consent.
- **Unproven:** driver acceptance of retained-ID re-enable while offline, signal
  release/return, monitor input auto-switching, HPD behavior, window placement,
  public mode/mirroring restoration and actual asynchronous convergence.
- **Unproven and separately gated:** global restore, logout, reboot and physical
  replug effects. Never escalate automatically. Helper SIGKILL, OS/driver hangs,
  logout/reboot and sleep delay remain outside the recovery guarantee.
- TASK-10 DDC `0x60` input selection is conditional, separately approved work
  after signal restoration; no DDC write was performed here.

A refusal is the correct safe result, not a successful reconnection or completed
hardware qualification. Preserve unresolved journals and record the exact missing
evidence instead of weakening these gates.
