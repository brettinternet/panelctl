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

## Experimental public mirroring

`panelctl mirror --display <target> --source <source> --consent-mirror` hides a
non-main external target's separate desktop by mirroring it, not by dropping its
signal. `panelctl unmirror --consent-unmirror` restores and verifies the journaled
topology. Both accept `--journal <path>`; neither changes gamma or monitor input.
Each live operation needs fresh scoped approval. Modes/HDR/refresh and windows or
Spaces may change; no hardware tuple is qualified yet. See
[public mirroring](display-mirroring.md) for restrictions, fallback and trial gates.

## Experimental topology disable and recovery

These commands are implemented but **production disable currently refuses**:
there is no qualified fresh physical-sink/driver/awake-state provider. Consent
cannot override missing evidence. Offline tests do not authorize hardware trials.
After separate qualification and scoped approval, the intended bounded syntax is:

```sh
panelctl recovery disable --display DISPLAY_UUID --consent-disable --timeout 15s
panelctl recovery status
panelctl recovery enable
panelctl recovery panic
```

Only one non-main external physical display may be selected; another verified
usable physical screen must remain. Timeout is explicitly required, 1–60 seconds.
The CLI stays attached to the independent recovery helper until the lease ends.
There is no indefinite disconnect or automatic disable on startup/login/wake.
Enable/panic use retained journal identity, **not** an online display selector.
`status` is journal-only JSON, including offline targets, state and refusal reason.
All accept `--journal <path>`; keep that same path for recovery. Parse errors exit
2; unsafe/unavailable operations or failed recovery exit 1; completed operations
exit 0. A refused disable is not a successful signal-removal experiment.

Blackout paints an overlay and keeps the display connected. Topology disable
would remove the Mac's display signal/layout entry; monitor standby and automatic
switching to another computer's input are separate, unqualified outcomes. Enable
would restore the Mac's signal, not necessarily the monitor's selected input.
Neither approach guarantees OLED maintenance, restored window placement or Spaces.
See [display recovery](display-recovery.md) for guards and the manual failure ladder.

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
  displays awake until a `--sleep-after` endpoint while the screen is unlocked,
  while still allowing the Mac to sleep sooner.
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

`status`, `hide`, `show` and `toggle-hide` do not launch the app; other commands
start it in the background if needed. Only `open-settings` shows a window. JSON status may
include `nextAction`, `secondsRemaining`, and `snoozedUntil`.

### Scripted Hide and Show

`hide`, `show` and `toggle-hide` do what a display's Hide or Show button does
in the running app, in that display's Hide style: Black out, or Remove from
desktop when Experimental features are on and the display is set up for it.
They name the display by UUID, not by numeric ID, name or index. Settings →
Displays → Scripts shows the command for the selected display, using the CLI
bundled in the app so it works without PATH setup:

```sh
/Applications/PanelCtl.app/Contents/Helpers/panelctl app toggle-hide --display 00000000-0000-0000-0000-000000000002
```

`toggle-hide` shows a hidden display and hides a shown one, which suits a
single Stream Deck button; `hide` and `show` set one state. A display already
in the requested state returns `no-op`, with no repeated input switch. The
command waits up to 30 seconds for the Hide or Show to finish and reports the
result. A request that can't run now is refused, never queued: another Hide or
Show is running or finished while the request waited, displays are asleep or
changing, no connected display has the UUID, the display can't be hidden, or it
is the last visible display. While display recovery is unresolved, scripts can
only show hidden displays; other requests return `recovery-needed`. Only these
commands hide a display; idle, startup, wake and reconnection never do.

For a Shortcut, use **Run Shell Script** with the bundled CLI and capture the
JSON even on a nonzero result:

```sh
/Applications/PanelCtl.app/Contents/Helpers/panelctl app toggle-hide \
  --display 00000000-0000-0000-0000-000000000002 --json || :
```

Read `outcome` in the returned dictionary: `done`, `no-op`, `refused`, `busy`,
`failed`, `partial`, `recovery-needed` or `response-lost`. `summary` describes
the desktop, `detail` the monitor input when Hide or Show switched it, and
`displays` holds that display's status entry, described below. On
`response-lost`, inspect `app status --json` before taking any further action;
the CLI does not resend these requests.

| Exit | Meaning |
| --- | --- |
| 0 | Success, including `done` and `no-op` |
| 1 | `refused`, `busy`, `failed`, `response-lost`, or other control failure |
| 2 | Invalid CLI arguments (usage error on stderr, no JSON) |
| 3 | App unavailable (Hide/Show/status do not launch it) |
| 5 | `partial`: the desktop changed but switching the monitor input was skipped, unverified, not attempted or failed; status reports it while that result is current |
| 6 | `recovery-needed`; inspect the shared journal in Displays |

Status keeps `state` as the protection state. Its added `displays` array lists
every display the Displays tab shows, with `targetUUID`, `observedState`
(`separate`, `hidden-by-panelctl`, `mirrored-externally`, `unavailable`,
`recovery-needed`, `unsupported-recovery` or `unknown`), `operation` (`idle`,
`hiding`, `showing`), `recoveryNeeded`, and optional `lastInputOutcome`. A
blacked-out display reports `hidden-by-panelctl`. Input evidence
includes its state, requested/observed codes, detail and any recovery command.
It is the last app operation result **in this session**, not a live input reading
or saved configuration. Relaunch discards it rather than inventing input state.
A partial input result can coexist with a restored desktop; repeated Show is
still a successful no-op, while status retains the warning. Status `ok: true`
means inspection answered, not that every display/input operation succeeded:
check `outcome` and the exit code. Oversized status fails explicitly rather than
silently dropping recovery/input evidence; an oversized Hide or Show reply keeps
its `outcome` and `summary` but omits `displays` and `detail`.

Existing enable/disable/toggle, blackout-now, restore, snooze/resume and sleep-now
retain their meanings. Restore only removes protection; it never Shows or
switches inputs. Idle/empty-display automation remains blackout/dimming-only,
and hide/recovery suspends protection as described in the
[Hide/Show contract](display-hide-ux.md). Launch/wake never re-hide or retry DDC.
This script interface adds no hardware qualification or live-write approval.

For a persistent CLI watcher, edit the executable path and display UUID in the
[LaunchAgent example](../examples/com.brettinternet.panelctl.blackout.plist).

## Limits and safety

An opaque pure-black window minimizes OLED pixel emission but does not sleep
display electronics or guarantee a panel compensation cycle. A transparent
working overlay reduces visible output but does not guarantee unlit OLED pixels
or panel longevity. Use all-display sleep for long unattended periods.

macOS has no public per-display sleep or disconnect setter. Ordinary PanelCtl
protection avoids private topology calls; the experimental recovery CLI fails
closed until its identity and physical/lifecycle providers are qualified.
See the [feasibility research](feasibility.md) for the API and hardware evidence.

DDC depends on the monitor and connection. `ddc-luminance --set` persists and
does not restore the previous value. Blackout `--dim-to` journals captured
values, but recovery can be delayed after a crash or disconnect. DDC power/DPMS
is not implemented.
