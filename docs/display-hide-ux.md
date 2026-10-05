# Hide and Show

Each display tile in **Settings → Displays** has a Hide/Show button. Hide works
in one of two styles:

| Style | What happens | Availability |
| --- | --- | --- |
| **Black out** (default) | An opaque app-owned window covers the display; the desktop stays put | Always |
| **Remove from desktop** | The display is [mirrored](display-mirroring.md) onto another, so windows move off it; optionally the monitor switches to another computer's input | Experimental features on |

Neither style removes the Mac's signal, puts the monitor in standby, or
guarantees OLED maintenance.

## Remove from desktop

Turn on **General → Experimental features** and accept the one-time prompt.
Then, on the display's tile:

```text
Hide                  [Black out | Remove from desktop]
Mirror onto           [main display ▾]          default: the only tested source
Switch monitor to     [Don't switch | HDMI 1 | … | Other…]
This Mac's input      DisplayPort 1             read once over DDC (read-only)
```

- Hide mirrors the display and, if an input is chosen, switches the monitor to
  it first. Show restores the saved layout, then switches back to the Mac's
  input.
- "This Mac's input" is read automatically. A reading of 0, or of the input Hide
  switches to, never replaces it.
- With **Don't switch**, PanelCtl makes no DDC requests; use the monitor's
  input button.
- Show restores public layout and modes only, not HDR, color profiles,
  rotation, windows or Spaces. Resolution, refresh rate or HDR can change while
  hidden.
- Tested only with the setup in [mirroring](display-mirroring.md#observed-cycle-2026-10-04)
  and [handoff](display-handoff.md#observed-round-trip-2026-10-04).

Turning Experimental features off hides this configuration and refuses new
Remove-from-desktop Hides. Show and recovery stay available whenever a journal
exists.

## Rules

- One display can be removed from the desktop at a time; an unresolved
  [recovery journal](display-recovery.md) blocks every new Hide.
- Hide never covers or removes the last usable display.
- Only a person or a [script](usage.md#scripted-hide-and-show) hides a display.
  Idle, startup, login, wake and reconnection never hide, show or switch inputs.
- **Restore** in the menu only removes automation blackout or dimming. It never
  shows a hidden display or switches inputs.
- Black out hides use app windows, so quitting or a crash shows those displays.
  A removed desktop survives quitting; the quit prompt offers **Show and Quit**.

## States

| Tile state | Meaning | Action |
| --- | --- | --- |
| Separate | Normal desktop | Hide, or a reason it can't |
| Hiding… / Showing… | Operation running | None; other requests report busy, no cancel or retry |
| Hidden by PanelCtl | Blacked out, or mirrored with a healthy journal | Show |
| Unavailable | Display disconnected, no journal | Reconnect; nothing is rebound to another display |
| Recovery needed — target unavailable | Journal owns a disconnected display | Reconnect the same hardware, then Check Again |
| Mirrored outside PanelCtl | Someone else mirrored it | Fix in System Settings → Displays |
| Recovery needed: *reason* | Journal or verification failed | Review the recovery card; Show only when checks pass |

State comes from current observations plus the journal, never from saved
preferences. A stale or unknown observation is recovery-needed. If macOS
restores the layout itself (for example after wake), PanelCtl verifies it
against the snapshot and resolves the journal without mirroring again.

With unresolved recovery, a banner on every Settings tab links to the recovery
card, the menu shows **Review Display Recovery…**, and reopening the app from
Finder focuses that card even when the menu icon is hidden. Login launch only
reports it. Custom CLI journals aren't scanned; recover them with
`panelctl recovery restore --journal <path>`.

## Results and failures

When an input switch is requested, results report **Desktop** and **Monitor
input** separately.

| Case | Desktop | Monitor input |
| --- | --- | --- |
| Input verified, hide succeeds | Hidden | Switched |
| Input `unverified` | Hidden | "Input change unverified — check monitor" |
| DDC unavailable | Hidden | Skipped; use monitor buttons |
| Input write fails | Not hidden; journal kept | Failed, with undo command |
| Input switched, mirror fails | Failed; journal recovery offered | Undo command shown; no automatic rollback |
| Show: topology fails | Not restored; no input write | — |
| Show: input fails | Restored | Failed; repeating Show is a no-op, not another DDC write |

The undo-input command is shown but not persisted. After a crash PanelCtl
doesn't guess the previous input.

## Automation while hidden

While a display is removed from the desktop, automation pauses except for one
case: if the mirror source is selected in Automation and automation is enabled
and not snoozed, the source may get an overlay blackout. The mirrored target
then also looks black on the Mac input. The target is never itself an overlay
target.

| Event | Behavior |
| --- | --- |
| Hide while automation is active | Stop treatment and restore brightness first; refuse if cleanup fails |
| Idle / Black Out Now while hidden | Source-only overlay when the journal and topology verify; no DDC dimming, empty-display blackout or follow-up sleep |
| Restore interval while hidden | Restore-only overlay timeout, capped at 24 hours ("until activity" uses 24 hours); no sleep or Show at timeout |
| Activity / Escape / Restore | Remove only the overlay; display stays hidden |
| Show | Remove the overlay first, then restore; afterward normal automation restarts with a fresh countdown |
| Wake / hotplug | Re-verify; never re-hide or retry input; changed identity keeps the recovery entry |
| Crash / relaunch | Journal survives; relaunch inspects it and never captures over it |

The overlay requires, under the operation and journal locks: an unresolved
mirror journal in `mirrored` state, the exact target observed mirrored onto the
exact source, a separate identity-matched source, and Show still possible.
Anything else removes the overlay. Plain `panelctl blackout` still refuses
mirrored displays. External CLI watchers and other display apps aren't
coordinated; stop them first.

## Accessibility

Native controls in reading order: identity → state → configuration → action.
Tab/Shift-Tab moves between enabled controls, Space activates, arrows navigate
menus and pickers, Cmd-comma opens Settings. There's no global Hide hotkey.
Disabled actions have a visible explanation, not only a tooltip or color.
Errors are selectable text. After an operation, focus returns to the action; on
error it moves to the recovery summary.
