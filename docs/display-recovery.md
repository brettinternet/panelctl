# Display recovery

Before changing the display layout, PanelCtl saves it to a journal so it can
verify and restore it later. [Mirroring](display-mirroring.md),
[handoff](display-handoff.md), app Hide/Show and
[private disable](display-disable.md) share this journal.

## Commands

Run these from your logged-in desktop session.

| Command | Changes displays? | Effect |
| --- | --- | --- |
| `recovery status` | No | Print the journal and every removed display as JSON |
| `recovery verify [--display UUID]` | No | Check the current layout against the journal |
| `recovery capture` | No | Save the current layout |
| `recovery rehearse --timeout 5s` | No | Save, start the helper, verify at the deadline |
| `recovery restore [--display UUID]` | **Yes** | Restore one removed display (or a saved layout), then verify |
| `recovery guard --timeout 15s` | **Yes** | Save, then restore on deadline, exit or signal |

```text
~/Library/Application Support/PanelCtl/Recovery/current.json   # default --journal
```

- A custom journal's folder must be yours, mode `0700`, not a symlink.
- An unresolved journal blocks the next capture; verify or restore it first.
  Resolved journals are archived, never deleted.
- `--display` is required when more than one display is removed.
- Exit 2 for bad arguments, 1 for refusals or failures.

## Restore

```text
already matches → no-op
otherwise       → one write → up to 6 checks, 200 ms apart → verified | needsAttention
```

Restore refuses, without writing, when:

- displays are missing, extra or ambiguous, or an ID changed
- a display's hardware identity, connector, rotation or color profile changed
- the Mac rebooted, changed OS build or switched user
- a saved mode is no longer available

It never retries, guesses IDs, resets firmware, writes permanent configuration
or reboots. There is no force flag. Fix the cause by hand, then run
`recovery verify`. If the Mac rebooted, keep the old journal and use a new
`--journal` path.

If restore can't succeed, turn off mirroring in **System Settings → Displays**,
drag the menu bar back to the original display, then run `recovery verify`.

## Multiple removed displays

```sh
panelctl recovery status
panelctl recovery verify --display UUID
panelctl recovery restore --display UUID
```

Each removed display has its own entry. Restoring one leaves the others
removed. While others are removed, macOS may place it slightly off its saved
position; the last restore verifies the exact original layout and main display.
A display that needs attention blocks new removals until it's fixed.

## Sleep, wake and reboot

macOS may undo mirroring on wake and return an off-input monitor late, with a
changed main display or arrangement. The running app retains the set verified
hidden before sleep and waits up to 15 seconds for those displays to return.
If the original layout came back exactly, it mirrors the hidden displays again.
For a multi-display journal with layout drift, it reapplies the captured mirrors
and saved visible-display origins/main together in one session transaction.
It never switches inputs on wake. Follower modes are negotiated by mirroring;
a missing saved follower mode does not prevent re-hide, but still blocks Show
until that exact mode returns. The original layout and modes remain journaled.

Changed identities, unrelated mirrors, changed visible-display modes, interrupted
Show operations or failed verification remain in recovery. There is no write
retry, and explicit Hide/Show cancels pending wake resume. Resume requires intent
captured by this running app before sleep; relaunch never starts it. A monitor
that returns after the bounded window still needs explicit recovery. This path
is covered by fake-writer regressions; live monitor/driver acceptance and timing
remain hardware-validation limits.

A monitor on another computer's input may reconnect with a reduced mode list
(for example, 60 Hz instead of the saved 240 Hz). Explicit app **Show** or
`back --input` validates the captured identities, attempts the configured Mac
input once, waits for modes/topology to settle, then restores and verifies the
journaled desktop. This input-return path accepts online mirror followers that
macOS marks inactive; ordinary DDC controls remain active-only. Identity and
connector checks still apply, and the monitor must accept DDC on the Mac's link.
Returning to mirroring alone does not count as shown.
Without a configured return input, use the monitor's input button first.

Recovery reports the current identity, lifecycle or exact saved-mode blocker
rather than hiding it behind an earlier generic layout error. Failed restoration
retains the unresolved journal. An online display is not evidence that its Mac
input is selected and never causes automatic Show or an input write.

Hide is session-only: after logout or reboot, macOS loads its own layout. If
macOS brings back a mirror itself, PanelCtl shows that display as **Mirrored**;
turn off mirroring in System Settings → Displays.

## Snapshot

| Saved | Not saved or restored |
| --- | --- |
| OS build, boot session, user, host model | HDR, variable refresh |
| UUID, display ID, vendor/model/serial | Color calibration |
| Main, active and built-in flags | DDC brightness, power or input |
| Mode, refresh rate, position, rotation (checked only) | Windows and Spaces |
| Mirror source | |
| Color space and ICC profile digests | |
| Connection and transport details | |

ICC profiles that differ only in their creation date (bytes 24–35) still match.

## Helper

`rehearse`, `guard` and private disable start a helper process that outlives
the command:

```text
parent: save journal → start helper → wait for READY
helper: lock journal → verify → arm deadline → READY
        … deadline, parent exit (even SIGKILL) or signal → verify (rehearse) | restore (guard)
```

The timeout is 1–60 seconds. The helper can't survive its own SIGKILL, logout,
reboot, or a hung WindowServer.

## Testing

```sh
swift test --disable-sandbox --filter DisplayRecoveryTests
```

Opt-in checks against a built CLI that never change displays (needs a desktop
session):

```sh
swift build --product panelctl
swift scripts/test-display-recovery.swift "$(swift build --show-bin-path)/panelctl"
```

The script covers capture, deadline verification, parent and helper signals,
lock contention and stale-boot refusal. It never runs `guard` or `restore`.
