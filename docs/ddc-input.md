# DDC input select

`panelctl ddc-input` reads or switches a monitor's input (MCCS VCP `0x60`) over
the Apple Silicon IOAVService DDC transport used by `ddc-luminance`. It hands a
multi-input monitor to another computer without touching macOS display topology.

```sh
panelctl ddc-input --display UUID                 # read current input
panelctl ddc-input --display UUID --set hdmi1     # switch (one write)
panelctl ddc-input --display UUID --set 0x0F --json
```

| Name | `dp1` | `dp2` | `hdmi1` | `hdmi2` |
| --- | --- | --- | --- | --- |
| Value | `0x0F` | `0x10` | `0x11` | `0x12` |

Any value 1–255 (decimal or `0x` hex) also works. Monitors differ, so read the
value first while on a known input.

## Check readability first

```sh
panelctl probe --json
```

`probe` sends Get VCP for input (`0x60`) and luminance (`0x10`) to each active
external display on arm64. It never sends Set VCP, power or link commands.
Each display reports independent `input` and `luminance` statuses:

| Status | Meaning |
| --- | --- |
| `readable` | Valid reply |
| `noController` | No DDC service for this display |
| `ambiguousMapping` | Connector maps to more than one DCPAV service |
| `unsupported` | Missing symbol or explicit unsupported-VCP reply |
| `transportError` | I2C failure, timeout or invalid reply (see `detail`) |
| `notApplicable` | Built-in, inactive, offline or non-arm64; no channel opened |

A readable input does not prove the monitor accepts writes.

## Behavior

```text
read current ─┬─ unreadable / ambiguous ─→ refuse, no write
              ├─ already requested ──────→ alreadySelected, no write
              └─ write once → poll 12 × 250 ms
                   ├─ reads requested ───→ verified
                   ├─ no reply ──────────→ unverified (monitor likely left the Mac's input; check visually)
                   └─ reads other value ─→ error with a switch-back command
```

No automatic switching, retries, input cycling, power (`0xD6`) or link control.
The read-first and ambiguity refusals apply to `ddc-luminance` too. Use the
monitor's input button as the fallback.

## Limitations

macOS still treats the display as attached, so windows, cursor and Spaces stay
on it while it shows the other computer. Use [away/back](display-handoff.md) to
also hide the Mac desktop. Switching back from the Mac requires the monitor to
keep answering DDC on its DisplayPort input while showing HDMI; that varies by
monitor.

## Hardware results

Unit tests (`Tests/PanelCtlCoreTests/DDCTests.swift`) use a fake transport.
Hardware behavior is known only where observed.

**Probe, 2026-10-04** (macOS 27.0.1 `26A434`, arm64, read-only, no retries):

| Display | Input `0x60` | Luminance `0x10` |
| --- | --- | --- |
| DELL S2721DGF | transportError: invalid payload length | same |
| AW3425DW | readable | readable |
| K272HUL | readable | readable |
| Dell AW3423DW | transportError: IOReturn -535740416 | same |

A failure at one moment is not proof the display lacks DDC (the S2721DGF passed
the trial below the same day).

**Input switch, 2026-10-04**, DELL S2721DGF on DP, other computer on HDMI 1:

| Step | Result |
| --- | --- |
| Read on DP | `0x0F` |
| `--set hdmi1` | One write, `unverified` (readbacks invalid); other computer's picture appeared; macOS still listed the display online |
| Read while on HDMI | `0x11` over DP |
| `--set 0x0F` | One write, `verified`; Mac picture returned |

Qualified only for that monitor, ports, host and build, for one round trip.
Other monitors, sleep/wake and repeated switching are untested.
