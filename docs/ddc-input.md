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
| Date, host, macOS build | not yet run |
| Monitor, firmware, connection | DELL S2721DGF; DP from this Mac; other computer on HDMI (to confirm) |
| Selector used | UUID from fresh `panelctl list` |
| Current input read on DP | not yet run |
| `--set hdmi1` outcome, visible result | not yet run |
| Readback while on HDMI | not yet run |
| Switch back to DP from the Mac | not yet run |
| Fallback needed | not yet run |
| Verdict | unqualified |
