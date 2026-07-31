# Selected-display panel protection on macOS

Research date: 2026-07-24; test host: macOS 26.5.2, Apple Silicon (M1 Max)

## Conclusion

macOS has no public API that sleeps or disconnects one external display while
leaving others awake.

| Operation | Desktop remains active | Result | Reliability |
| --- | --- | --- | --- |
| Pure-black window | Yes | OLED pixels are unlit; electronics stay on | High |
| DDC luminance zero | Yes | Hardware brightness is minimized | Hardware-dependent |
| Private topology disconnect | No | Signal may stop | Low; recovery varies |
| DDC power/DPMS | Usually | Firmware decides | Unsafe without an allowlist |

Pure black is the safest selective default: it is reversible and does not alter
display topology or firmware state. For long unattended periods, sleep every
display so monitors can enter their normal standby and compensation paths.

`panelctl` therefore implements inventory, reversible blackouts, all-display
sleep/wake, private-API probes, and verified DDC luminance reads/writes. It does
not invoke private topology APIs or send DDC power commands.

## API findings

### Public CoreGraphics

[Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services)
can enumerate displays and configure modes, positions, and mirroring.
`CGDisplayIsAsleep` is only a getter. There is no public per-display sleep,
enable, or disconnect setter.

### Private topology APIs

`CGSConfigureDisplayEnabled` and `SLSConfigureDisplayEnabled` exist on the test
host but have no public headers, compatibility contract, or reliable recovery
behavior. They change display topology, not monitor power.

This explains displayplacer's observed re-enable failure:

1. It resolves targets through `CGGetOnlineDisplayList`.
2. Disabling a display can remove it from that list.
3. The normal enable path then cannot resolve the UUID needed to restore it.

The maintainer reproduced the disappearance in
[issue #109](https://github.com/jakehilborn/displayplacer/issues/109); related
failures appear in [#126](https://github.com/jakehilborn/displayplacer/issues/126)
and [#137](https://github.com/jakehilborn/displayplacer/issues/137).
[PR #155](https://github.com/jakehilborn/displayplacer/pull/155) tries numeric
display IDs, but recovery remains driver-dependent. panelctl does not take this
risk.

### IOKit and DisplayServices

The public IOKit display-parameter API includes power-state keys, but its
concrete backlight path does not establish control of arbitrary external
monitors. The old CoreGraphics-to-framebuffer bridge has been unavailable since
macOS 10.9.

Private DisplayServices exports power and brightness functions, but no public
contract says they support external monitors. They should be treated as
Apple-display SPI until qualified on specific hardware.

### DDC/CI

Public IOKit I2C interfaces are optional. Apple Silicon tools commonly use the
private `IOAVServiceReadI2C` and `IOAVServiceWriteI2C` path demonstrated by
[m1ddc](https://github.com/waydabber/m1ddc), which does not cover every Mac,
port, adapter, or monitor.

Common VCP codes are luminance `0x10`, input `0x60`, and power `0xD6`.
Capability discovery or a successful read does not prove a write is safe;
Microsoft gives the same warning for
[`SetVCPFeature`](https://learn.microsoft.com/en-us/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-setvcpfeature).

## Hardware results

| Display | EDID standby/suspend/off | DDC luminance |
| --- | --- | --- |
| Dell AW3425DW | Yes / Yes / Yes | Read `75/100`; `75 → 74 → 75` verified |
| Dell AW3423DW | Yes / No / No | Communication failed; no write attempted |

EDID flags describe advertised capabilities, not callable public APIs. The
different flags also show why one power sequence cannot be assumed safe even
for two OLEDs on the same Mac.

The AW3425DW result applies only to that monitor, firmware state, and connection
path. Raw luminance writes persist, so callers must restore them. Blackout
`--dim` journals captured values and retries failed restorations, but cannot
guarantee immediate recovery after a crash, disconnect, shutdown, UUID change,
or unavailable transport.

DDC power remains excluded. Reports in
[`ddcctl` issue #89](https://github.com/kfix/ddcctl/issues/89) include broken
physical controls and monitors requiring power removal. A powered-down monitor
may also stop accepting the command needed to wake it.

## Blackout and sleep implications

Black OLED pixels are unlit, as described in Samsung Display's
[OLED overview](https://oledera.samsungdisplay.com/eng/oled/), but the video
link and electronics remain active. A black window reduces content-driven pixel
emission; it is not hardware sleep or a longevity guarantee.

The overlay fails open on input, display-layout changes, sleep, session changes,
or signals. It verifies each window's screen ID and full frame before showing
it, including scaled, rotated, stacked, and negative-origin layouts. System UI
may still appear above it.

`sleep-displays` uses `pmset displaysleepnow` for every display. This is the
preferred long-idle mode. Dell documents automatic Pixel Refresh in standby for
the [AW3425DW](https://dl.dell.com/content/manual4846619-alienware-34-240hz-qd-oled-gaming-monitor-aw3425dw-user-s-guide.pdf?language=en-us)
and [AW3423DW](https://www.dell.com/support/kbdoc/en-us/000198595/alienware-aw3423dw-pixel-refresh-will-turn-monitor-off).

## Qualification commands

Run from the logged-in GUI session:

```sh
swift run panelctl list
swift run panelctl probe --json
```

Record the display UUID, model and serial, connection path, current macOS build,
and DDC read result before enabling any hardware write. Do not persist indexes
or CG IDs because they can change after reconnecting a display.
