# Selected-display panel protection on macOS

Research date: 2026-07-24; test host: macOS 26.5.2, Apple Silicon (M1 Max)

## Conclusion

macOS has no public API that sleeps or disconnects one external display while
leaving others awake.

| Operation | Desktop remains active | Result | Reliability |
| --- | --- | --- | --- |
| Opaque pure-black window | Yes | OLED pixels are unlit; electronics stay on | High |
| Partially transparent overlay | Yes | Visible output is reduced; OLED pixels may remain lit | High |
| DDC luminance target | Yes | Hardware brightness is lowered | Hardware-dependent |
| Private topology disconnect | No | Signal may stop | Low; recovery varies |
| DDC power/DPMS | Usually | Firmware decides | Unsafe without an allowlist |

Opaque pure black is the safest selective OLED-protection default: it is
reversible and does not alter display topology or firmware state. A partially
transparent composited overlay reduces visible output but does not guarantee
unlit OLED pixels, hardware sleep, or panel longevity. For long unattended
periods, sleep every display so monitors can enter their normal standby and
compensation paths.

`panelctl` therefore implements inventory, reversible blackouts, all-display
sleep/wake, private-API probes, and verified DDC luminance reads/writes. It does
not invoke private topology APIs or send DDC power commands.

## Current direction

The findings below are historical evidence for the stated host, not qualification
of later machines. The [display-disable implementation plan](display-disable-implementation-plan.md)
now recommends bounded offline development of a consent-gated soft disconnect,
with strict recovery/refusal and separately approved hardware trials. `backlog/`
tracks that future work; this does not change the current feature claims above.

## Further exploration

[Recovery-first undocumented display control](undocumented-display-control.md)
compares soft disconnect, link control, and power APIs against the requirement
for easy restoration. It includes read-only evidence from the newer host and
qualification gates; no private state-changing calls have been tested there.

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
`--dim-to` journals captured values and retries failed restorations, but cannot
guarantee immediate recovery after a crash, disconnect, shutdown, UUID change,
or unavailable transport.

DDC power remains excluded. Reports in
[`ddcctl` issue #89](https://github.com/kfix/ddcctl/issues/89) include broken
physical controls and monitors requiring power removal. A powered-down monitor
may also stop accepting the command needed to wake it.

## Blackout and sleep implications

Black OLED pixels under an opaque pure-black window are unlit, as described in
Samsung Display's [OLED overview](https://oledera.samsungdisplay.com/eng/oled/),
but the video link and electronics remain active. A partially transparent
working overlay only reduces visible output; underlying OLED pixels may remain
lit. Neither treatment is hardware sleep or a longevity guarantee.

The overlay fails open on display-layout changes, sleep, session changes, or
signals; blocking mode also fails open on input. It verifies each window's
screen ID and full frame before showing it, including scaled, rotated, stacked,
and negative-origin layouts. System UI may still appear above it.

`sleep-displays` uses `pmset displaysleepnow` for every display. This is the
preferred long-idle mode. Dell documents automatic Pixel Refresh in standby for
the [AW3425DW](https://dl.dell.com/content/manual4846619-alienware-34-240hz-qd-oled-gaming-monitor-aw3425dw-user-s-guide.pdf?language=en-us)
and [AW3423DW](https://www.dell.com/support/kbdoc/en-us/000198595/alienware-aw3423dw-pixel-refresh-will-turn-monitor-off).

## Per-display DDC availability (TASK-14)

`probe` now reports independent Get VCP readability for input (`0x60`) and
luminance (`0x10`) in text and JSON, including failure reasons and not-applicable
skips. It never sets monitor values. A successful read is not write qualification.
See [DDC probe behavior](ddc-input.md#check-readability-first) for status meanings.

### Approved read-only run: 2026-10-04

At `2026-10-04T17:07:01Z`, the user approved one probe of all currently active
external displays, limited to Get VCP `0x60` and `0x10`. Ran
`.build/debug/panelctl probe --json` once (exit 0), with no Set VCP, topology,
power or link-control commands, and no retries.

Build: arm64, macOS 27.0.1 (`26A434`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), debug `panelctl` built with warnings as errors from
base `b9dca94e8976d0c390b3cb5e823cd7a7fd2e1da2` plus the TASK-14 implementation.
Binary SHA-256: `32c1520dba52b9fa2529fae0f5ca9ab33984d72e0a7504260b9c038916136262`.

| Display (vendor/model/serial) | UUID | Input 0x60 | Luminance 0x10 |
| --- | --- | --- | --- |
| DELL S2721DGF (4268/16857/1094800204) | `09084682-3C42-4455-AAB8-126A7431125B` | transportError: invalid DDC reply: invalid payload length | Same error |
| AW3425DW (4268/41613/809650259) | `A8D3635B-35EC-4171-BBE2-95FB8CF76111` | readable | readable |
| K272HUL (1138/1316/1952494047) | `98402864-2A3E-4B75-92E6-0F801B89C132` | readable | readable |
| Dell AW3423DW (4268/41444/809906515) | `1FC57E99-DE7C-4DAF-B896-3B512CEE064F` | transportError: DDC I2C request failed (IOReturn -535740416) | Same error |

All four were active, online external displays. The inventory found four
external DCPAVServiceProxy services on `dispext0`–`dispext3`; cable/adapter types,
per-display connector mapping and firmware versions were not captured by this
report. No physical connection or input changes were requested. The S2721DGF
failure does not negate its historical successful reads/input trial: this run
only establishes that it did not return valid replies at this time. Failures
are not proof of permanent lack of DDC support. Neither readable result qualifies
writes. The earlier hardware table remains separate historical evidence.

## Qualification commands

After user approval for DDC Get VCP reads, run from the logged-in GUI session:

```sh
swift run panelctl list
swift run panelctl probe --json
```

Record the display UUID, model and serial, connection path, current macOS build,
and DDC read result before enabling any hardware write. Do not persist indexes
or CG IDs because they can change after reconnecting a display.
