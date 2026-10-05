# Experimental DDC monitor power

`panelctl ddc-power` is an explicit, CLI-only MCCS VCP `0xD6` operation on
Apple Silicon. Offline implementation and fake tests are complete; **no monitor
is power-qualified**. Input/luminance, mirroring and private-disconnect trials
are not power evidence. App integration is [planned, not shipped](display-hide-ux.md#planned-ddc-power-hide-style).

Power control is not input selection, desktop hiding or private disconnect.
Power-off alone need not remove the macOS desktop: windows and the pointer may
remain on an invisible screen. It does not promise signal loss, standby,
OLED maintenance, harmlessness or automatic restoration.

## Commands and consent

Only run these with a present user, accessible physical monitor power and
another usable display. Each real power read or write needs fresh, scoped
approval; examples and consent flags are not that approval.

```sh
panelctl ddc-power --display UUID                          # Get VCP only
panelctl ddc-power --display UUID --set off --accept-power-risk
panelctl ddc-power --display UUID --set on --json          # best effort only
```

`--accept-power-risk` explicitly acknowledges that software wake may fail, the
physical power button may not suffice, and unplugging monitor power may be
required. Neither harmlessness nor physical recovery is guaranteed. It is
required for every `--set off`, even if the monitor already reports Off.
Consent is checked before opening the transport, both in the parser and the
operation API. On also carries firmware risk; an explicit On command is not a
promise of recovery.

Use a freshly identified UUID from `panelctl list`, not a historical numeric
ID. One selector is required; there is no all-display operation. Resolution
requires an active, online external display, a valid unique UUID and unique CG
ID, and exactly one matching external controller. Missing/ambiguous identity
or controller mapping refuses before Set VCP. An absent wake target is not
rebound to another display or guessed ID. DDC support depends on the Mac,
monitor, port, adapter and firmware. Intel is unsupported.

## Supported values and evidence

[VESA MCCS 2.2a](https://files.lunar.fyi/mccs.pdf), dated 13 January 2011,
Table 8-9, page 70, defines `D6h` as non-continuous Power Mode:

| CLI name | Value | MCCS meaning |
| --- | --- | --- |
| `on` | `0x01` | DPM On / DPMS On |
| `off` | `0x04` | DPM Off / DPMS Off |

The standard says values `0x01`–`0x04` retain the appropriate DPM/DPMS protocol
response; that is **not** evidence this monitor remains reachable over DDC.
`0x02` is DPM Off / DPMS Standby, `0x03` is DPM Off / DPMS Suspend, and `0x05`
is a separate power-button-equivalent off command that may require user
intervention. None of those three values is exposed for writing. There is no
raw numeric/hex value, toggle, value sweep or alternate-value fallback.
Readings accept states `0x01`–`0x04`; reserved or invalid readings refuse.

[ddcctl issue 89](https://github.com/kfix/ddcctl/issues/89) reports physical-button
faults and an LG 27UL650-W requiring power removal after power commands. The
original report mixed power and another command; causality and permanent
damage are unproven. These reports still rule out promising software wake or
recovery using only the physical button.

## One-shot behavior and results

1. Resolve once and Get VCP `0xD6` once. Unsupported, unreadable or invalid
   state refuses before any Set VCP; even On requires this pre-read.
2. A read-only request returns `reported`. An already matching requested state
   returns `alreadyReported` without writing.
3. Otherwise send **one** Set VCP and perform **one** readback after 250 ms.
   The count and delay are bounded; the underlying OS I2C call has no
   application-enforced wall-clock timeout.

| Result | Meaning |
| --- | --- |
| `reported` | Read-only report; no power write |
| `alreadyReported` | Pre-read already matched; no power write |
| `matchingReadback` | One write, then a matching reported value |
| `unverified` | Write returned, but readback transport failed; visible state unknown |
| Error before Set VCP | No power write attempted; includes unreachable wake targets |
| Write error | One attempt; delivery/state unknown, no readback or retry |
| Readback error/mismatch | One write; unsupported/malformed/nonmatching reply, no retry |

A delivered command or matching readback is **not proof of visible panel state**.
JSON contains `displayID`, `uuid`, `original`, optional `requested` (name), optional
`observed`, `outcome` and `detail`. Exit 0 means one of the reported outcomes,
including `unverified`, not visible success. Exit 1 means refusal/error; 2 means
invalid CLI arguments. Errors go to stderr even with `--json`.

There is no journal, watchdog, automatic rollback, retry, wake command, or
restoration on exit. No startup, login, wake, probe, blackout, Hide/Show or
input-selection path issues power requests. Unattended power automation is
not supported. `probe` still queries only input and luminance.

## Manual recovery

Inspect the actual monitor, not just command output. Use its physical power
controls; unplugging its power supply may be required if the controls do not
work. Follow the manufacturer's handling instructions. Recovery is not
guaranteed. Stop after unexplained behavior; do not cycle values, guess IDs,
repeat writes automatically, or escalate to logout/reboot. An On request is
only an explicit best-effort attempt when the same target and DDC transport
remain available. Existing topology recovery cannot restore monitor power.

## Supervised qualification protocol

No trials have been performed for this feature. Record each field below, with
**not tested** rather than inferred success for omitted observations.

1. Record commit, host model/architecture, macOS version/build, monitor model,
   exact unit/serial/UUID, user-confirmed firmware, connection/port/adapters,
   selected input, monitor settings and initial usable output. Confirm the
   present user, another usable display and accessible physical power. Stop
   concurrent display tools/automation; review the above risks and manual plan.
2. Obtain approval for the exact target and a single power read. Record the
   exact command, timestamp, raw output and exit status. A successful read
   does not qualify writes.
3. Separately approve one `off` command. Record its output, reported values,
   visible behavior, LED/OSD, desktop presence and DDC loss independently.
4. If the same target remains resolvable, separately approve one best-effort
   `on` command; record actual usable output and readback separately. If absent,
   record refusal; do not guess a target or try alternate power values.
5. If needed, separately agree the physical recovery action with the user.
   Record whether the button worked, whether power removal was necessary and
   whether usable output returned. Do not claim physical recovery was tested
   merely because software On worked.
6. Stop on the first unexplained mismatch. Keep failures and untested steps in
   the record. Qualification applies only to that exact monitor/firmware/
   connection/host tuple and those commands; repeated reliability and other
   combinations remain unqualified. No extra cycle is implied by success.
