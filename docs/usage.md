# Usage

## Display selection

Selectors accept a display UUID, decimal or hexadecimal Core Graphics ID, or
`index:N`. Indexes can change after displays reconnect, so unattended watchers
should use UUIDs. Durations accept seconds or an `s`, `m`, or `h` suffix.

```sh
panelctl list
panelctl blackout --display DISPLAY_UUID --idle-after 5m --watch
panelctl blackout --display DISPLAY_UUID --mode working --overlay-opacity 60 --dim-to 25 --timeout 1h
panelctl blackout --display DISPLAY_UUID --idle-after 5m --watch --blackout-empty-displays
panelctl blackout --index 3 --timeout 1h
panelctl blackout --all --idle-after 5m --sleep-after 30m --keep-displays-awake
panelctl sleep-displays --keep-system-awake
panelctl wake-displays
panelctl ddc-luminance --display index:2
panelctl ddc-luminance --display index:2 --set 75
```

## Menu-bar app

Move `PanelCtl.app` to `/Applications`, open it, select displays, and enable
protection. It supports per-display blackouts, optional all-display sleep,
hardware dimming, snooze, launch at login, and configurable idle and restore
timers.

Closing Settings does not stop protection. Quitting removes the blackout and
stops the watcher. Reopen the app to show Settings when its menu icon is hidden.

## Blackout behavior

Blocking mode is the default. When the pointer is on a display blacked out by
the menu-bar app, PanelCtl takes focus so macOS will hide the cursor. Moving to
an active display or restoring returns focus to the previous app. Escape is a
best-effort app-managed restore after that proxy activates. The standalone CLI
has no background Escape or cursor guarantee.

`--mode working` installs a click-through dimming overlay without changing
focus, hiding the pointer, or consuming keyboard input. Set its darkness with
`--overlay-opacity 1...100`, or disable composited darkening with
`--no-overlay`. Restore from the status menu, `panelctl app restore`, or the
configured Restore/Sleep endpoint.

- Without `--idle-after`, treatment starts immediately.
- Input restores a blocking blackout. `--timeout` restores after a limit;
  `--sleep-after` instead sleeps every display.
- `--keep-blackout-on-input` keeps a partial blocking blackout during activity
  and restarts its endpoint. Working mode always behaves this way for partial
  selections. Activity does not extend full-display finite endpoints.
- `--watch` requires `--idle-after` and repeats after each restored cycle.
- `--all` requires `--timeout` or `--sleep-after`. Every full-display selection
  requires a finite Restore/Sleep endpoint, including explicit selectors.
- `--caffeinate` prevents idle system sleep. `--keep-displays-awake` keeps all
  displays awake until a `--sleep-after` endpoint while allowing the Mac to
  sleep sooner.
- Automatic treatment waits while another app keeps the display awake, then
  restarts the full idle countdown. It can also wait for configured camera
  activity. Manual commands are not deferred.
- `--dim-to 0...100` best-effort lowers supported external displays and restores
  their captured brightness. It never raises brightness. Blocking
  `--keep-blackout-on-input` cannot use it; working mode can.

Display, session, or sleep changes fail open by removing the blackout. Windows
appear only after their screen IDs and frames are verified.

## App automation

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
[LaunchAgent example](../examples/com.brettinternet.panelctl.blackout.plist).

## Limits and safety

An opaque pure-black window minimizes OLED pixel emission but does not sleep
display electronics or guarantee a panel compensation cycle. A transparent
working overlay reduces visible output but does not guarantee unlit OLED pixels
or panel longevity. Use all-display sleep for long unattended periods.

macOS has no public per-display sleep or disconnect setter. PanelCtl avoids
private topology calls because they can make a display difficult to recover.
See the [feasibility research](feasibility.md) for the API and hardware evidence.

DDC depends on the monitor and connection. `ddc-luminance --set` persists and
does not restore the previous value. Blackout `--dim-to` journals captured
values, but recovery can be delayed after a crash or disconnect. DDC power/DPMS
is not implemented.
