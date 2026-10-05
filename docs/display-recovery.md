# Display recovery

A versioned journal records the display topology before any change so it can be
verified and restored later. [Mirroring](display-mirroring.md),
[handoff](display-handoff.md), the app's Hide/Show and the experimental
[private disable](display-disable.md) all share it.

## Commands

Run from the logged-in console user's GUI session.

| Command | Writes displays? | Effect |
| --- | --- | --- |
| `recovery capture` | No | Snapshot all online displays into the journal |
| `recovery status` | No | Print the journal as JSON (works with absent targets) |
| `recovery verify` | No | Compare current topology with the snapshot; resolves the journal on match |
| `recovery rehearse --timeout 5s` | No | Capture, start the helper, verify on deadline. Ends `verified`, **not** "safe to disconnect" |
| `recovery restore` | **Yes** | Restore public modes, origins and mirroring (session scope), then verify |
| `recovery guard --timeout 15s` | **Yes** | Capture, arm the helper, restore + verify on deadline, parent exit or signal |

All accept `--journal <path>`. Default:

```text
~/Library/Application Support/PanelCtl/Recovery/current.json
```

- Parent directory: owned by you, mode `0700`, not a symlink. Journals: `0600`.
- An unresolved journal blocks the next capture. Verify or restore it first.
  Resolved journals are archived by the next capture, never deleted.
- A per-user operation lock serializes all recovery actions, even across custom
  journals; each journal has its own lock too. Other display apps ignore both.
- Parse errors exit 2; unsafe or failed operations exit 1.

## Restore

```text
already matches ──→ no-op
otherwise ────────→ one session-scoped write → up to 6 reads, 200 ms apart → verified | needsAttention
```

Restore restores and verifies the captured main display as well as modes,
origins and mirroring. A main-target mirror may be reported with a different
main display while hidden; that is not by itself recovery-needed when the exact
target/source relationship and other captured checks match. Restoration still
requires the exact captured main flag, arrangement and modes. If a main-target
restore does not verify, keep the journal, turn off mirroring and drag the menu
bar back to the original display in System Settings → Displays; do not report
success or discard evidence. One [main-target CLI cycle](display-mirroring.md#observed-main-target-cycle-2026-10-05)
restored AW3423DW from mirroring onto AW3425DW and passed exact verification;
other combinations remain unqualified.

Restore refuses, without writing, on any of:

- missing, extra or ambiguous displays, or a changed numeric ID
- changed hardware identity, connector, rotation, color space or ICC profile
- a different boot, OS build or user
- an unavailable exact mode, or a configuration change detected before commit

It never retries writes, searches IDs, changes power, resets firmware, restarts
WindowServer, deletes preferences, writes permanent configuration or reboots.
A `verifyOnly` journal (from `rehearse`) can't be restored. Failures keep the
snapshot in `needsAttention`; after fixing things by hand, `verify` resolves it.
There is no force or discard flag. If the boot or OS changed, keep the old
journal as evidence and use a new `--journal` path; never edit its identity
fields.

`guard` is not protection for disconnect experiments: a vanished display
becomes `needsAttention`, not a reconnect. Restore and guard can flicker displays
and move windows. Don't change HDR, color profiles or rotation under a guard.

## Snapshot

| Captured | Not captured or restored |
| --- | --- |
| OS build, boot session, user, host model | HDR, VRR beyond the mode's refresh rate |
| UUID, CG ID, vendor/model/serial | Full color calibration |
| Built-in, main, active flags | DDC brightness, power or input |
| Exact mode, refresh rate, origin, rotation (checked, not written) | Window placement, Spaces |
| Mirror source UUID | OLED maintenance state |
| Color space name, ICC digests | |
| IOKit transport, type, location, HPD; CoreDisplay `IODisplayLocation` as `connector` | |

`connector` is the CoreDisplay location, `nil` in public mirror captures. The
IOKit transport location is a separate field. Missing values are unknown, not
equal. Restore requires every original display online; a retained ID is
evidence, not permission to touch an offline or recycled ID.

**ICC profiles.** Regenerated profiles can differ only in creation-time bytes
24–35. If both snapshots carry a date-independent digest (computed after v2/v4
display-profile, date, tag-table and zero profile-ID checks), those bytes are
ignored; every other byte is still compared. Older journals without the digest
stay raw-hash strict.

## Helper

`rehearse`, `guard` and private disable use a helper process started from the
same executable:

```text
parent: write + fsync baseline → launch helper ──────────────→ wait for READY → report armed
helper: lock journal → verify baseline, modes → arm deadline + parent pipe → save "armed" → READY
        ... deadline, parent exit (even SIGKILL) or signal → verify (rehearse) | restore + verify (guard)
```

- Separate process group with no terminal output; diagnostics go to the journal.
- Timeout 1–60 s (default 5), on a monotonic clock. Sleep can delay it.
- Startup failure never authorizes a write. READY is an acknowledgment, not a
  lifetime guarantee. The recorded PID is diagnostic; recovery never signals it.
- `_recovery-helper` is internal, not a user command.
- The helper can't survive its own SIGKILL, logout, reboot, or a hung
  WindowServer or driver.

## Testing

`swift test --filter DisplayRecoveryTests` covers locking, archives,
permissions, corruption, identity rejection, write-ahead ordering, failed
writes, verification failure, idempotence and CLI parsing with fake displays.
Public mirror tests also exercise main-target main reassignment and exact-main
restoration using fake topologies and writers; no live main-target trial is
qualified by offline tests.

Opt-in **no-write** subprocess checks against a built CLI (GUI session
required):

```sh
swift build --product panelctl
swift scripts/test-display-recovery.swift "$(swift build --show-bin-path)/panelctl"
```

The script exercises live capture, deadline verification, parent
SIGINT/SIGTERM/SIGKILL, operation-lock contention, helper SIGKILL with retained
evidence and stale-boot refusal. It never runs `guard`, `restore` or private
calls, and keeps its temporary artifacts at the printed path.
