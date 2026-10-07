# Usage

```sh
panelctl list                                           # find display UUIDs
panelctl blackout --display UUID --idle-after 5m --watch
panelctl blackout --display UUID --mode working --overlay-opacity 60 --dim-to 25 --timeout 1h
panelctl blackout --all --idle-after 5m --sleep-after 30m --keep-displays-awake
panelctl sleep-displays --keep-system-awake
panelctl wake-displays
panelctl ddc-luminance --display index:2 --set 75
```

A display selector is a UUID, a decimal or hex Core Graphics ID, or `index:N`.
IDs and indexes change on reconnect, so scripts should use UUIDs. Durations
take seconds or an `s`, `m` or `h` suffix.

## Blackout

| Mode | Effect | Ends on |
| --- | --- | --- |
| Blocking (default) | Opaque black window; takes focus so the cursor hides | Input, `--timeout`, `--sleep-after` |
| `--mode working` | Click-through dimming; focus and input untouched | `--timeout`, `--sleep-after`, menu Restore, `panelctl app restore` |

| Flag | Behavior |
| --- | --- |
| `--idle-after D` | Wait until idle for D; otherwise start now |
| `--watch` | Repeat after each restore (needs `--idle-after`) |
| `--timeout D` | Restore after D |
| `--sleep-after D` | Sleep every display after D |
| `--keep-blackout-on-input` | A partial blocking blackout survives input and restarts its timer (always on in working mode) |
| `--overlay-opacity 1...100` / `--no-overlay` | Working-mode darkness, or none |
| `--dim-to 0...100` | Lower external brightness over DDC, then restore it; never raises |
| `--blackout-empty-displays` | Also black out selected displays with no windows |
| `--caffeinate` | Prevent idle system sleep |
| `--keep-displays-awake` | Keep displays awake until `--sleep-after` |

- Covering every display (including `--all`) requires `--timeout` or
  `--sleep-after`, so you can't lock yourself out.
- Idle blackout waits while another app keeps displays awake (such as a video
  call), then restarts its countdown. Manual commands never wait.
- Display, session or sleep changes remove the blackout.
- In the app, Escape with the pointer on a black display restores it.

For a persistent watcher, edit the
[LaunchAgent example](../examples/com.brettinternet.panelctl.blackout.plist).

## Menu-bar app

Settings has three tabs:

| Tab | Contents |
| --- | --- |
| **Displays** | Per-display Hide/Show, input switching, copyable scripts |
| **Automations** | **Rules** run when you're idle; **Actions** run when you trigger them |
| **General** | Launch at login, menu icon, Experimental features |

Hide defaults to **Black out**: the display stays black until Show. With
Experimental features on, **Remove from desktop** moves windows off the display
instead. See [Hide and Show](display-hide-ux.md).

Each rule picks displays, an idle delay, blackout or dimming, and what happens
afterward (**Restore** or **Sleep**). Two enabled rules can't share a display.
The master switch and Pause apply to all rules.

An Action is 1–8 ordered steps, each hiding or showing one display. It runs
only from **Run** or `panelctl app run-action`. Steps run in order and stop at
the first problem; earlier steps are not undone.

Closing Settings keeps everything running. Quitting removes black-outs but can
leave removed displays hidden, so the quit prompt offers **Show and Quit**.
If the menu icon is hidden, reopen the app to show Settings.

## App automation

```sh
panelctl app enable | disable | toggle        # master Automation switch
panelctl app status --json
panelctl app status --watch --json             # live, read-only status
panelctl app restore | sleep-now
panelctl app snooze --for 30m
panelctl app resume
panelctl app open-settings
panelctl app hide | toggle-hide --display UUID [--style black-out] [--json]
panelctl app show --display UUID [--json]
panelctl app run-action --action UUID [--json]
panelctl app run-rule --rule UUID [--json]
```

### Live status for integrations

`panelctl app status --watch --json` opens one read-only connection. It prints a
complete current status immediately, then newline-delimited JSON (one compact
document per line), using the same fields as `app status --json` plus `sequence`.
Sequence numbers start at 1 and increase per connection; compare consecutive
numbers to detect gaps. No heartbeats or identical consecutive snapshots are
sent. Changes are coalesced into 100 ms windows (at most ten updates per second,
plus the initial and terminal snapshots); intermediate states in a burst may be
omitted, so this is a current-state feed, not an event/audit log.

Display, rule, running Action, snooze and countdown changes update the stream.
On app shutdown or connection failure the CLI emits a final `running: false`
document with an error and the next sequence number, then exits 3. It also exits
3 with one such document if the app is absent. It never launches the app or
reconnects; restart it explicitly when desired. An older app without streaming
support produces a terminal error rather than silently falling back to polling.

For a Stream Deck plugin, keep one watcher process and update your button from
each parsed line. This shell example needs `jq` and prints the button label:

```sh
panelctl app status --watch --json |
  jq --unbuffered -r 'if .running then .summary else "PanelCtl disconnected" end'
```

Consumers must read promptly. The app does not queue unsent snapshots: a full
socket buffer or partial write disconnects that watcher without affecting others.
Frames are bounded to 1 MiB; oversized snapshots disconnect rather than omit
display evidence. At most 64 watchers are accepted. The stream accepts no further
requests; use a separate normal CLI invocation for commands. Existing one-shot
status and command requests retain their existing protocol and size limits.

Without a standalone install, use
`/Applications/PanelCtl.app/Contents/Helpers/panelctl`.

`status`, `hide`, `show`, `toggle-hide`, `run-action` and `run-rule` need the app
running; the rest launch it in the background. `restore` ends Automation blackouts
only; it never shows a hidden display.

