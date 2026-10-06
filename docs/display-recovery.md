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
| `recovery status` | No | Print the journal and every public-mirror removal as JSON (works with absent targets) |
| `recovery verify [--display UUID]` | No | Verify a public-mirror removal/session or exact restored baseline; resolves only proven system restorations |
| `recovery rehearse --timeout 5s` | No | Capture, start the helper, verify on deadline. Ends `verified`, **not** "safe to disconnect" |
| `recovery restore [--display UUID]` | **Yes** | Restore the selected public-mirror removal, or a legacy single snapshot, then verify |
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

## Public-mirror removal sessions

A v3 journal can contain one versioned public-mirror session with an immutable
pre-first-Hide baseline and independently identified removal entries. Each entry
records the full topology immediately before that target's operation before
any DDC or topology change. The existing file lock and atomic save cover the
baseline and all entries together; private-disable journals remain single
transactions and older mirror journals remain readable.

Healthy entries can be added with `mirror` or `away` while the session remains
verified. `recovery status` reports every target, source, operation state and
recovery reason. `back --display UUID` and `unmirror --display UUID` restore
only that target; other removals stay in their recorded mirror groups. The last
Show verifies the exact pre-first-Hide arrangement, modes and main display.
`recovery restore --display UUID` has the same selected-target behavior. A
selector is required when more than one entry is unresolved; unselected
multi-entry restore refuses without changing siblings. `recovery verify
--display UUID` is a read-only verification of the selected removal/session and
does not Show it. When exactly one entry is unresolved, `verify`/`restore` may
omit `--display`; explicit UUIDs are preferred. If a display becomes needs
attention or disconnects, new removals are blocked until it is repaired or
safely reconciled. Show never replays another target's operation.

macOS may restore a display on wake. PanelCtl resolves only an entry that
matches its recorded pre-operation or baseline topology; a disconnected or
ambiguous target retains its recovery entry. Failures during a new Hide or a
selected Show keep every sibling entry durable. Manual recovery must not edit
the journal; correct the exact identity/topology, then inspect status and run
selected `verify` or `restore` as documented. An exact pre-operation match
can retire an unchanged Hide as `cancelled` while other displays remain
removed; this does not claim its shifted coordinates match the original layout.
The last recovery entry is retained until the **whole** baseline verifies. If
a failed final Show has already cleared mirroring but left a mode or origin
wrong, explicit Show or selected `restore` can repair that layout after the
same identity checks; inspection and `verify` never retry the display writer.
A partial Show requests, but does not verify, the target's saved origin:
macOS may place it nearby while other displays are mirrored (see the
[multi-display trial](display-multi-removal-trial.md)). Its exact identity,
mode and main role, the other visible displays and the remaining removals are
verified against the durable pre-Show snapshot before input return; a mismatch
keeps recovery. A failed partial Show that already cleared its target's mirror
permits an explicit target-only repair, but only while those survivors and
sibling topology still verify. Do not retry repeatedly. An explicit
Show of the last physically mirrored target may restore the full baseline while
an earlier, already-separate target retains recovery. All other displays
must already be separate, and every entry stays unresolved until the entire
baseline verifies. Only the selected target's input is switched; return other
inputs separately with explicit consent or monitor buttons.

### App sleep/wake handling

For a public-mirror session that is healthy and fully verified before PanelCtl
observes a system or screen sleep, the app keeps a session-only resume intent in
memory. After `screensDidWake` and a 1-second settle, it inspects the journal. A
new sleep notification cancels that settle, clears the awake flag and preserves
the original intent until a later screen wake. The baseline token is a stable
projection of topology and identity fields: capture timestamps, localized names,
host labels and diagnostic identity provenance do not participate. The saved
baseline is still checked with `RecoverySnapshot.verify`, which requires exact
identity, profile compatibility, modes, main/active roles, origins and mirror
relationships.

The app re-applies each removal that was still hidden before sleep through the
existing public mirroring path only if the same journal/session token, baseline,
captured target/source UUIDs, numeric IDs and hardware identities still match,
every target/source is present and awake, and inspection proves the complete
baseline was restored. The expected journal, session, baseline and observed
topology are checked again under the core operation/journal locks and at
transaction revalidation boundaries before staging and commit. A still-healthy
hidden topology is left alone; entries already restored before sleep stay
restored. Reapplication is one attempt per observed sleep cycle and never
switches monitor inputs or replays DDC. These locks do not serialize unrelated
display managers or macOS; a post-commit mismatch remains journaled recovery,
not success.

This is not startup/login recovery: intent is not persisted, so quitting or
relaunching while asleep loses it. Missing, changed, ambiguous, partially
restored or interrupted-Show state, a source that is not awake, or uncertain
wake ordering refuses automatic re-hide and keeps recovery evidence. Other
monitor/topology changes do not trigger it. Displays → Restore offers the
existing guarded Show/recovery path for a public removal even when inspection
reports `needsAttention`; core identity and topology checks remain mandatory.
For a multi-removal wake reset with all targets separate and captured identities
intact, selecting Restore can restore and verify the full saved baseline. If
that action is refused, keep the journal, use System Settings → Displays to
correct the arrangement, then Check Again and inspect the journal. No private
setter, automatic DDC, global reset or reboot is involved.

Private disable refuses while any public removal is unresolved, and a public
removal refuses while a private-disable journal is unresolved. Legacy
single-display mirror journals retain their original Show/recovery behavior.

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
snapshot or selected removal in `needsAttention`; after fixing things by hand,
run `verify` with `--display UUID` when several entries remain. A single legacy
snapshot is resolved only when its full exact baseline verifies.
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
Public mirror tests exercise two- and three-target Show permutations, shared
and distinct sources, main-target reassignment, observed macOS rearrangement,
write interruption, disconnect, wake self-restoration, status selection and
exact final-baseline verification with fake topologies and writers. They do not
qualify live multi-display combinations or authorize any topology/DDC write.

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
