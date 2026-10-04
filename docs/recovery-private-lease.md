# Bounded private-recovery lease (TASK-5)

This is offline recovery infrastructure, not hardware qualification or permission
to write a display. Production still installs **no private disable or re-enable
backend**. Identity remains synthetic-only; TASK-6 supplies physical/lifecycle
preflight and TASK-7 connects the guarded CLI. No new daemon or public command is
introduced here.

## One writer, one lease

The existing helper owns the per-user operation lock and the selected journal's
lock throughout its 1–60 second lease. This applies to custom journal paths too.
The parent never borrows these locks or calls a display setter on the strength of
READY. It sends one bounded `DISABLE <journal UUID> <retained ID>` message over the
existing parent lease pipe. Successful delivery is **not** a commit acknowledgment;
the durable journal records the outcome. A dead/unready helper cannot execute a
request. Normal shutdown closes the lease and waits for the helper.

The helper checks its own successful READY write, monotonic deadline, wall-clock
journal deadline, live parent pipe, unchanged baseline, qualified identity and
injected physical/lifecycle preflight. The transaction repeats these checks before
begin, immediately before the setter, and before session-scope completion. Further
pipe input or EOF revokes disable authority. Invalid/duplicate requests invoke the
same recovery path rather than issuing another disable.

The version-2 journal retains its baseline and gains optional fields/states:

| Evidence | Meaning |
| --- | --- |
| `disabledByUsID`, `disableAttempted: true`, `disabling` | Selected intent synchronized **before** any transaction call; alone this never authorizes re-enable |
| `disableStaged: true` | Setter staged successfully; synchronized before final revalidation/completion. Required for any private recovery attempt |
| `disabled` | Completion returned and the following save succeeded; not proof of signal loss |
| `reenableAttempted: true`, `restoring` | Synchronized before the one permitted private enable attempt |
| `privateRecoveryClosed: true` | Successful verification retired private authority, even if a later observation fails |
| `needsAttention` | Retained evidence with refusal/failure; never silently discarded |

Recovery must not require the post-commit `disabled` acknowledgment. A crash in
that window leaves `disabling`, `disableStaged` and the retained target, sufficient
to *evaluate* one identity-checked recovery attempt, not sufficient to bypass
identity checks. Death before successful staging cannot authorize re-enable if
the target later disappears for an unrelated reason. Staging persistence failure
cancels without completion. The durable staged marker still cannot prove whether
completion happened: write-ahead evidence and a display commit are not atomic.
Setter failure cancels the uncompleted transaction; completion consumes it even
on error. A failed or interrupted enable attempt is never automatically replayed.

## Shared recovery path

`RecoveryEngine.recover` acquires both locks, reloads the journal and invokes the
same engine used by the helper. It is the internal manual/startup/shutdown entry
point; the live helper uses its already-held locks. A helper's EOF, deadline or
handled signal uses that same engine. TASK-7 owns startup/CLI wiring, not an
alternate recovery implementation. A boot, OS-build or user mismatch invalidates
stale authority. No global restore, logout or reboot is performed automatically.

Private enable is allowed only for the journaled target with qualified fresh
identity. After enable there are at most six read-only observations, spaced by
200 ms, to establish strict restoration identity. The public session-scoped
restorer then runs at most once if needed. A second bounded observation phase
verifies the full baseline. No convergence loop retries a writer. Return-code
success without connectivity/configuration convergence ends in `needsAttention`.
An interrupted enable can subsequently be verified if the baseline is present,
but cannot be replayed while the target is missing.

Legacy version-1 journals and version-2 journals without successful staging
evidence never authorize private writes. Missing intent never
comes from disappearance alone. A stored `verifyOnly` flag cannot be overridden
by `restore`; it forbids public **and** private writers. Successfully resolved
private intent cannot be revived by a later unrelated disappearance. Unresolved
journals continue to block replacement; resolved baselines are archived.

## Limits

The helper can itself die after any liveness check, including during a setter.
Locks prevent competing cooperative writers, not writes by other applications.
Sleep can delay timers; a hung WindowServer/driver can block the helper. No lease
provides a hard wall-clock recovery guarantee. Helper SIGKILL, logout, reboot and
OS/driver failure remain outside its survival guarantees. A later same-boot
recovery can evaluate retained evidence; new boot/OS/user or unknown identity
requires manual attention. Real offline identity is still unqualified on this
host. Refusal is safe behavior, not successful reconnection.

## Fresh offline validation

- `swift test --disable-sandbox --filter RecoveryLeaseTests`: fake transactions,
  durable ordering, lease/topology/preflight/persistence refusal, cancellation,
  bounded delayed/exhausted convergence, retired/rehearsal authority and both
  locks across custom journals. The test-only XCTest subprocess runs the actual
  helper with synthetic observations and fake writers: death before/after READY,
  before/after staging and commit, EOF/shutdown, deadline, SIGINT and SIGTERM.
  Same-boot startup recovery exercises the commit-before-ack window and refuses
  a later unrelated disappearance after a pre-staging crash.
- Existing `RecoveryReenableTests` cover legacy/unknown identity, host changes,
  enable intent persistence failure, interrupted enable, commit errors and
  no replay. `DisplayRecoveryTests` cover journal permissions/archives/corruption
  and strict public restoration.
- `swift scripts/test-display-recovery.swift <built-panelctl>` is opt-in and
  **no-write**: live snapshot/rehearsal, deadline, parent SIGINT/SIGTERM/SIGKILL,
  helper SIGKILL, cross-journal contention and stale-boot refusal. It retains
  artifacts and does not request `guard`, `restore`, private calls or DDC.

On the TASK-5 validation host (2026-10-04), both products built and release-version
checks passed. The full suite failed three compositor-bounds assertions in the
unchanged `BlackoutGeometryTests.testWindowPlacementOnConnectedExternalScreens`;
that test reproduced the failure in isolation. The suite passed with that single
live-window test excluded. This is not a claim that the unfiltered suite is green.
Language-server diagnostics were unavailable (unknown), so compiler/tests supply
the validation evidence.

One independent safety review found that pre-staging intent could authorize
re-enable after a later unrelated disappearance. The correction requires durable
successful staging before private recovery. Regression tests kill the actual fake
helper before staging, then remove the target from the synthetic inventory and
verify startup refuses without a writer. Tests also cover staging-save failure
cancelling before commit and version-2 intent without staging evidence refusing.
The focused recovery filter passes 61 core tests (one opt-in symbol test skipped)
and one app test after the correction; the suite excluding the live-window test,
both builds, release checks and no-write subprocess checks were rerun successfully.

No fake test result establishes driver acceptance, monitor signal loss, input
switching, or restoration on actual hardware. Those remain separately approved
TASK-9/TASK-10 work.
