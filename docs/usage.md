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
**Displays** (per-display Hide/Show, input switching, scripts), **Automations**
(named idle protection rules and manual Actions) and **General** (launch at login,
menu icon, Experimental features).

The Automations tab has two sections. **Rules** run on their own when you're
idle; **Actions** run only when you trigger them. The master Automation switch
and global pause sit at the top of Rules and govern rules only. Rules are listed
with their effect, displays, Afterward behavior and current status. A
migrated **Display protection** rule appears without changing its settings.
**Add Rule…**
and **Edit…** open a draft sheet; **Save** applies changes and **Cancel**
discards them. Each rule has its own switch. Conflicts are explained inline,
missing saved targets remain visible, and the global display-sleep timer setting
appears only when a rule sleeps all displays. **Black Out Now** in the menu is
titled for the enabled rules' effects; Restore and Pause remain global.

Named idle blackout/dimming rules and named manual display Actions are shipped.
Schedules and arbitrary action chains are deferred. Rules do not support
unattended Hide/Show, topology, monitor-input, power or private-disconnect
actions; those hardware-changing operations are not implicit rule triggers.

Select a display tile to see its state, Hide/Show button, setup and inline
results. Hide defaults to **Black out**: it leaves the desktop in place and
stays black until Show or Escape with the pointer on that display. It is not
the same as an automation blackout: **Restore** does not show a hidden display.

To move windows off eligible external displays, enable **General → Experimental
features**, accept the configuration-time prompt, then turn on **Remove from
desktop** for each target. Choose **Mirror onto** and optionally **Switch
monitor to**. Multiple healthy removals can coexist, including several targets
onto one source. Each tile, menu item and scripted status is per target; setup
for other displays stays editable. Show any target in any order: it returns only
that display, and the remaining targets stay removed. While other targets stay
removed, macOS may place the returning display slightly away from its saved
position; the final Show verifies the exact pre-first-Hide arrangement, modes
and main display. Every Show verifies before switching back to the Mac's
detected input. Turning Experimental features off makes new
Hides black out instead, but never removes Show or recovery for a removed
display. Only the recorded S2721DGF-then-AW3425DW CLI round trip is qualified;
other multi-display combinations remain unqualified. See
[the trial record](display-multi-removal-trial.md).
Each new live write still needs separate approval.

The menu also offers per-display Hide/Show; each Show leaves other removed
displays untouched. **Show and Quit** restores each healthy removed target in
turn and quits only after all succeed. Results stay inline, including
input-switch warnings; ordinary Hide/Show has no per-operation confirmation.
Full disconnect (experimental) is separate and requires its own scoped consent each time.
See [Hide styles and safety boundaries](display-hide-ux.md).

### Named manual Actions

Create a named, one-display Action in **Settings → Automations → Actions**.
Choose the exact **Hide (black out)**, **Hide (remove from desktop)** or
**Show** effect; an Action never changes style to get around a blocker. An
Action's Hide is the same as Hide in Displays and stays until Show, unlike a
rule's temporary blackout. Hide (remove from desktop) uses the target's Mirror
onto and Switch monitor to setup from Displays; the editor offers **Set Up in
Displays…** when it's missing and won't save until it's set. **Run** invokes the saved
effect once. The editor also provides its `run-action --action UUID` command for
Shortcuts or Stream Deck. The ID remains stable when the name is edited; deleting
the Action stops that command from working but does not alter the display or its
recovery state.

