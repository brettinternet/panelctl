# DDC input select (TASK-10)

`panelctl ddc-input` reads or switches a monitor's input source using MCCS VCP
`0x60` over the existing Apple Silicon IOAVService DDC transport that
`ddc-luminance` already uses. It is the standalone way to hand a multi-input
monitor to another computer without the private display-disable path.

```sh
panelctl ddc-input --display <selector>                  # read current input
panelctl ddc-input --display <selector> --set hdmi1      # switch (one write)
panelctl ddc-input --display <selector> --set 0x0F --json
```

Names map to common MCCS values: `dp1`=0x0F, `dp2`=0x10, `hdmi1`=0x11,
`hdmi2`=0x12. Numeric values 1–255 (decimal or `0x` hex) are also accepted.
Monitors differ, so read the value first while you are on a known input.

## Check readability first

`panelctl probe` (or `--json`) now sends Get VCP requests for input (`0x60`)
and luminance (`0x10`) to each active online external display on arm64. It never
sends Set VCP, power, or link-control commands. Get VCP uses an I2C request write
followed by a reply read; it does not set monitor values.

Text output and the JSON `ddc` array identify each display by `displayID` and
report independent `input`/`luminance` statuses: `readable`, `noController`,
`ambiguousMapping`, `unsupported`, or `transportError`, with failure `detail`.
Built-in/inactive/offline displays and non-arm64 hosts report `notApplicable`
without opening a channel. A feature or display failure does not stop other
reads. Missing metadata and invalid replies are reported as transport errors;
`unsupported` means a missing required symbol or explicit unsupported VCP reply,
not a guess based on a timeout. No retry or write qualification is performed.

**A successful read is not write qualification.** Request user approval before
running this hardware probe during agent work. See [feasibility](feasibility.md)
for dated observations; historical results are not fresh probe results.

## Behavior

- **Explicit only.** Nothing switches automatically. There is no retry, no
  cycling through inputs, and no power (`0xD6`) or link control.
- **Read first.** If the current input can't be read (DDC unsupported,
  unsupported-feature reply, or transport failure), the command refuses
  before writing. If the display's connector maps to more than one external
  DCPAV service, it also refuses. This now applies to `ddc-luminance` too.
- **Already selected:** no write is sent; outcome `alreadySelected`.
- **One write**, then read-only polling (12 × 250 ms) to check the result:
  - `verified`: a readback reports the requested input.
  - `unverified`: no readback succeeded after the write. This is expected
    when the monitor stops answering DDC once it leaves the Mac's input. The
    switch probably happened; check visually.
  - A readback of some other input is an error that includes a switch-back
    command. Use the monitor's input button as the fallback.
- The input value is the low byte of the reply. Non-continuous replies are not
  checked against the reported maximum.

## Limitations

This switches the monitor's input only. macOS still treats the display as
attached, so windows, the cursor and Spaces stay on it while it shows the
other computer. It is not a display disable and is not reported as one. If the
display must leave the macOS topology, that remains TASK-12 and then TASK-9.

Switching back from the Mac requires the monitor to keep accepting DDC on its
DisplayPort input while it shows HDMI. That varies by monitor and has to be
observed.

## Qualification record

Fake-transport tests (`Tests/PanelCtlCoreTests/DDCTests.swift`) cover
encoding, reply parsing, unsupported features, transport loss, ambiguous
mapping, readback mismatch and already-selected. Hardware behavior is
unqualified until a supervised trial is recorded below. Only observed results
belong here.

| Field | Observation |
| --- | --- |
| Date, host, macOS build | 2026-10-04, this Apple Silicon Mac, macOS build `26A434`; supervised, user present, scoped consent recorded in TASK-10 |
| Monitor, firmware, connection | DELL S2721DGF (vendor 4268, model 16857, non-main, portrait); DP from this Mac; other computer on HDMI 1; firmware not recorded |
| Selector used | UUID `09084682-3C42-4455-AAB8-126A7431125B` from a fresh `panelctl list` |
| Current input read on DP | `0x0F` (dp1), matches the MCCS default |
| `--set hdmi1` outcome, visible result | One write; outcome `unverified`. Every readback in the 3 s window was an invalid reply ("not a Get VCP Feature reply"). User saw the other computer's picture. macOS still listed the display as active and online. |
| Readback while on HDMI | Later, still on HDMI, the Mac read `0x11` over DP |
| Switch back to DP from the Mac | `--set 0x0F`: one write; outcome `verified` (read back `0x0F`). User confirmed the Mac's picture returned. |
| Fallback needed | No; the monitor's input button was not used |
| Verdict | **Qualified for this tuple only**: S2721DGF on DP plus HDMI 1, this host and build, one round trip. Other monitors, ports, builds, sleep/wake and repeated switching are unqualified. Window placement during HDMI was not observed. |