`panelctl app blackout-now` is retired. The CLI exits 2 with migration guidance
before contacting or launching the app, and the app refuses the same request from
older clients without changing Automation or snooze state. Use `app hide --display`
for one display until Show, `app run-action` for ordered Hide/Show steps, or
`app run-rule` to run one saved Automation rule. The Run rule submenu replaced the
former broadcast Blackout Now menu item; it never runs every rule at once.

`panelctl app run-rule --rule UUID` runs exactly one saved Automation rule once,
immediately bypassing its idle wait. Find stable IDs with `panelctl app status --json`
in `rules[].id`, or edit the rule in **Settings → Automations** and use
**Command → Copy**. Save the rule before running its command. **Run now** in Settings and the menu bar’s **Run rule** submenu use
this same one-shot operation. The submenu lists off rules too and marks the
selected rule while it runs. Run failures
from the menu open Automations, where the rule shows the refusal and next action.
Running once does not turn on its automatic trigger.

The run applies that rule’s display selection, blackout or dimming,
input behavior, duration, and configured Restore or Sleep follow-up. As a manual
run, playback and camera automatic deferrals do not delay it. It returns when the
effect is installed or refused, not when the run later restores, and does not
change the rule, master Automation switch, snooze expiry or saved preferences. Text
reports the outcome and summary; `--json` returns the structured result. A rule,
Automation or snooze may be disabled; normal automatic scheduling afterward
still follows those unchanged settings.

This is different from `run-action` (ordered Hide/Show steps) and app `hide`
(which keeps one display hidden until Show). `hide` and `toggle-hide` use the
configured Hide style unless `--style black-out` forces a black cover for that
Hide without changing saved preferences. Styled requests require app-control request
protocol 2, so older running apps refuse rather than silently use the configured
removal style; update/restart the app before using this option. Unstyled requests
and responses retain protocol 1 compatibility. An active selected rule or competing
display operation returns `busy`; overlapping rules are refused, and Full disconnect
or unresolved recovery returns `recovery-needed`. Run-rule never launches the app, queues,
retries, broadcasts to another rule or automatically replays a lost response. After
`response-lost`, check `panelctl app status --json`; a lost response does not cancel
the run or make retry safe. The status response includes `runningRule` with the
selected rule’s stable ID while it runs.

### Scripted Hide and Show

Copy the exact command from **Displays → Scripts**, or use it in a Stream Deck
button or Shortcuts **Run Shell Script** action:

```sh
/Applications/PanelCtl.app/Contents/Helpers/panelctl app toggle-hide \
  --display DISPLAY_UUID --json
```

```json
{ "outcome": "done", "summary": "Hidden.", "detail": "<input result>", "displays": [ … ] }
```

| Exit | `outcome` | Meaning |
| --- | --- | --- |
| 0 | `done`, `no-op` | Success (`no-op`: already in that state) |
| 1 | `refused`, `busy`, `failed`, `response-lost` | Not done |
| 2 | — | Invalid arguments |
| 3 | — | App not running |
| 5 | `partial` | Desktop changed, but the input switch didn't complete |
| 6 | `recovery-needed` | Display needs recovery; only Show is allowed |

Hide/Show waits up to 30 seconds; an Action waits 30 seconds per step; run-rule
returns as soon as its effect is installed. Requests are never queued or resent.
After `response-lost`, check
`app status --json` before retrying.

### Status JSON

```json
{
  "ok": true, "running": true, "enabled": true, "state": "waiting",
  "summary": "…", "nextAction": "blackout", "secondsRemaining": 240,
  "runningRule": { "id": "…", "name": "Desk dimming" },
  "rules": [
    { "id": "…", "name": "Desk dimming", "enabled": true, "state": "waiting",
      "displays": ["DISPLAY_UUID"], "nextAction": "dim", "secondsRemaining": 180 }
  ],
  "displays": [
    { "targetUUID": "…", "observedState": "hidden-by-panelctl", "operation": "idle", "recoveryNeeded": false }
  ]
}
```

- Top-level fields summarize all rules; `rules` has one entry per rule.
- `ok: true` means the app answered, not that everything succeeded.
- `observedState`: `separate`, `hidden-by-panelctl`, `mirrored-externally`,
  `unavailable`, `recovery-needed`, `unsupported-recovery` or `unknown`.
- `operation`: `idle`, `hiding` or `showing`.
- `runningAction` appears while an Action runs; `runningRule` identifies the
  single rule running once.
- `lastInputOutcome` is the last input result since launch, with a
  `recoveryCommand` to switch back.

## Experimental commands

| Command | What it does |
| --- | --- |
| [`ddc-input`](ddc-input.md) | Read or switch a monitor's input |
| [`ddc-power`](ddc-power.md) | Turn a monitor off or on over DDC; may need manual recovery |
| [`mirror` / `unmirror`](display-mirroring.md) | Remove a display's desktop by mirroring, or Show it |
| [`away` / `back`](display-handoff.md) | Mirror plus optional input switch, or Show |
| [`recovery …`](display-recovery.md) | List, verify and restore saved display layouts |
| [`recovery disable`](display-disable.md) | Drop the Mac's signal to one display (private API) |

Consent flags (`--consent-mirror`, `--accept-power-risk`, …) acknowledge risk;
they don't make untested hardware safe. Have another working display and the
monitor's buttons within reach.

## Limits

- A black window leaves OLED pixels unlit, but the monitor stays on and won't
  run its panel maintenance. For long idle periods, sleep all displays.
- macOS has no public way to sleep or disconnect one display. See
  [feasibility](feasibility.md).
- DDC support depends on the Mac, monitor, port and adapter.
  `ddc-luminance --set` is not undone. `--dim-to` restores brightness, though a
  crash or disconnect can delay it.