A Remove Action records the current Remove switch, mirror source and away input
as a reviewed setup. If one changes, the Action is disabled until it is reviewed
and saved again. Experimental features and the target's current readiness are
checked again before each run; a refusal never falls back to Black out. Show
uses the existing recovery evidence and remains available with Experimental
features off. Actions run only when you select **Run** or execute their exact
command. If a command reports `response-lost`, inspect `panelctl app status
--json` before deciding what to do; the request is never retried or queued.
Startup, login, wake, reconnection, Automation, Pause and Restore never run
Actions or undo an Action's manual Hide. For current limitations, see
[Named manual display actions](display-hide-ux.md#named-manual-actions).

![Displays tab with experimental removal setup](displays.png)

![Automations tab with rules and actions](automations.png)

*Rendered from fake display and helper fixtures, not a live hardware trial.*

Closing Settings keeps automation and Black out Hides running. Quitting clears
app-owned covers and stops the watcher, but a removed desktop may remain hidden;
the quit prompt offers **Show and Quit**. Reopen the app to show Settings when
the menu icon is hidden. Recovery problems appear on the affected display (or
above the tiles), with a Review banner on the other tabs and **Review Display
Recovery…** in the menu.

## App automation

```sh
panelctl app enable | disable | toggle
panelctl app status --json
panelctl app blackout-now | restore | sleep-now
panelctl app snooze --for 30m
panelctl app resume
panelctl app open-settings
panelctl app hide | show | toggle-hide --display UUID [--json]
panelctl app run-action --action UUID [--json]
```

Without a standalone install, use the bundled CLI:
`/Applications/PanelCtl.app/Contents/Helpers/panelctl`.

`status`, `hide`, `show`, `toggle-hide` and `run-action` never launch the app. Other commands
start it in the background; only `open-settings` shows a window. `enable`,
`disable` and `toggle` change the Automation master switch; each rule also has
its own enabled flag. Snooze and resume apply to Automation as a whole.
`blackout-now` turns the master switch on and triggers every runnable enabled
rule; it refuses when no rules are on. `restore` restores all automation covers,
never a manually hidden display or monitor input. `sleep-now` keeps its existing
global behavior.

### Scripted Hide and Show

`hide`, `show` and `toggle-hide` press a display's Hide/Show button in the
running app, using its Hide style (see [Hide and Show](display-hide-ux.md)).
Settings → Displays → Scripts shows the exact command. For a Stream Deck button
or a Shortcuts **Run Shell Script** action:

```sh
/Applications/PanelCtl.app/Contents/Helpers/panelctl app toggle-hide \
  --display DISPLAY_UUID --json
```

```json
{ "outcome": "done", "summary": "<desktop result>", "detail": "<input result>", "displays": [ … ] }
```

Replace `DISPLAY_UUID` with the UUID from `panelctl list`, or use the exact
command copied from the app. Keep the exit status if your automation needs to
detect failure or partial success.

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
  "rules": [
    {
      "id": "…", "name": "Desk dimming", "enabled": true,
      "state": "waiting", "summary": "Watching for inactivity",
      "displays": ["DISPLAY_UUID"], "nextAction": "dim", "secondsRemaining": 180
    },
    {
      "id": "…", "name": "Display protection", "enabled": false,
      "state": "disabled", "summary": "Disabled", "displays": ["OTHER_UUID"]
    }
  ],
  "displays": [
    { "targetUUID": "…", "observedState": "hidden-by-panelctl", "operation": "idle", "recoveryNeeded": false },
    { "targetUUID": "…", "observedState": "hidden-by-panelctl", "operation": "idle", "recoveryNeeded": false }
  ]
}
```

The optional `rules` array is additive to protocol 1; old clients may ignore
it. Each entry reports one rule's stable `id`, `name`, enablement, state and
summary, plus optional detail and countdown fields and its target UUIDs. The
existing top-level fields stay aggregate: `enabled` is the master switch,
`state` reflects the highest-priority rule state, and `nextAction` and
`secondsRemaining` describe the soonest rule timer. With exactly one enabled
rule, top-level status text remains unchanged.

The `displays` array includes one status entry per discovered or journaled
target. A disconnected removed display remains listed as unavailable/recovery
needed instead of being silently dropped.

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

Only an explicit Hide/Show command or named Action changes a display. Idle,
startup, login, wake and reconnection never invoke these manual operations. For
a persistent CLI watcher, edit the
[LaunchAgent example](../examples/com.brettinternet.panelctl.blackout.plist).

## Experimental display commands

| Command | What it does | Docs |
| --- | --- | --- |
| `ddc-input` | Read or switch a monitor's input over DDC | [DDC input](ddc-input.md) |
| `ddc-power` | Explicit experimental monitor On/Off; manual recovery may be required | [Power semantics, consent and qualification](ddc-power.md) |
| `mirror` / `unmirror` | Add a public-mirror removal or Show one target | [Mirroring](display-mirroring.md) |
| `away` / `back` | Add a removal plus optional input switch, or Show one target | [Handoff](display-handoff.md) |
| `recovery …` | List, verify and restore journal entries | [Recovery](display-recovery.md) |
| `recovery disable` | Private signal removal; **currently always refuses** | [Display disable](display-disable.md) |

For one removed display, `unmirror --consent-unmirror` and `back --display
UUID` retain the legacy one-target behavior. With several removals, use
`unmirror --display UUID`, `back --display UUID`, or
`recovery restore --display UUID` to Show exactly one. `recovery status` reports
each entry; `recovery verify --display UUID` is read-only and never Shows. An
omitted selector for ambiguous multi-entry verify/restore/unmirror requests is
refused. `mirror` and `away` can add a new removal only beside a healthy session.
The last Show verifies the original pre-first-Hide layout, modes and main
display. Private disable refuses while removals remain, and removals refuse an
unresolved private-disable journal.

Each live topology or DDC write needs a deliberate decision on untested
hardware; consent flags acknowledge risk, they are not qualification. The
recorded CLI cycles qualify only their stated single-target setups; no
multi-display combination is hardware-qualified.

`ddc-power --display UUID --set off --accept-power-risk` acknowledges that
software wake may fail, the physical button may not suffice, and unplugging
monitor power may be required. `--set on` is best effort only; omit `--set` for
one power-state read. Only named `on` (0x01) and `off` (0x04) are supported.
At most one write and one readback; no retry or automatic restoration. Neither
command delivery nor matching readback proves visible panel state. No monitor
is power-qualified. Each live power read/write needs fresh scoped approval, a
present user, accessible physical power and another usable display. See the
[supervised protocol](ddc-power.md#supervised-qualification-protocol).
App power support is [planned within existing Hide/Show](display-hide-ux.md#planned-ddc-power-hide-style),
not a shipped app action or unattended automation feature.

## Limits

- An opaque black window leaves OLED pixels unlit but keeps the display
  electronics on and does not trigger panel compensation. The working overlay
  only reduces output. Use all-display sleep for long unattended periods.
- macOS has no public per-display sleep or disconnect. Normal protection never
  calls private topology APIs. See [feasibility](feasibility.md).
- DDC depends on monitor and connection. `ddc-luminance --set` persists and is
  not restored. `--dim-to` journals captured values, but restoration can be
  delayed by a crash or disconnect. Explicit experimental DDC power is CLI-only,
  may leave the desktop present and has no automatic restoration or guaranteed
  physical recovery. It is never part of blackout, wake, input switching or
  app Hide/Show.
