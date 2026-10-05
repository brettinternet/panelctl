# Selected-display control on macOS: research

macOS has no public API that sleeps or disconnects one external display while
others stay awake.

| Operation | Desktop stays | Result | Reliability |
| --- | --- | --- | --- |
| Opaque black window | Yes | OLED pixels unlit; electronics on | High |
| Translucent overlay | Yes | Output reduced; pixels may stay lit | High |
| DDC luminance | Yes | Hardware brightness lowered | Hardware-dependent |
| Public mirroring | No (merged) | Separate desktop removed; signal stays | Tested on one setup |
| Private topology disable | No | Signal may stop | Unqualified; recovery varies |
| DDC power/DPMS | Usually | Firmware decides | Unsafe without an allowlist |

PanelCtl ships the overlay, all-display sleep and DDC luminance, plus
experimental [mirroring](display-mirroring.md) and [DDC input](ddc-input.md).
Private disable is [designed but unqualified](display-disable.md).

For long unattended periods, sleep every display (`pmset displaysleepnow`) so
monitors enter standby and their compensation cycles. Dell documents Pixel
Refresh in standby for the
[AW3425DW](https://dl.dell.com/content/manual4846619-alienware-34-240hz-qd-oled-gaming-monitor-aw3425dw-user-s-guide.pdf?language=en-us)
and [AW3423DW](https://www.dell.com/support/kbdoc/en-us/000198595/alienware-aw3423dw-pixel-refresh-will-turn-monitor-off).
Black pixels under an overlay are unlit
([Samsung Display](https://oledera.samsungdisplay.com/eng/oled/)), but the link
and electronics stay active.

## APIs

**Public CoreGraphics.** [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services)
enumerates displays and sets modes, positions and mirroring.
`CGDisplayIsAsleep` is only a getter; there is no per-display sleep, enable or
disconnect setter.

**Private topology.** `CGSConfigureDisplayEnabled` / `SLSConfigureDisplayEnabled`
change topology, not monitor power, with no header or compatibility contract.
displayplacer's re-enable failure shows the trap: it resolves targets through
`CGGetOnlineDisplayList`, disabling removes the display from that list, so
enable can't find it
([#109](https://github.com/jakehilborn/displayplacer/issues/109),
[#126](https://github.com/jakehilborn/displayplacer/issues/126),
[#137](https://github.com/jakehilborn/displayplacer/issues/137)).
[PR #155](https://github.com/jakehilborn/displayplacer/pull/155) sweeps numeric
IDs — not a targeted recovery strategy. displayplacer also commits permanently.

**IOKit and DisplayServices.** IOKit display power keys don't establish
control of arbitrary external monitors; the CG-to-framebuffer bridge has been
gone since macOS 10.9. DisplayServices exports power and brightness functions
with no external-monitor contract.

**DDC/CI.** Apple Silicon tools use private `IOAVServiceReadI2C` /
`WriteI2C` ([m1ddc](https://github.com/waydabber/m1ddc)), which doesn't cover
every Mac, port, adapter or monitor. VCP codes: luminance `0x10`, input `0x60`,
power `0xD6`. A successful read doesn't make a write safe (see Microsoft's
[`SetVCPFeature`](https://learn.microsoft.com/en-us/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-setvcpfeature)
warning). DDC power is excluded: [ddcctl #89](https://github.com/kfix/ddcctl/issues/89)
reports broken physical controls and monitors needing power removal, and a
powered-down monitor may not accept the wake command.

## Candidate private methods

| Method | Expected effect | Concern | Disposition |
| --- | --- | --- | --- |
| `CGSConfigureDisplayEnabled` | Remove from topology; monitor may enter standby | Vanishes from enumeration; driver may reject enable | [Implemented, unqualified](display-disable.md) |
| `IOAVServiceStopLink` / `StartLink` | Names suggest link control | Unverified signatures and WindowServer interaction | Don't invoke on names alone |
| `DisplayServicesSetPowerMode` | Private power control | No external restore contract | Lower priority |
| DDC `0xD6` | Firmware power | May stop accepting wake | Excluded |

External evidence: [Lunar](https://lunar.fyi/faq) ships a hidden disconnect on
Apple Silicon (implementation not verifiable).
[BetterDisplay #1623](https://github.com/waydabber/BetterDisplay/issues/1623):
macOS can create a headless virtual display that counts as online, so an online
count doesn't prove a usable physical screen remains.
[BetterDisplay #5658](https://github.com/waydabber/BetterDisplay/issues/5658):
model-specific built-in failures on base M3 laptops. See also the
[tool survey](display-disable-tool-survey.md).

## Hardware results

Older host (macOS 26.5.2, M1 Max):

| Display | EDID standby / suspend / off | DDC luminance |
| --- | --- | --- |
| Dell AW3425DW | Yes / Yes / Yes | Read 75; `75 → 74 → 75` verified |
| Dell AW3423DW | Yes / No / No | Communication failed; no write |

EDID flags are advertised capabilities, not callable APIs, and differ even
between two OLEDs on one Mac. Current-host DDC probes are in
[ddc-input](ddc-input.md#hardware-results).

Current host (macOS 27.0.1 `26A434`, M5 Max Mac Studio): four external
displays (S2721DGF, AW3425DW, K272HUL, AW3423DW main); `CGSConfigureDisplayEnabled`,
`DisplayServicesSetPowerMode`, `IOAVServiceGetPower` and
`IOAVServiceStart/StopLink` resolve; four `DCPAVServiceProxy` services, no
`AppleCLCD2`. Symbol presence proves availability only.

To gather evidence on a new setup (DDC reads only):

```sh
swift run panelctl list
swift run panelctl probe --json
```

Record UUID, model, serial, connection path, macOS build and DDC results.
Don't persist indexes or CG IDs; they change on reconnect.

## Offline identity research

Private re-enable needs to know that a retained CG ID still names the same
physical monitor while it's offline. Static analysis of build `26A434` found no
source that proves this:

| Source | Finding |
| --- | --- |
| Public / private enumeration | Private list included an offline entry with no UUID and zero vendor/model/serial |
| `IOAVServiceCopyEDID` (`0x184e130d4`) | User-client selector `0x1a` → DCP operation 7 over IPC. A fresh reply isn't a fresh EDID read; opening the service is not passive |
| `IOMobileFramebufferGetID` (`0x18fefea30`) | `_kern_GetID` returns a cached 32-bit value at `+0xad8` without a kernel call (image `B1C5BB2D-DB25-332B-AD82-CF1EC6170E8B`) |
| `AppleDisplayManagerMappingGet` / QuartzCore | Resource mapping, separate `framebufferId` and `displayId` paths, first-match lookup; no unique CG association |
| DCP firmware (`64863924-B56B-3E32-87FE-038677F52709`) | BUND reconstruction incomplete; a candidate EDID helper may return virtual EDID. Operation 7's producer and invalidation weren't joined |
| Third-party callers | Agree on the setter shape; disagree on GetID |

Still unknown: fresh sink identity, a unique offline CG association, and
replacement or ID-reuse invalidation. Cached metadata, HPD and matching integers
don't fill these gaps, so PanelCtl uses an exact capture/current match and
refuses otherwise ([identity](display-disable.md#identity)).

A possible next step, unapproved and only for identical-monitor hardening: one
bounded static reconstruction of the DCP BUND data and fixups, then trace
operation 7 to its producer and invalidation paths. Read-only, local artifacts
only, stop on the first unresolved edge. Even success wouldn't prove retained
CG ID mapping.

**ICC.** Two regenerated profiles differed only in creation-time bytes 24–35;
that led to the [date-independent digest](display-recovery.md#snapshot).
