# Display disable: surveyed tools

How four macOS tools implement per-monitor "disable", reduced to mechanisms
and safety patterns. Tools are named by role: an open-source menu-bar utility,
a mode-switching utility, a full display manager, and an adaptive-brightness
app. Sources: public code, issue trackers, release notes, and static analysis
of shipped binaries. Nothing was installed or run; vendor help text is a claim,
not an observation. The resulting design is [display disable](display-disable.md).

## Mechanism

All four call `CGSConfigureDisplayEnabled(config, displayID, enabled)` inside a
`CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` transaction.
SkyLight exports it as `SLSConfigureDisplayEnabled`; CoreGraphics re-exports
the `CGS` name.

- Re-enable passes `true` with the ID retained from before disable.
- A disabled display leaves the layout, System Settings and the public online
  list; windows move off it. The monitor usually loses signal and enters
  standby, though one vendor warns some monitors don't turn off.
- To list disabled displays, two tools use the private `CGSGetDisplayList` /
  `SLSGetDisplayList`; the open-source utility remembers them in memory.
- None uses `IOAVServiceStopLink`/`StartLink`. DDC power-off appears only as a
  separate, caveated action.

| Binding | Seen in | If the symbol disappears |
| --- | --- | --- |
| `dlsym` CoreGraphics, fall back to SkyLight, explicit "unavailable" | Mode-switching utility | Feature disabled; app works |
| Static import of `CGS` | Full display manager | App fails to launch |
| Static import of `SLS` | Adaptive-brightness app | App fails to launch |
| `@_silgen_name` | Open-source utility | Launch failure; also declares `Int` return and Swift convention, which works on arm64 by accident |

## Commit scope

| Scope | Used by | Behavior |
| --- | --- | --- |
| App-only (`0`) | Open-source utility | After a force quit the display stayed disabled and unlistable. Same-port replug didn't help; another port did; restart restores |
| Session (`1`) | Mode-switching utility | Re-enables all on quit and SIGTERM/SIGINT; crash and SIGKILL can't |
| Permanent (`2`) | Full display manager, adaptive-brightness app | Survival across reboot unverified; help still lists restart as recovery |

Takeaways: no scope undoes the private flag when the process dies, so recovery
must work from another process and after restart. Use session scope, never
permanent. Logout/reboot and `CGRestorePermanentDisplayConfiguration()` are
expected but unverified restores. Completion invalidates the transaction even on
failure; one tool cancels after a failed complete — don't.

## Fallbacks

| Method | Notes |
| --- | --- |
| Mirror + zero gamma | Gamma reapplied 5× at 1 s. Re-enables are nondeterministic. A macOS gamma bug can leave a screen blank; needs a journal and zero-table detection |
| Mirror + brightness 0 | With an enforcer that reapplies it |
| Overlay | Works for virtual, Sidecar and AirPlay. Safest, but no standby, no input fallback, windows stay |
| DDC power `0xD6` | Can't power back on; standby monitors ignore DDC; user must press power |

## Identity and recovery patterns

- **Retained ID.** Every tool re-enables by the pre-disable CG ID.
- **IOKit presence** (mode-switching utility). Reads
  `IOPortTransportStateDisplayPort` (`HPD_StateDescription`,
  `TransportDescription`, registry ID) to map disabled displays to cached IDs.
  For uncached displays it guesses sequential IDs — which PanelCtl forbids.
- **Intent vs observation** (full display manager). Stores disconnect intent
  separately; keeps a display disconnected only with intent and confirmed
  physical presence; accepts disconnects without intent as system state;
  schedules recovery instead of guessing for identical displays.
- **Sleep/wake.** Snapshot before sleep, restore after wake with a fixed attempt
  budget, read lid state from `IOPMrootDomain` `AppleClamshellState`, defer
  during transitions.
- **System re-enable.** macOS may reconnect displays after wake. Accept it.

## Guard rails

- **Never leave zero usable displays.** Count only eligible displays (virtual
  ones don't count). The open-source utility lacks this guard; users needed VNC.
- **Built-in.** Refuse built-in-only mode with the lid closed. Some M3 Macs
  may not reconnect a disabled built-in until restart.
- **Escape hatches.** Keyboard kill switch, safe-mode launch modifier,
  reconnect-all in CLI/automation.
- **Non-native.** Disable the API while DisplayLink runs.
- **Intel.** Soft disconnect may not fully sleep the display; unplugging while
  disconnected can leave no display until restart. One tool ships arm64 only.
- **UI.** Keep disabled displays listed; reconnect by retained ID.

## Failure evidence

- A force quit left a display disabled and unlistable: re-enable must come from
  a persisted journal, not the online list.
- Same-port replug stayed disabled while another port recovered (USB-C, M1 Max,
  macOS 15.2). A display on a new port may get a new ID.
- Unplugging the last enabled external with the built-in disabled gave a black
  screen.
- Every tool's last resort: replug, lid close/open, restart.

## Multi-input monitor case

A monitor fed by this Mac over DP and another computer over HDMI:

- Disable should drop the Mac's signal so the monitor auto-selects HDMI.
  Unobserved on the S2721DGF, which reports `SupportsSuspend = No` and
  `SupportsActiveOff = No` (the AW3425DW reports both `Yes`).
- On re-enable the monitor may stay on HDMI. Both DDC-capable tools ship VCP
  `0x60` input select, a lower-risk follow-up and a standalone alternative
  ([ddc-input](ddc-input.md)).
