# Display recovery groundwork

This tooling prepares for future private display-control experiments. **It does
not disable displays, reconnect privately disconnected displays, or qualify a
private API as safe.** Rehearsal is deliberately verification-only.

## Commands

Run from the logged-in console user's GUI session:

```sh
panelctl recovery capture
panelctl recovery status
panelctl recovery verify
panelctl recovery rehearse --timeout 5s
```

`capture` records all online displays and writes a versioned journal. `status`
prints it as JSON. `verify` compares the current configuration without changing
it. `rehearse` captures a new baseline and starts a separate verification helper,
then waits. The helper verifies on its deadline or when the parent disappears.
A successful rehearsal ends in `verified`, **not** "safe to disconnect."

An unresolved capture blocks the next capture/rehearsal: verify or restore it
first. A resolved journal is archived alongside the next capture, not deleted.
The default location is:

```text
~/Library/Application Support/PanelCtl/Recovery/current.json
```

Every action accepts `--journal <path>`. Its parent directory must be owned by
you, mode `0700`, and not a symlink. New directories are created privately.
Journals are mode `0600`. A per-user operation lock serializes recovery actions
and helpers even with different custom journals; each journal also has a lock.
Other display utilities do not participate in these locks.

### Explicit restoration

```sh
panelctl recovery restore
```

This action **can change display configuration**, as can the timed `guard`
described below. It restores public display modes, origins, and mirroring with session scope,
then compares the result with the original snapshot. An already matching
configuration is a no-op. It never writes a permanent display configuration.

Restoration refuses missing/additional/ambiguous displays, changed numeric IDs,
changed hardware identity or connector, changed rotation or captured color-space/
ICC profile identity, another boot/OS build/user, an unavailable exact mode, or concurrent
configuration changes detected before commit. It does not search arbitrary IDs,
change power, reset firmware, restart WindowServer, delete preferences, or reboot.
Failures retain the baseline in `needsAttention` with a diagnostic. After manual
recovery, `verify` can resolve it without a write. There is no force/discard flag.

If the OS/boot changed, verification also refuses the old journal. Keep that
journal as evidence; use a new private `--journal` location for a new baseline.
Do not edit its identity fields to bypass the guard.

### Timed public-configuration guard

```sh
panelctl recovery guard --timeout 15s
```

The CLI captures a fresh baseline, waits for the independent helper's READY
handshake, reports that it is armed, then waits. The helper runs the same restore
and verify pipeline on deadline, parent exit (including SIGKILL), or a handled
signal. It retains failures rather than repeatedly issuing writes. An unchanged
configuration needs no write.

This guard is useful groundwork, **not protection for disconnect experiments**:
if a display vanishes, recovery reports `needsAttention` rather than attempting
private reconnection. Explicit restore/guard may flicker displays or move windows.
Do not change HDR, color profiles, or rotation under this guard; they are not
restored. Another display utility can still race it. No state-changing private
call is authorized by a successful guard startup.

## What the snapshot means

Captured: OS build, boot-session UUID, user ID, display UUID and CG ID,
vendor/model/serial, built-in/main/active flags, exact mode attributes and ID,
refresh rate, origin, rotation, mirror-source UUID, optional color-space name and
SHA-256 of the readable ICC data, and optional `IODisplayLocation` from CoreDisplay metadata. The latter works on
the investigated host's `IOMobileFramebufferShim` path without assuming an
`AppleCLCD2` service exists.

Not captured/restored: HDR enablement, VRR policy beyond the mode's reported
refresh rate, full color profiles/calibration, DDC brightness/power/input state,
application window placement, Spaces, or OLED maintenance state. A missing
color-space/profile identity or connector is unknown, not proof of equality or safety.
Rotation is captured/checked but not written. The current restore implementation
requires all original displays online; retained IDs are evidence, not permission
to operate on offline or recycled IDs.

## Watchdog contract

- The parent writes and synchronizes the baseline before launching a helper
  from the same executable. The helper locks the journal, verifies the baseline
  and exact mode availability without writes, arms an event-driven deadline/
  parent-pipe watcher, synchronizes `armed`, and
  sends a bounded READY handshake. Startup failures never authorize mutation.
- Foundation starts a separate process group; the helper checks isolation.
  Closing the parent lease (including parent SIGKILL) triggers early checking.
  The helper does not inherit terminal output; diagnostics live in the journal.
- Timeout is 1–60 seconds (default 5). The elapsed timer is monotonic after
  startup. Sleep can delay execution; there is no wall-clock recovery guarantee.
- `rehearse` journals have `verifyOnly: true`; the helper never calls the writer
  for them. `guard` journals use the public restoration writer. No shell-command
  hook or private control backend exists. The internal `_recovery-helper` entry
  point is not a standalone recovery command. The recorded helper PID is for
  diagnostics only; recovery never signals a PID loaded from a journal.
- The helper cannot survive its own SIGKILL, logout, reboot, or a hung/crashed
  WindowServer/driver. Readiness is an acknowledgment, not a lifetime guarantee.

## Required before adding a disable API

1. Implement and independently qualify missing-display identification and a
   narrowly targeted re-enable backend. Do not relax current identity checks
   just to get an enable call through. An unavailable identity must block.
2. Add a mutation preflight that permits only one explicitly selected non-main
   external display and proves another usable **physical** screen remains.
   Online-count, UUID, and `builtin == false` alone do not prove this.
3. Integrate the mutation with the existing READY/lease protocol, revalidate
   readiness and topology immediately before mutation, and cover the remaining
   crash/race windows. Extend the restoration backend to handle the specific
   private operation without weakening identity checks. Do not bypass the
   helper or treat its PID/readiness acknowledgment as lasting proof of health.
4. Qualify restoration of actual hardware modes/mirroring and asynchronous
   convergence. Current immediate verification may conservatively report
   `needsAttention` while macOS is still settling; it does not retry writes.
5. Address HDR/color/rotation limitations, and agree with the user on acceptable
   physical recovery (replug/reboot) before any state-changing private call.

See [the research and risk assessment](undocumented-display-control.md).

## Validation

See the [implementation validation checkpoint](recovery-validation.md) for
executed checks and unqualified behavior.

`swift test --filter DisplayRecoveryTests` exercises journal locking, archives,
permissions, corruption, identity rejection, write-ahead ordering, failed writes,
verification failure, idempotence, and strict CLI parsing using fake displays.
The full `swift test` suite also exercises the existing app/CLI behavior.
The restoration pipeline is tested with a fake writer, not a live topology change.
For opt-in **no-write** subprocess checks, build the CLI and pass its path:

```sh
swift build --product panelctl
swift scripts/test-display-recovery.swift /absolute/path/to/built/panelctl
```

Use `swift build --show-bin-path` to locate it. The script tests live snapshotting,
deadline verification, parent SIGKILL/EOF recovery, operation-lock contention,
helper SIGKILL with retained evidence, and stale-boot rejection. It never invokes `guard` or `restore`, and retains
private temporary artifacts at the printed path. It requires a GUI console session.
