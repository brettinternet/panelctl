<p align="center">
  <img width="128" src="Packaging/AppIcon.png" style="padding:0.5rem;">
</p>

<h1 align="center">panelctl</h1>

A macOS CLI and menu-bar app for OLED blackouts, display sleep, inventory, and
experimental DDC luminance control.

## Install

Download the universal app or CLI from
[GitHub Releases](https://github.com/brettinternet/panelctl/releases), or build
the CLI on macOS 13 or newer:

```sh
swift build -c release --product panelctl
mkdir -p ~/.local/bin
install -m 0755 .build/release/panelctl ~/.local/bin/panelctl
```

Release artifacts are ad-hoc signed, not Developer ID signed or notarized. If
macOS blocks the app, verify its checksum and source, then use **Open Anyway**
in System Settings → Privacy & Security or control-click it and choose **Open**.

## Menu-bar app

Move `PanelCtl.app` to `/Applications`, open it, select displays, and enable
protection. It supports per-display blackouts, optional all-display sleep,
hardware dimming, snooze, launch at login, and configurable idle and restore
timers.

Closing Settings does not stop protection. Quitting removes the blackout and
stops the watcher. Reopen the app to show Settings when its menu icon is hidden.

## CLI

```sh
panelctl list
panelctl blackout --display DISPLAY_UUID --idle-after 5m --watch
panelctl blackout --index 3 --timeout 1h
panelctl blackout --all --idle-after 5m --sleep-after 30m --keep-displays-awake
panelctl sleep-displays --keep-system-awake
panelctl wake-displays
panelctl ddc-luminance --display index:2
panelctl ddc-luminance --display index:2 --set 75
```

Selectors accept a display UUID, decimal or hexadecimal CG ID, or `index:N`.
Indexes can change after reconnecting displays, so unattended watchers should
use UUIDs. Durations accept seconds or an `s`, `m`, or `h` suffix.

Run `panelctl help` or `panelctl <command> --help` for all options.

### Blackout behavior

When the pointer is on a blacked-out display, the menu-bar app takes focus so
macOS will hide the cursor. Moving to an active display or restoring the
blackout returns focus to the previous app. This applies only to blackouts
managed by the menu-bar app; the standalone CLI cannot reliably hide the macOS
cursor while it is in the background.

- Without `--idle-after`, blackout starts immediately.
- Input restores the display. `--timeout` restores after a limit;
  `--sleep-after` instead sleeps every display.
- `--watch` requires `--idle-after` and repeats after each restored cycle.
- `--all` requires `--timeout` or `--sleep-after`.
- `--caffeinate` explicitly prevents idle system sleep (advanced behavior).
  `--keep-displays-awake` is valid with `--sleep-after` and keeps displays
  awake until that endpoint while allowing macOS to sleep the Mac sooner. The
  display assertion is global, so it applies to all displays.
- Automatic idle blackouts pause while macOS reports an active display-sleep
  prevention assertion (such as media playback), then restart the full idle
  countdown when it ends. Manual blackout-now commands are not deferred.
- `--dim` best-effort dims supported external displays and restores their
  captured brightness. DDC remains experimental.

Display, session, or sleep changes fail open by removing the blackout. Windows
are shown only after their screen IDs and frames are verified.

### App automation

The CLI can control the app's saved configuration from scripts and Shortcuts:

```sh
panelctl app enable
panelctl app disable
panelctl app toggle
panelctl app status --json
panelctl app blackout-now
panelctl app restore
panelctl app sleep-now
panelctl app snooze --for 30m
panelctl app resume
panelctl app open-settings
```

Use the bundled CLI if the standalone one is not installed:

```sh
/Applications/PanelCtl.app/Contents/Helpers/panelctl app toggle
```

`status` does not launch the app; other commands start it in the background if
needed. Only `open-settings` shows a window. Status exits `0` when the app
answers, `3` when it is not running, and `1` on control failure. JSON status may
include `nextAction`, `secondsRemaining`, and `snoozedUntil`.

For a persistent CLI watcher, edit the executable path and display UUID in the
[LaunchAgent example](examples/com.brettinternet.panelctl.blackout.plist).

## Limits and safety

A pure-black window minimizes OLED pixel emission but does not sleep the display
electronics or guarantee a panel compensation cycle. System UI may appear above
it. Use all-display sleep for long unattended periods.

macOS provides no public per-display sleep or disconnect setter. Private
topology calls can make a display difficult to recover, so panelctl does not use
them. See [the feasibility note](docs/feasibility.md) for the API and hardware
evidence.

DDC depends on the monitor and connection. `ddc-luminance --set` persists and
does not restore the previous value. Blackout `--dim` journals captured values,
but recovery can be delayed after a crash or disconnect. DDC power/DPMS is not
implemented.

## Development

```sh
swift test --disable-sandbox
swift build --product panelctl
swift build --product PanelCtlApp
scripts/test-release-version.sh
```

Package releases with `scripts/package-release.sh vMAJOR.MINOR.PATCH`.
