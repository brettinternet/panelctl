# DDC input select

`panelctl ddc-input` reads or switches a monitor's input over DDC (VCP `0x60`)
on Apple Silicon. Use it to hand a multi-input monitor to another computer.

```sh
panelctl ddc-input --display UUID                 # read current input
panelctl ddc-input --display UUID --set hdmi1     # switch
panelctl ddc-input --display UUID --set 0x0F --json
```

| Name | `dp1` | `dp2` | `hdmi1` | `hdmi2` |
| --- | --- | --- | --- | --- |
| Value | `0x0F` | `0x10` | `0x11` | `0x12` |

Any value 1–255 also works. Monitors differ, so read the value first while on a
known input.

## Check support

```sh
panelctl probe --json
```

`probe` only reads input and brightness from each external display:

| Status | Meaning |
| --- | --- |
| `readable` | Valid reply |
| `noController` | No DDC service for this display |
| `ambiguousMapping` | Can't tell which DDC service belongs to it |
| `unsupported` | Monitor or macOS doesn't support it |
| `transportError` | Communication failed (see `detail`); may succeed later |
| `notApplicable` | Built-in, inactive or Intel |

Readable doesn't guarantee the monitor accepts writes.

## Behavior

```text
read current ─┬─ unreadable / ambiguous ─→ refuse
              ├─ already selected ───────→ alreadySelected
              └─ write once → poll 12 × 250 ms
                   ├─ reads requested ───→ verified
                   ├─ no reply ──────────→ unverified (check the monitor)
                   └─ reads other value ─→ error with a switch-back command
```

No retries, input cycling or power commands. `ddc-luminance` uses the same
read-first rule. If anything goes wrong, use the monitor's input button.

## Limits

macOS still treats the display as attached, so windows and the cursor can stay
on it. Use [away/back](display-handoff.md) to also remove the Mac desktop.

Switching back requires the monitor to accept DDC on the Mac's input while it
shows another one. This varies by monitor; some stop responding when the selected input has
no signal or enters standby.
