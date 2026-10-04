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

`status`, `hide` and `show` do not launch the app; other commands start it in
the background if needed. Only `open-settings` shows a window. JSON status may
include `nextAction`, `secondsRemaining`, and `snoozedUntil`.

### Scripted desktop Hide/Show

Configure the exact target and mirror source in Settings → Displays first.
Use the target UUID, not a numeric ID, name or index:

```sh
panelctl app hide --display 00000000-0000-0000-0000-000000000002 --json
panelctl app show --display 00000000-0000-0000-0000-000000000002 --json
```

Replace the example UUID with your configured display's UUID. These commands
check current identity and shared-journal observations using the app's UI
settings, including optional monitor inputs. **Every actual change still needs
fresh UI confirmation.** A headless request returns `confirmation-required`
and directs you to Settings → Displays; it never opens a hidden modal or treats
saved opt-in as consent. There is no `--yes` bypass. Open the app and choose
Hide or Show to review the source, inputs, protection suspension and fallback.
An already hidden/shown desktop returns `no-op`, with no repeated DDC write.
Show confirmation/recovery remains available while protection is disabled or
snoozed, and uses the journal owner rather than guessing an absent target.

For a Shortcut, use **Run Shell Script** with the bundled CLI and capture the
JSON even on a nonzero result:

```sh
/Applications/PanelCtl.app/Contents/Helpers/panelctl app show \
  --display 00000000-0000-0000-0000-000000000002 --json || :
```

Read `outcome` in the returned dictionary. On `confirmation-required`, instruct
the user to open PanelCtl and confirm Show in Displays. Do not poll/retry Hide
or Show to obtain consent. On `response-lost`, inspect `app status --json`
before taking any further action; the CLI does not resend these requests.

| Exit | Meaning |
| --- | --- |
| 0 | Successful existing action/status, or Hide/Show `no-op` |
| 1 | `refused`, `busy`, `response-lost`, or other control failure |
| 2 | Invalid CLI arguments (usage error on stderr, no JSON) |
| 3 | App unavailable (Hide/Show/status do not launch it) |
| 4 | `confirmation-required`; complete the operation in the UI |
| 5 | Status reports `partial`: a session input result was skipped, unverified, not attempted or failed |
| 6 | `recovery-needed`; inspect the shared journal in Displays |

Status keeps `state` as the protection state. Its added `displays` array contains
`targetUUID`, `observedState` (`separate`, `hidden-by-panelctl`,
`mirrored-externally`, `unavailable`, `recovery-needed`,
`unsupported-recovery` or `unknown`), `operation` (`idle`, `hiding`,
`showing`), `recoveryNeeded`, and optional `lastInputOutcome`. Input evidence
includes its state, requested/observed codes, detail and any recovery command.
It is the last app operation result **in this session**, not a live input reading
or saved configuration. Relaunch discards it rather than inventing input state.
A partial input result can coexist with a restored desktop; repeated Show is
still a successful no-op, while status retains the warning. Status `ok: true`
means inspection answered, not that every display/input operation succeeded:
check `outcome` and the exit code. Oversized status fails explicitly rather than
silently dropping recovery/input evidence.

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
