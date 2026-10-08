# Hide and Show

Select a display in **Settings → Displays** and press **Hide**. The menu's
**Hide _display_** / **Show _display_** items and [scripts](#scripting) do the
same thing.

## Hide styles

| Style | What happens | How to choose it |
| --- | --- | --- |
| **Black out** (default) | A black window covers the display; its desktop stays put | Default, or `panelctl app hide --display UUID --style black-out` |
| **Remove from desktop** | The display [mirrors](display-mirroring.md) another, so windows move off it; optionally switches the monitor's input | Experimental features, then the display's **Remove from desktop** switch |

Neither style turns the monitor off or cuts its signal.

### Black out

The cover stays until Show, or Escape with the pointer on that display. Input
doesn't remove it. `app hide` and `app toggle-hide` accept `--style black-out`
to force this cover for one request even when that display is configured for
**Remove from desktop**. It does not edit the saved Hide settings. You can black
out several displays, but never the last visible one. Covers survive sleep, wake
and reconnects, and end on quit. Automation skips blacked-out displays, and
**Restore** doesn't show them.

### Keep windows off while blacked out

In **Settings → Displays → Window relocation**, opt in separately for each
stable display identity. The option defaults off and is independent of both Hide
and **Remove from desktop**; enabling Hide never enables window movement. Choose
**Automatic** (current main display, then stable UUID order) or one exact
destination. If that destination is asleep, disconnected, covered, mirrored,
removed, or has an ambiguous identity, movement pauses instead of choosing a
replacement. Monitor power-off alone is not a PanelCtl blackout.

While PanelCtl is covering the opted-in display—through manual Hide, an Action,
or Automation—the app rescans once per second and moves newly appearing or
returning eligible windows off it. A healthy scan considers new windows within
one tick plus the current pass (up to one second per application and one in-flight
250 ms Accessibility call); this is a service bound, not a promise that every app
will accept a move. Refusing, returning, or actively dragged windows back off
with a bounded 1, 2, 4, 8, 16, then 30 second delay. Armed means opted in but
visible; Enforcing means covered and eligible; Paused includes the reason. The
Displays settings, menu, and status stream report state and last moved/failed
counts. Each pass attempts at most 64 windows; remaining windows wait for later
passes. Before each setter, managed helpers must acknowledge relocation suppression
within one second, otherwise movement pauses. Helper replacement invalidates the
old permission to write.

Only ordinary movable windows with public, unique on-screen evidence on the
current Space can move. Full-screen, minimized, other-Space, nonmovable, vanished,
or unverified windows are skipped; titles and persistent window identifiers are
not stored. The app checks Accessibility permission in the background and never
prompts. Grant it only with the explicit **Allow Accessibility** control in
**Settings → Automations → Actions**. Coverage ending, sleep/topology changes,
permission loss, recovery, or turning the option off cancels pending work. An
already-dispatched setter may finish; windows are never moved back. Relaunch only
reevaluates current state and never starts a blackout or replays moves.

This ongoing option reuses the one-shot **Move windows** behavior in [Actions](#named-manual-actions),
but it is configured per display and continues while that display is covered.
It does not trigger Hide, extend blackout, synthesize input, or count a move as
user activity. **Remove from desktop** already lets macOS relocate windows, so
it does not need this option. Keyboard input, pointer restoration and time limits
still end blackout during a move. If a write's final geometry is uncertain, or a
helper's 256-window provenance budget overflows, that helper conservatively stops
using window occupancy to clear empty-display rearm latches for the rest of its
session. Real pointer occupancy still clears them; moving windows away afterward
cannot by itself rearm blackout.

## Experimental features

Turn on **General → Experimental features** and accept the prompt once. This
enables **Remove from desktop** with optional input switching.

Turning it off makes new Hides black out instead. Displays already removed stay
removed, and Show and recovery keep working.

### Remove from desktop

Turn on **Remove from desktop** for an external display, then set:

| Control | Meaning |
| --- | --- |
| **Mirror onto** | The display to mirror onto. Defaults to the main display; hiding the main display needs an explicit choice |
| **This Mac's input** | Detected over DDC (read-only) |
| **Switch monitor to** | Don't switch, a named input, or a custom input code |

```text
Hide: save layout → switch input (optional) → mirror
Show: restore layout → verify → switch input back (optional)
```

- Only awake external displays with a stable ID can be removed.
- You can remove several displays, in any order, onto shared or separate
  sources. A removed display can't be a source, and a source can't be removed
  until its targets are shown.
- Show returns one display and leaves the others removed. While others are
  still removed, macOS may place it slightly off its saved position; the last
  Show restores the exact original layout and main display.
- Hiding the main display lets macOS decide where the menu bar, Dock and
  windows go.
- Show restores layout and display modes, not HDR, color profiles, windows or
  Spaces.
- With **Don't switch**, Hide and Show send no DDC commands. Use the monitor's
  input button if needed.

### Full disconnect

**Full disconnect · Experimental** is a separate, manual action that drops the
Mac's signal using a private API. It is not a Hide style. It needs fresh
consent each time and reconnects automatically after 15 seconds. See
[private display disable](display-disable.md#app-controls).

## Named manual actions

**Automations → Actions** stores named workflows of 1–8 steps. Each step targets
a display with **Hide (black out)**, **Hide (remove from desktop)**, **Show** or
**Move windows**. A display may appear once in the Hide/Show class and once in
the separate Move class, so Hide and Move can share a source in either order.
Hide never moves windows; Move never changes Hide state.

```sh
panelctl app run-action --action ACTION_UUID --json
```

- Runs only from **Run** or this command, never from rules, login or wake. Action steps keep their saved effects; `--style` applies only to direct Hide and Toggle Hide CLI requests.
- Before any change, PanelCtl checks every step. A refusal names the step and
  changes nothing.
- Steps run in order. Disconnected targets and targets verified hidden by the
  other Hide style are skipped with a visible reason, without showing them or
  switching styles. Other failures stop the run; earlier steps stay done.
- Identity ambiguity, changed metadata, unverified recovery, and last-visible-display
  safeguards still block. A skipped step never becomes a write during that run.
- A Remove step saves the display's setup. If that setup changes later, review
  and save the Action again.
- Move windows is a one-shot relocation of ordinary movable windows on the
  current Space. It does not activate apps, switch Spaces, or restore windows on
  Show; windows already off the source stay untouched. Full-screen, minimized,
  vanished, nonmovable and publicly unverified windows are skipped with reasons.
- Move windows requires Accessibility permission granted by the explicit
  **Allow Accessibility** button in **Settings → Automations → Actions**. CLI and
  background runs report missing or stale permission and never prompt. Results
  include privacy-safe moved/skipped/failed counts and reason codes; window titles
  are not stored.
- `done`: eligible steps finished. Per-step `skipped` results explain unavailable
  targets. `no-op`: nothing needed to change; when steps were skipped, the summary
  says “Nothing to do.” `partial`: some steps changed, then the run stopped.

## Saved display identity

Actions and Remove from desktop settings follow the monitor across reconnects
and restarts, even when macOS assigns a new numeric display ID. Existing saved
settings load automatically; you don't need to recreate Actions or input choices.
PanelCtl requires exactly one matching UUID with the same vendor, model and
serial values. Names and desktop positions aren't used to choose a replacement.
Duplicate or changed identities remain blocked with a specific reason. Missing
Action targets can be skipped only when no outstanding recovery involves them;
other saved-display operations still refuse missing identities.

Each new operation captures current display IDs. An Action keeps those captured
identities for its entire run; a connection change stops it instead of choosing
new IDs mid-run. A step checked as already complete cannot later become a write.
Recovery journals and pending operations are never rebound to new IDs or a new
session. Unresolved recovery still needs attention before conflicting work.

## Rules and hidden displays

Automation rules never hide, show, mirror or switch inputs. Rules skip hidden
displays and keep running on the others. While a display is removed, rules use
a black window only: no DDC dimming, and **Sleep** becomes Restore.

## States

| Tile state | Meaning |
| --- | --- |
| On | Normal; Hide available |
| Hidden | Blacked out or removed; Show available |
| Hiding… / Showing… / Busy | In progress; no cancel or queue |
| Blacked out | An automation cover; **Restore** ends it |
| Asleep / Unavailable | Wake or reconnect the display |
| Mirrored | Mirrored outside PanelCtl; fix in System Settings → Displays |
| Needs recovery | Read the reason; Show when allowed |

Removed displays stay listed even when disconnected. Reconnect the same
monitor, then **Check Again**. Recovery problems also appear as a banner and in
the menu as **Review Display Recovery…**. See [display recovery](display-recovery.md).

If PanelCtl can't confirm that dimmed brightness was restored, automation
pauses and **Retry Automation Cleanup** appears. It only restores saved
brightness.

## Results

Desktop and input results are reported separately on the selected display:

| Case | Desktop | Input |
| --- | --- | --- |
| Everything works | Hidden | Switched |
| Input can't be confirmed | Hidden | Check the monitor |
| No DDC | Hidden | Skipped; use monitor buttons |
| Input write fails | Not hidden | Failed, with a switch-back command |
| Mirroring fails after input switched | Failed; recovery offered | Switch-back command shown |
| Show: layout fails | Not restored; journal retained | May already have switched; outcome shown |
| Show: input fails | Restored only if fresh layout/mode checks pass | Failed |

Explicit Show returns the configured Mac input before restoring the desktop,
then verifies the post-input layout. Online status alone never triggers Show.
A missing saved mode names the display and mode to recover; switch its input
manually if DDC is unavailable, then retry Show.

## Scripting

**Displays → Command** shows a copyable command for Stream Deck or Shortcuts:

```sh
/Applications/PanelCtl.app/Contents/Helpers/panelctl app toggle-hide --display DISPLAY_UUID --json
```

Use `hide` or `show` for a specific state. Add `--style black-out` to `hide` or
`toggle-hide` when a script needs a black cover instead of a display's configured
Remove from desktop style; this is per-request and does not edit saved preferences.
The Scripts copy command remains style-neutral, and Action steps keep their saved
effects. The app must be running. See [exit codes and status](usage.md#scripted-hide-and-show).

`panelctl app blackout-now` and the menu's Blackout Now item are retired; the
command exits 2 and older CLIs are refused. They triggered every enabled
Automation rule at once. Use `app hide --display` for one display,
`app run-action --action` for a saved Action, or `app run-rule --rule` (or the
menu's Run rule submenu) to run one saved Automation rule once.

## Keyboard

Cmd-, opens Settings; Cmd-1/2/3 switch tabs. In editors, Return saves and
Escape cancels. There is no global Hide hotkey.
