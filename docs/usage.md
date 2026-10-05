# Usage

## Quick start

```sh
panelctl list                                           # find display UUIDs
panelctl blackout --display UUID --idle-after 5m --watch
panelctl blackout --display UUID --mode working --overlay-opacity 60 --dim-to 25 --timeout 1h
panelctl blackout --all --idle-after 5m --sleep-after 30m --keep-displays-awake
panelctl sleep-displays --keep-system-awake
panelctl wake-displays
panelctl ddc-luminance --display index:2 --set 75
```

Selectors accept a UUID, a decimal or hex Core Graphics ID, or `index:N`.
Indexes and IDs change on reconnect, so scripts and watchers should use UUIDs.
Durations accept seconds or an `s`, `m` or `h` suffix.

## Blackout

| Mode | Effect | Ends on |
| --- | --- | --- |
| Blocking (default) | Opaque black window; app takes focus so macOS hides the cursor | Input, `--timeout`, or `--sleep-after` |
| `--mode working` | Click-through dimming; focus, pointer and keyboard untouched | `--timeout`, `--sleep-after`, menu Restore, `panelctl app restore` |

| Flag | Behavior |
| --- | --- |
| `--idle-after D` | Wait for idle; without it, treatment starts immediately |
| `--watch` | Repeat after each restore; requires `--idle-after` |
| `--timeout D` / `--sleep-after D` | Restore after D, or sleep every display after D |
| `--keep-blackout-on-input` | Partial blocking blackout survives activity and restarts its endpoint (always on in working mode) |
| `--overlay-opacity 1...100` / `--no-overlay` | Working-mode darkness, or no composited darkening |
| `--dim-to 0...100` | Lower supported externals over DDC, then restore captured brightness; never raises. Not with blocking `--keep-blackout-on-input` |
| `--blackout-empty-displays` | Black out selected displays that have no windows |
| `--caffeinate` | Prevent idle system sleep |
| `--keep-displays-awake` | Keep displays awake until `--sleep-after` while unlocked; the Mac may still sleep |

Rules:

- `--all`, and any selection covering every display, needs `--timeout` or
  `--sleep-after`. Activity never extends that endpoint.
- Automatic treatment waits while another app holds a display-awake assertion
  (or a configured camera is active), then restarts the full countdown. Manual
  commands are never deferred.
- Display, session or sleep changes fail open by removing the blackout. Windows
  appear only after their screen IDs and frames are verified.
- In the app, Escape with the pointer on a black display restores it. The
  standalone CLI has no background Escape or cursor guarantee.

## Menu-bar app

Move `PanelCtl.app` to `/Applications` and open it. Settings has three tabs:
**Displays** (per-display Hide/Show, input switching, scripts), **Automation**
(idle blackout, dimming, timers, pause rules) and **General** (launch at login,
menu icon, Experimental features).

Closing Settings keeps protection running. Quitting removes blackouts and stops
the watcher. Reopen the app to show Settings when the menu icon is hidden.

## App automation

```sh
panelctl app enable | disable | toggle
panelctl app status --json
panelctl app blackout-now | restore | sleep-now
panelctl app snooze --for 30m
panelctl app resume
panelctl app open-settings
panelctl app hide | show | toggle-hide --display UUID [--json]
```

Without a standalone install, use the bundled CLI:
`/Applications/PanelCtl.app/Contents/Helpers/panelctl`.

`status`, `hide`, `show` and `toggle-hide` never launch the app. Other commands
start it in the background; only `open-settings` shows a window. `restore` only
removes protection; it never shows a hidden display or switches inputs.

### Scripted Hide and Show

`hide`, `show` and `toggle-hide` press a display's Hide/Show button in the
running app, using its Hide style (see [Hide and Show](display-hide-ux.md)).
Settings → Displays → Scripts shows the exact command. For a Stream Deck button
or a Shortcuts **Run Shell Script** action:

```sh
/Applications/PanelCtl.app/Contents/Helpers/panelctl app toggle-hide \
  --display 00000000-0000-0000-0000-000000000002 --json || :
```

```json
{ "outcome": "done", "summary": "<desktop result>", "detail": "<input result>", "displays": [ … ] }
```

The command waits up to 30 seconds and is never queued or resent. A display
already in the requested state returns `no-op` without another input switch.

| Exit | `outcome` | Meaning |
| --- | --- | --- |
| 0 | `done`, `no-op` | Success |
| 1 | `refused`, `busy`, `failed`, `response-lost` | Not done. Refusals: another Hide/Show running, displays asleep or changing, unknown UUID, display can't hide, last visible display |
| 2 | — | Invalid arguments (usage on stderr, no JSON) |
| 3 | — | App not running |
| 5 | `partial` | Desktop changed; monitor input switch skipped, unverified or failed |
| 6 | `recovery-needed` | Unresolved display recovery; only Show is allowed |

On `response-lost`, check `app status --json` before doing anything else.

### Status JSON

```json
{
  "ok": true, "running": true, "enabled": true, "state": "waiting",
  "summary": "…", "nextAction": "blackout", "secondsRemaining": 240,
  "displays": [{
    "targetUUID": "…", "observedState": "hidden-by-panelctl",
    "operation": "idle", "recoveryNeeded": false,
    "lastInputOutcome": { "state": "verified", "requestedInput": 17, "observedInput": 17 }
  }]
}
```

- `state` is the protection state (`disabled`, `waiting`, …). `ok: true` means status answered, not that
  every operation succeeded.
- `observedState`: `separate`, `hidden-by-panelctl` (including blacked out),
  `mirrored-externally`, `unavailable`, `recovery-needed`,
  `unsupported-recovery` or `unknown`. `operation`: `idle`, `hiding`, `showing`.
- `lastInputOutcome` is the last input result **in this app session**, not a
  live reading. Relaunch clears it. It may include `detail` and the
  `recoveryCommand` that switches the input back.
- Oversized status fails rather than drop evidence. An oversized Hide/Show reply
  keeps `outcome` and `summary` and omits `displays` and `detail`.

Only explicit commands hide a display. Idle, startup, wake and reconnection
never do. For a persistent CLI watcher, edit the
[LaunchAgent example](../examples/com.brettinternet.panelctl.blackout.plist).

## Experimental display commands

| Command | What it does | Docs |
| --- | --- | --- |
| `ddc-input` | Read or switch a monitor's input over DDC | [DDC input](ddc-input.md) |
| `mirror` / `unmirror` | Hide a desktop by public mirroring | [Mirroring](display-mirroring.md) |
| `away` / `back` | Mirror plus optional input switch, as one command | [Handoff](display-handoff.md) |
| `recovery …` | Journal, verify and restore display topology | [Recovery](display-recovery.md) |
| `recovery disable` | Private signal removal; **currently always refuses** | [Display disable](display-disable.md) |

Each live topology or DDC write needs a deliberate decision on untested
hardware; consent flags acknowledge risk, they are not qualification.

## Limits

- An opaque black window leaves OLED pixels unlit but keeps the display
  electronics on and does not trigger panel compensation. The working overlay
  only reduces output. Use all-display sleep for long unattended periods.
- macOS has no public per-display sleep or disconnect. Normal protection never
  calls private topology APIs. See [feasibility](feasibility.md).
- DDC depends on monitor and connection. `ddc-luminance --set` persists and is
  not restored. `--dim-to` journals captured values, but restoration can be
  delayed by a crash or disconnect. DDC power is not implemented.
