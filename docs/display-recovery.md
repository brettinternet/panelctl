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
Journals are mode `0600`. Locking is per journal: different custom journals do
not coordinate with each other or with other display utilities.

### Explicit restoration

```sh
panelctl recovery restore
```

This is the **only user-facing action that can change display configuration**.
It restores public display modes, origins, and mirroring with session scope,
then compares the result with the original snapshot. An already matching
configuration is a no-op. It never writes a permanent display configuration.

Restoration refuses missing/additional/ambiguous displays, changed numeric IDs,
changed hardware identity or connector, changed rotation or captured color-space
name, another boot/OS build/user, an unavailable exact mode, or concurrent
configuration changes detected before commit. It does not search arbitrary IDs,
change power, reset firmware, restart WindowServer, delete preferences, or reboot.
Failures retain the baseline in `needsAttention` with a diagnostic. After manual
recovery, `verify` can resolve it without a write. There is no force/discard flag.

If the OS/boot changed, verification also refuses the old journal. Keep that
journal as evidence; use a new private `--journal` location for a new baseline.
Do not edit its identity fields to bypass the guard.

## What the snapshot means

Captured: OS build, boot-session UUID, user ID, display UUID and CG ID,
vendor/model/serial, built-in/main/active flags, exact mode attributes and ID,
refresh rate, origin, rotation, mirror-source UUID, optional color-space name,
and optional `IODisplayLocation` from CoreDisplay metadata. The latter works on
the investigated host's `IOMobileFramebufferShim` path without assuming an
`AppleCLCD2` service exists.

Not captured/restored: HDR enablement, VRR policy beyond the mode's reported
refresh rate, full color profiles/calibration, DDC brightness/power/input state,
application window placement, Spaces, or OLED maintenance state. A missing
color-space name or connector is unknown, not proof of equality or safety.
Rotation is captured/checked but not written. The current restore implementation
requires all original displays online; retained IDs are evidence, not permission
to operate on offline or recycled IDs.

## Watchdog contract

- The parent writes and synchronizes the baseline before launching a helper
  from the same executable. The helper locks the journal, verifies the baseline,
  arms an event-driven deadline/parent-pipe watcher, synchronizes `armed`, and
  sends a bounded READY handshake. Startup failures never authorize mutation.
- Foundation starts a separate process group; the helper checks isolation.
  Closing the parent lease (including parent SIGKILL) triggers early checking.
  The helper does not inherit terminal output; diagnostics live in the journal.
- Timeout is 1–60 seconds (default 5). The elapsed timer is monotonic after
  startup. Sleep can delay execution; there is no wall-clock recovery guarantee.
- Only `verifyOnly` journals are accepted by this helper. There is no live arm
  command or shell-command hook. The internal `_recovery-helper` entry point is
  not a standalone recovery command.
- The helper cannot survive its own SIGKILL, logout, reboot, or a hung/crashed
  WindowServer/driver. Readiness is an acknowledgment, not a lifetime guarantee.

## Required before adding a disable API

1. Implement and independently qualify missing-display identification and a
   narrowly targeted re-enable backend. Do not relax current identity checks
   just to get an enable call through. An unavailable identity must block.
2. Add a mutation preflight that permits only one explicitly selected non-main
   external display and proves another usable **physical** screen remains.
   Online-count, UUID, and `builtin == false` alone do not prove this.
3. Establish a real arming/operation protocol, including ownership across all
   journals, readiness revalidation, crash windows, topology-change detection,
   and a bounded restore path. Do not change the rehearsal helper into a writer
   merely by flipping its `verifyOnly` field.
4. Qualify restoration of actual hardware modes/mirroring and asynchronous
   convergence. Current immediate verification may conservatively report
   `needsAttention` while macOS is still settling; it does not retry writes.
5. Address HDR/color/rotation limitations, and agree with the user on acceptable
   physical recovery (replug/reboot) before any state-changing private call.

See [the research and risk assessment](undocumented-display-control.md).

## Validation

`swift test --filter DisplayRecoveryTests` exercises journal locking, archives,
permissions, corruption, identity rejection, write-ahead ordering, failed writes,
verification failure, idempotence, and strict CLI parsing using fake displays.
The full `swift test` suite also exercises the existing app/CLI behavior.
No test of the public restoration writer changes real display configuration.
