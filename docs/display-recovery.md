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

macOS may undo mirroring on wake. If the whole original layout came back
cleanly, the app mirrors each hidden display again, once, without switching
inputs. Anything unexpected is left alone and shown as needing recovery.

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
