# Selected-display panel protection on macOS

Research date: 2026-07-24
Test host: macOS 26.5.2, Apple Silicon (M1 Max)

## Conclusion

macOS has no public API that sleeps or disconnects one physical external
display while leaving the others awake.

There are four different operations that tools often call "turn off":

| Operation | macOS still uses the desktop? | Panel result | Reliability |
| --- | --- | --- | --- |
| Render pure black | Yes | OLED pixels are unlit; monitor electronics remain on | High |
| Set DDC luminance to zero | Yes | Hardware brightness is minimized; exact OLED behavior is monitor-specific | Medium, monitor/connection dependent |
| Disconnect from the display topology | No | Signal may stop and the monitor may enter standby | Low; private API and recovery is inconsistent |
| Send DDC power/DPMS | Usually yes until the monitor drops off the bus | Monitor firmware decides whether to sleep or power down | Dangerous without a per-model allowlist |

For this project's panel-preservation goal, pure-black output is the safe
selective baseline. It is immediately reversible when the process exits and
does not alter display topology or monitor firmware state. For a long
unattended interval, sleeping all displays is preferable: it lets each monitor
enter its normal standby/compensation path instead of leaving the electronics
continuously active behind an app window.

This is specific to emissive panels: Samsung Display's
[OLED overview](https://oledera.samsungdisplay.com/eng/oled/) confirms that
black OLED pixels are unlit. The video link and panel electronics remain on,
but content-driven pixel emission and wear are reduced while the overlay is
present. This is not a guarantee of total panel longevity: standby and
compensation behavior remain model-specific.

`panelctl` therefore implements:

- public display inventory;
- a read-only probe for the relevant private symbols and Apple Silicon display
  services;
- a reversible, selected-display black overlay with idle, timeout, and
  all-display sleep lifecycle options;
- an explicit all-display sleep/wake command using the public `pmset` tool;
- DDC luminance Get/Set VCP `0x10` with read-back verification.

It intentionally does not invoke private topology APIs or send DDC DPMS/power
commands.

### Blackout command and limits

The grammar is:

```text
blackout ((--display <selector> | --index <n>)... | --all)
         [--idle-after <seconds>]
         [--timeout <seconds> | --sleep-after <seconds>]
         [--caffeinate]
```

`--index` is a one-based shortcut for the index printed by `list`; selectors
also accept a contextual decimal/hexadecimal display ID, UUID, or `index:N`.
`--all` requires a finite `--timeout` or `--sleep-after`, and explicit targets
cannot include every drawable screen. Without `--idle-after`, the overlay is
installed immediately. With it, `panelctl` waits for combined-session idle
time. After installation, any new combined-session input removes the overlay
and exits (one-shot restore behavior).

The timeout and sleep-after clocks start when the overlay is installed, not
when the process starts. `--timeout` removes the overlay and exits;
`--sleep-after` removes it and then runs `pmset displaysleepnow` for all
displays. They are mutually exclusive. `--caffeinate` holds only a
`caffeinate -i` assertion, so idle system sleep is prevented while display
sleep remains allowed. Signals, display-layout changes, and session/sleep
notifications fail open by removing the windows.

The overlay is owned by the logged-in GUI session. The cursor, system HUDs,
lock screen, or a higher-level system window may appear above it; locking,
Fast User Switching, or ending the GUI session can replace it. It does not
disconnect displays, power them off, or guarantee uninterrupted black output.
Hot-plug and display-layout changes stop it rather than risk covering the wrong
screen. Windows are prepared before any are shown, pinned to the current full
`NSScreen.frame`, and rejected unless the actual frame and target screen ID
match exactly. AppKit points naturally cover Retina scaling, rotation, and
current logical resolution; WindowServer's documented coordinate/window-size
limits still apply. The initializer uses a zero-origin content rectangle with
the target screen passed separately. This is required for screens with offset
or negative global origins; using the global frame as the content rectangle
doubles the origin and can produce a small corner blackout instead of full
coverage. This follows the screen-relative semantics of Apple's
[`NSWindow` screen initializer](https://developer.apple.com/documentation/appkit/nswindow/init%28contentrect%3Astylemask%3Abacking%3Adefer%3Ascreen%3A).

### True display sleep

`panelctl sleep-displays` invokes `pmset displaysleepnow`, which asks macOS to
sleep every display without putting the system to sleep. `--keep-system-awake`
adds `caffeinate -i`; an optional timeout releases that assertion, while
`wake-displays` sends a short user-activity assertion. These commands do not
change persistent power settings. This is the recommended mode for a long
unattended OLED interval when no panel must remain visible.

The two Dell OLEDs on the test host document model-specific standby behavior:
the [AW3425DW user guide](https://dl.dell.com/content/manual4846619-alienware-34-240hz-qd-oled-gaming-monitor-aw3425dw-user-s-guide.pdf?language=en-us)
describes automatic Pixel Refresh after four hours when the monitor enters
standby/power-off, and Dell reports the same automatic refresh behavior for the
[AW3423DW](https://www.dell.com/support/kbdoc/en-us/000198595/alienware-aw3423dw-pixel-refresh-will-turn-monitor-off).
That is why true standby is safer for eventual maintenance than leaving a
black app window up indefinitely.

### DDC luminance qualification on this host

`ddc-luminance` uses only the MCCS luminance feature (`0x10`) through
dynamically loaded private `IOAVService`/CoreDisplay transport functions.
Without `--set` it sends a Get VCP query. With `--set`, it first reads the
current value and maximum, rejects out-of-range values, sends Set VCP `0x10`,
and reads back the value with one bounded verification retry. It implements no
DPMS/power operation.

The live qualification results were:

| Display | Result |
| --- | --- |
| Dell AW3425DW, UUID `703CA103-...` | Read `75/100`; write/restore `75 → 74 → 75` verified |
| Dell AW3423DW, UUID `9963A32C-...` | DDC communication failed on the current path |

The second result is not proof that the AW3423DW lacks DDC/CI. Check its OSD
DDC/CI setting and test without the dock/adapter or through another link before
classifying the panel as unsupported. DDC is a monitor-firmware and transport
feature, not a portable macOS display-power API.

The AW3425DW write proves luminance control only for this monitor, firmware
state, and connection path. A luminance write persists if the process exits;
there is no transactional rollback across a crash, cable loss, or system
shutdown. The command therefore reports the original, requested, and observed
values, but restoration remains the caller's responsibility. No write was sent
to the AW3423DW because it did not pass the read prerequisite.

BetterDisplay's exact implementation is proprietary. Based on its published
[integration/CLI documentation](https://github.com/waydabber/BetterDisplay/wiki/Integration-features%2C-CLI),
the reasonable inference is a layered strategy: private display-topology or
Apple display services where available, DDC for compatible hardware controls,
and software color-table/overlay dimming as a fallback. Its `connected`,
`hardwareBacklight`, and software-dimming controls should not be interpreted as
a universal per-panel power switch; support varies with monitor, HDR mode, and
connection path.

These limits need physical testing across the actual idle, lock, sleep, and wake
lifecycle. The overlay should not be described as panel sleep or as guaranteed
uninterrupted black output.

## Available control planes

### Public CoreGraphics

[Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services)
can enumerate active and online displays and configure modes, origins, and
mirroring in a transaction.

Relevant distinctions:

- `CGGetActiveDisplayList`: displays drawable by applications;
- `CGGetOnlineDisplayList`: connected displays, including sleeping displays and
  non-drawable hardware mirrors;
- `CGDisplayIsAsleep`: a getter only;
- `CGConfigureDisplayWithDisplayMode`: mode changes;
- `CGConfigureDisplayMirrorOfDisplay`: mirroring;
- `CGCompleteDisplayConfiguration`: app, session, or permanent transaction
  scope.

There is no public enable, disconnect, or per-display sleep setter.

Apple does not publish a rationale for keeping those operations private. The
most likely explanation is architectural and safety-related: a per-path
disconnect spans WindowServer, display-controller firmware, link training,
docks/adapters, mirroring, and recovery when the last visible screen vanishes.
Those states are heterogeneous and can strand a user without a working
display, so Apple keeps the coordinated topology SPI private rather than
promising a portable monitor-power contract. This is an inference from the
public API boundary, not an Apple statement.

### Private WindowServer topology API

`CGSConfigureDisplayEnabled` is exported by CoreGraphics on the test host, and
`SLSConfigureDisplayEnabled` is exported by SkyLight. Neither has a public
header or compatibility contract.

`displayplacer` declares this private signature itself and commits changes
permanently:

```c
CGError CGSConfigureDisplayEnabled(
    CGDisplayConfigRef config,
    CGDirectDisplayID display,
    bool enabled
);
```

This changes the macOS display topology. It is not a monitor power command.
Depending on the driver and connection, removing the framebuffer may also stop
the video signal and cause the monitor to enter its own standby mode.

The symbol's presence proves that a private control plane exists. It does not
prove stable behavior, a stable ABI, or reliable recovery on a particular Mac,
dock, adapter, or monitor.

### Public legacy IOKit display parameters

The macOS SDK still declares:

- `IODisplaySetIntegerParameter`;
- `IODisplaySetFloatParameter`;
- `kIODisplayPowerStateKey` (`"dsyp"`);
- states `Off`, `MinUsable`, and `On`.

Apple's current published
[IOGraphics source](https://github.com/apple-oss-distributions/IOGraphics)
routes the power-state parameter through display-driver handlers. Its concrete
backlight implementation is for `IOBacklightDisplay`; this is not evidence that
arbitrary external monitors implement per-connector power control.

The old bridge from a CoreGraphics display ID to its framebuffer,
`CGDisplayIOServicePort`, has been unavailable since macOS 10.9. That makes the
otherwise-public API impractical as a modern general solution.

### DDC/CI

The public `IOKit/i2c/IOI2CInterface.h` API can expose a framebuffer's I2C bus
and explicitly supports DDC/CI transactions. Its own contract says not every
graphics device provides this interface.

On Apple Silicon, current tools commonly use private `IOAVService` functions
instead:

- `IOAVServiceCreateWithService`;
- `IOAVServiceReadI2C`;
- `IOAVServiceWriteI2C`.

These symbols are present in IOKit on the test host but have no public SDK
declarations. The MIT-licensed
[m1ddc](https://github.com/waydabber/m1ddc) project demonstrates this route for
USB-C/DisplayPort Alt Mode. It explicitly does not cover every Mac or port.

DDC operations remain monitor-firmware operations:

- luminance is usually VCP `0x10`;
- input selection is usually VCP `0x60`;
- power mode is VCP `0xD6`.

DDC capability discovery and reading a value do not guarantee that writing it
is safe. Microsoft gives the same warning for its public
[`SetVCPFeature`](https://learn.microsoft.com/en-us/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-setvcpfeature)
API: many monitors incompletely implement MCCS and require physical validation.

### Private DisplayServices

The private DisplayServices framework exports:

- `DisplayServicesGetPowerMode`;
- `DisplayServicesSetPowerMode`;
- brightness controls.

The symbols exist, but no public contract establishes that they control
arbitrary external monitors. Open-source Lunar exposes them only through an
experimental CLI path. They should be treated as built-in/Apple-smart-display
SPI until a specific monitor proves otherwise.

## displayplacer failure diagnosis

ROOT CAUSE PROVEN for displayplacer's normal re-enable path; universal hardware
recovery remains unproven.

Symptom: `enabled:false` succeeds, but the same display cannot subsequently be
found or re-enabled.

Reproduction evidence:

- [`displayplacer` issue #109](https://github.com/jakehilborn/displayplacer/issues/109)
  reports that a disabled display disappears from System Information; the
  maintainer reproduced this on an M2 Mac.
- [Issues #126](https://github.com/jakehilborn/displayplacer/issues/126) and
  [#137](https://github.com/jakehilborn/displayplacer/issues/137) contain
  additional Apple Silicon and external-monitor failures.

First divergence:

1. `displayplacer` obtains its addressable set from
   `CGGetOnlineDisplayList`.
2. It resolves the supplied UUID to a contextual `CGDirectDisplayID`.
3. It rejects any target that is not in the online list before calling
   `CGSConfigureDisplayEnabled`.
4. The private disable operation removes the target from that list, so the
   normal enable path cannot address it.

Mechanism: private topology removal destroys the public identifier mapping that
the tool requires for the inverse operation.

Trigger: permanently commit `CGSConfigureDisplayEnabled(..., false)` on a
display/driver combination that removes the target from public enumeration.

Evidence that distinguishes this from a simple command-syntax problem:

- the source performs the online validation before every enable/disable call;
- the display is also absent from macOS's own inventory;
- open, unmerged
  [`displayplacer` PR #155](https://github.com/jakehilborn/displayplacer/pull/155)
  bypasses UUID resolution and sweeps numeric IDs 1–10 to recover offline
  displays.

The PR's numeric sweep works on some Macs and fails on others. That leaves a
second, driver-specific recovery problem unresolved. It is not safe enough to
adopt.

## Why Windows appears better integrated

Windows exposes two stable public layers that macOS does not:

1. [`SetDisplayConfig`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdisplayconfig)
   explicitly applies and persists active display paths. A caller can validate
   a proposed topology before applying it.
2. The monitor-configuration API maps an `HMONITOR` to physical monitor handles
   and exposes MCCS capability discovery and VCP reads/writes.

macOS exposes public mode, layout, and mirroring APIs, but keeps path
enable/disable private. Its modern Apple Silicon DDC mapping also relies on
private `IOAVService` calls.

Windows does not make arbitrary physical-monitor power safe. Its documentation
warns that DDC/MCCS behavior is undefined until validated on the actual monitor.
The integration advantage is mainly stable topology and physical-monitor
addressing, not a universal panel-power command.

## Rejected default mechanisms

### Persistent private disconnect

Do not call `CGSConfigureDisplayEnabled(false)` as the normal inactivity action.
It can remove the only identifier needed for recovery, and `displayplacer`
commits the state permanently.

If this is ever added as an experimental mode, minimum safeguards are:

- never target the last usable display;
- use app-only transaction scope first;
- retain the original contextual ID and stable EDID identity before changing
  topology;
- keep a separate watchdog process with a short automatic restore timer;
- restore on `SIGINT`, `SIGTERM`, `SIGHUP`, and unexpected parent exit;
- prove cable hot-plug and reboot recovery on each tested setup;
- never sweep guessed display IDs.

### DDC power mode

Do not send VCP `0xD6` by default.

[`ddcctl` issue #89](https://github.com/kfix/ddcctl/issues/89) records three
separate destructive or unrecoverable behaviors, including broken physical
button behavior and monitors that required power removal. The project replaced
its former power flag with a no-op because of those reports.

A powered-down monitor may also stop responding to DDC, making software wake
impossible even when the off command behaved as designed.

### Brightness without state capture

Hardware brightness zero is lower risk than DPMS but must still be treated as a
per-monitor operation. Always read and retain the previous value, serialize
writes, and restore only after re-identifying the same physical display.

## Hardware qualification sequence

Run these from a terminal in the logged-in GUI session:

```sh
swift run panelctl list
swift run panelctl probe --json
```

The probe output should establish:

- actual online/active contextual IDs and current CG UUIDs;
- OLED model and serial identities;
- direct HDMI vs USB-C/DP vs dock/adapter path;
- Apple Silicon `DCPAVServiceProxy` availability;
- which private transports are present on this OS build.

The initial read-only registry inspection on this host found two active external
OLEDs:

| Model | EDID standby | EDID suspend | EDID active-off |
| --- | --- | --- | --- |
| Dell AW3425DW | Yes | Yes | Yes |
| Dell AW3423DW | Yes | No | No |

Those flags describe capabilities advertised to the display driver; they are
not callable public APIs and do not prove a safe per-display transition. The
difference does prove that one hard-coded power sequence would be incorrect
even for the two OLEDs attached to this Mac.

The DDC command is implemented as `panelctl ddc-luminance`. On this host it
reads `75/100` from the AW3425DW and a one-unit write/restore qualification
(`75 → 74 → 75`) passed read-back verification. The AW3423DW still reports a
communication failure on its current path and was not written. DPMS remains out
of scope unless the exact monitor model and connection path are explicitly
allowlisted after physical validation.
