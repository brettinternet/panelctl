# Controlling one display on macOS

macOS has no public API that sleeps or disconnects one external display while
others stay on. These are the options:

| Approach | Desktop stays | Result | PanelCtl |
| --- | --- | --- | --- |
| Black window | Yes | OLED pixels unlit; monitor stays on | Blackout, Hide (black out) |
| Translucent overlay | Yes | Dimmer; pixels may stay lit | Working-mode blackout |
| DDC brightness | Yes | Hardware brightness lowered | `--dim-to`, `ddc-luminance` |
| Public mirroring | No | Separate desktop removed; signal stays | [Mirroring](display-mirroring.md) (experimental) |
| Private disable | No | Signal dropped; monitor may switch input | [Display disable](display-disable.md) (experimental) |
| DDC power | Usually | Monitor firmware decides | [DDC power](ddc-power.md) (experimental, CLI) |
| Sleep all displays | — | Every monitor enters standby | `sleep-displays` |

For long idle periods, sleep every display: many OLED monitors run panel
maintenance (such as pixel refresh) only in standby. A black window leaves
pixels unlit
([Samsung Display](https://oledera.samsungdisplay.com/eng/oled/)), but the
monitor stays on.

## APIs

**Public Core Graphics.** [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services)
lists displays and sets modes, positions and mirroring. `CGDisplayIsAsleep` is
read-only; there is no per-display sleep or disconnect.

**Private topology.** `CGSConfigureDisplayEnabled` / `SLSConfigureDisplayEnabled`
remove a display from the layout. They have no header or compatibility promise.
A common bug: tools look the display up in `CGGetOnlineDisplayList` to
re-enable it, but disabling removes it from that list
([displayplacer #109](https://github.com/jakehilborn/displayplacer/issues/109),
[#126](https://github.com/jakehilborn/displayplacer/issues/126),
[#137](https://github.com/jakehilborn/displayplacer/issues/137)). PanelCtl saves
the ID first.

**IOKit and DisplayServices.** IOKit power keys don't control arbitrary
external monitors. DisplayServices has power and brightness functions with no
external-monitor contract.

**DDC/CI.** Apple Silicon tools use private `IOAVServiceReadI2C` /
`WriteI2C` ([m1ddc](https://github.com/waydabber/m1ddc)). Support varies by
Mac, port, adapter and monitor. VCP codes: brightness `0x10`, input `0x60`,
power `0xD6`. A successful read doesn't make a write safe (see Microsoft's
[`SetVCPFeature`](https://learn.microsoft.com/en-us/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-setvcpfeature)
warning), and power commands have left some monitors needing power removal
([ddcctl #89](https://github.com/kfix/ddcctl/issues/89)).

## Other private methods

| Method | Concern | Status |
| --- | --- | --- |
| `IOAVServiceStopLink` / `StartLink` | Unknown signatures and side effects | Not used |
| `DisplayServicesSetPowerMode` | No external-monitor restore contract | Not used |

Related: [Lunar](https://lunar.fyi/faq) ships a disconnect feature on Apple
Silicon. macOS can create a headless virtual display that counts as online, so
an online count doesn't prove a usable screen remains
([BetterDisplay #1623](https://github.com/waydabber/BetterDisplay/issues/1623)).
See also the [tool survey](display-disable-tool-survey.md).

## Check your setup

```sh
panelctl list
panelctl probe --json      # DDC reads only
```

EDID power flags are advertised capabilities, not guarantees, and differ even
between similar monitors. Record UUIDs, not indexes or IDs; those change on
reconnect.
