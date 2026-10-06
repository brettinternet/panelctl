# Experimental DDC power

`panelctl ddc-power` turns a monitor off or on over DDC (VCP `0xD6`) on Apple
Silicon. It is CLI-only and experimental.

> [!WARNING]
> Some monitors stop accepting DDC once off, and some need their power cable
> unplugged to recover. Run this only with another working display and the
> monitor's power within reach.

```sh
panelctl ddc-power --display UUID                                # read only
panelctl ddc-power --display UUID --set off --accept-power-risk
panelctl ddc-power --display UUID --set on --json                # best effort
```

Power is not input switching or hiding: after Off, the macOS desktop may still
extend onto the dark screen.

| Name | Value | MCCS meaning |
| --- | --- | --- |
| `on` | `0x01` | DPM On |
| `off` | `0x04` | DPM Off |

Only these two values can be written. Standby (`0x02`), suspend (`0x03`) and
power-button off (`0x05`) are not exposed.

## Behavior

1. Find exactly one matching external display, or refuse.
2. Read the current power state. Refuse if unreadable.
3. If it already matches, stop. Otherwise write once and read back once after
   250 ms.

| Result | Meaning |
| --- | --- |
| `reported` | Read only |
| `alreadyReported` | Already in that state; no write |
| `matchingReadback` | Wrote, and the monitor reports the new state |
| `unverified` | Wrote, but the readback failed |
| Error | Refused before writing, or the write or readback failed |

A matching readback doesn't prove the panel is actually off or on; look at it.
Exit 0 means one of the results above, 1 a refusal or error, 2 invalid
arguments.

Nothing retries, restores on exit or runs automatically. Blackout, Hide/Show,
probe and input switching never send power commands.

## Recovery

1. If the same display is still listed, try `--set on`.
2. Use the monitor's power button.
3. Unplug the monitor's power, wait, and plug it back in.

Don't cycle other values or repeat commands in a loop. Display recovery
journals can't restore monitor power.

## References

- [VESA MCCS 2.2a](https://files.lunar.fyi/mccs.pdf), Table 8-9
- [ddcctl #89](https://github.com/kfix/ddcctl/issues/89): monitors needing
  power removal after power commands
