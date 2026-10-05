# Hide and Show

This is the current app contract. **Settings → Displays** shows display tiles
in arrangement order. Select a tile to see its state, Hide/Show action, setup,
inline result and Scripts command. The menu's **Hide _display_** / **Show
_display_** actions and [scripts](#scripting) use the same per-display behavior.
**Automation** configures idle protection; **General** holds app preferences
and the Experimental features gate.

## Hide styles

| Style | What happens | Configuration |
| --- | --- | --- |
| **Black out** (default) | An opaque app-owned window covers the display; its desktop stays put | Leave Remove from desktop off |
| **Remove from desktop** | The display is [mirrored](display-mirroring.md) onto another, so windows move off it; optionally switch the monitor to another computer's input | Enable Experimental features, then the display's Remove from desktop switch |

Neither style removes the Mac's signal, puts the monitor in standby, or
guarantees OLED maintenance. Hide is independent of the displays selected for
Automation. There is no separate Hide-style picker.

### Black out

Hide keeps the cover until Show, or Escape with the pointer on that display.
Ordinary input does not show it. Multiple displays can be blacked out, including
the main or built-in display, but Hide refuses the last visible display.
Targets need a unique stable UUID and must be online, active and awake.

Closing Settings leaves covers in place. Sleep/wake and display changes keep
the session's Hide intent; a disconnected display is covered again when it
reconnects. If macOS starts mirroring it, or no other display remains connected,
PanelCtl shows it. A failed cover is reported inline, not silently treated as
success. Quit, crash and relaunch clear these app-owned covers; Black out Hide
is not persisted as a recovery transaction.

Automation skips displays hidden this way. Its **Restore** action and timeouts
never show them. Black out Hide does not switch monitor inputs or dim via DDC.

## Experimental features

In **General**, turn on **Experimental features** and accept the prompt. The
flag persists; enabling it again after turning it off asks again. This is
configuration-time consent, not a dialog before every Hide or Show. It covers
public mirroring and optional input switching, not private disconnect.

Turning the flag off hides removal setup and makes subsequent Hide actions use
Black out instead. It does not show an already removed display, erase its saved
setup or discard its recovery journal. Show and journal-driven recovery stay
available with the flag off.

### Remove from desktop

Select an eligible display in **Displays** and turn on **Remove from desktop**.
The setup then shows:

| Control | Meaning |
| --- | --- |
| **Mirror onto** | Defaults to main for other targets; a main target requires an explicit source |
| **This Mac's input** | Read-only DDC detection; Detect Again appears when detection needs attention |
| **Switch monitor to** | Don't switch, a named input, or Other… with a decimal/hex input code |

Only awake, active external displays with a stable ID are eligible for removal;
built-in displays remain ineligible, including when main. A main display has no
default mirror source: choose another available, awake source before Hide. Other
displays retain their existing default source, and saved configurations are not
rewritten. When mirroring the main display, macOS decides where the menu bar,
Dock, windows and Spaces go; the main display may stay, move to the source or
move elsewhere. Observe the result rather than assuming which display becomes
main. One [main-target CLI cycle](display-mirroring.md#observed-main-target-cycle-2026-10-05)
qualified AW3423DW onto AW3425DW and exact restoration; other combinations
and live app/script paths remain unqualified. Setup is frozen while
a removal journal is unresolved or an operation/cleanup is pending.

- Hide captures recovery, switches the input if requested, then mirrors. Show
  restores and verifies the saved layout first, then switches back when a valid
  return input is known. If not, use the monitor's buttons.
- Opening the setup reads This Mac's input once per app session even with
  **Don't switch**. A zero reading or a reading of the configured away input
  never replaces the saved return input. Detection is read-only, not a write.
- With **Don't switch**, the Hide/Show operations themselves make no DDC
  requests. Use the monitor's input button if needed.
- Show restores public layout and modes, not HDR, color profiles, rotation,
  windows or Spaces. Resolution, refresh rate or HDR can change while hidden.
- The recorded [mirroring](display-mirroring.md#observed-cycle-2026-10-04)
  and [handoff](display-handoff.md#observed-round-trip-2026-10-04) cycles used a
  non-main target and main source. The later main-target CLI mirror/unmirror
  cycle used AW3423DW onto AW3425DW; it did not qualify input switching.
  Each live mirror and restore write requires separate scoped human approval.

### Planned DDC power Hide style

**Not shipped in the app.** The explicit [DDC power CLI](ddc-power.md) is
implemented but has no hardware-qualified monitor. The design below extends
this contract's current display tiles and per-display setup; it is not a
standalone future Power UI.

- Add **Monitor power · Experimental** as an opt-in choice within the selected
  display's existing Hide-style setup, alongside Black out and Remove from
  desktop. Evolve the current removal switch only as needed to express these
  mutually exclusive styles; preserve Black out defaults and existing removal
  configurations. No top-level Power buttons, parallel menu or settings page.
- Availability requires a uniquely identified external monitor and reachable
  DDC power support. Built-in, ambiguous, absent, unsupported and unreadable
  targets show an inline reason and disabled power Hide, not an automatic
  fallback. A readable value is not hardware qualification; show that status.
  Choosing or inspecting setup must not silently issue a power command.
- General **Experimental features** must be on to configure or initiate this
  style. Require separate, display-specific power consent in this setup:
  software wake may fail; the physical button may not suffice; unplugging
  monitor power may be required; harmlessness and physical recovery are not
  guaranteed. Mirror/input consent and the existing General prompt are not
  power consent. Show the selected monitor, exact Off semantics and recovery
  warning beside the opt-in; no consent inferred from existing preferences.
- The same tile and menu **Hide** action requests one Off; **Show** requests
  one best-effort On when that exact target and transport are available.
  Power-only Hide never mirrors, switches inputs or privately disconnects.
  The Mac desktop may remain and windows may stay on the dark screen.
- Use existing inline results and recovery details to distinguish already
  reported, matching readback, unverified transport loss and failure. Do not
  label the physical panel Off/On as proven from DDC alone. A tile may report
  “Power-off requested · check monitor”; uncertain output needs recovery, not
  silent success. No automatic retry or alternate value.
- Before attempting Off, retain the exact target and power-operation evidence
  for the existing recovery presentation, including when it disappears from
  enumeration. This is planned app persistence, **not** a CLI journal today.
  Relaunch only reports outstanding evidence; it never powers on or off.
  Keep the selected tile's Show/manual recovery details, shared recovery
  banner and **Review Display Recovery…** route. Do not repurpose topology
  restore as power recovery or bind a missing target to another monitor.
- If DDC cannot reach the target, Show explains manual recovery using physical
  controls and possibly power removal; it does not claim restoration. Keep
  recovery visible until usable output is confirmed, independently of
  readback. Changing Hide style or turning off Experimental features must
  neither discard outstanding evidence nor change the pending Show operation
  into a blackout/topology action. Best-effort Show and manual recovery remain
  accessible with the gate off; configuration changes cannot strand recovery.
- Count outstanding power-hidden or uncertain targets as unavailable for the
  last-visible rule. Require another usable screen before Off. Quit/relaunch,
  wake and hotplug never repeat power commands; quit warns about unresolved
  power recovery in the existing recovery flow.
- Preserve current automation behavior and default styles. Power is not an
  idle/empty-display treatment or a fallback from input switching. App scripts
  and unattended power automation remain deferred: selecting this style must
  not silently make existing scripted Hide/Show emit power writes.

This planned style needs its own implementation and supervised qualification;
the [power protocol](ddc-power.md#supervised-qualification-protocol) separates
software results, visible behavior, DDC wake and physical recovery.

### Private disconnect

The separate **Private disconnect · Experimental** section in Displays does
not change either Hide style. It appears only for the qualified display while
Experimental features are on, or while a disconnect journal exists. It supports only the recorded Dell/firmware/host/
build/connection, requires fresh per-operation consent, and holds a fixed
15-second watchdog lease. General experimental consent is insufficient. Turn
off automation and show hidden displays first. Journal-driven reconnect stays
available without an enumerable target or the experimental gate. No script,
idle, startup or wake path disconnects a display. See
[qualification and recovery limits](display-disable.md#app-controls).

## Coexistence and safety boundaries

- Only one display can be removed from the desktop at a time. An unresolved
  journal blocks another removal; it is never overwritten to start one.
- Other independent displays can still use Black out. A verified PanelCtl
  removal source can also be blacked out when another display remains visible;
  its cover is copied to the removed target on the Mac's input. Displays mirrored
  outside PanelCtl still refuse Black out, and removing onto a blacked-out source
  is refused.
- Removed and blacked-out displays do not count as visible for Black out's
  last-visible check. Showing the removed display leaves its source's manual
  cover in place; showing the source removes only its manual cover and leaves the
  removal intact.
- Only an explicit person or script action starts Hide. Idle, startup, login,
  wake and reconnection never initiate a new removal or input switch. Re-covering
  a Black out Hide within the same session preserves an existing explicit Hide.
- **Restore** only removes automation blackout/dimming; it never shows a hidden
  display or switches inputs. **Show** acts on the selected hidden display.
- A removed desktop can survive quitting. The quit prompt offers **Show and
  Quit**; failed restoration keeps the app running rather than reporting success.
- External CLI watchers and other display apps are not coordinated; stop them
  before topology work. No automatic logout, reboot or guessed identity is a
  recovery strategy.

## States and recovery

| Tile state | Meaning / action |
| --- | --- |
| On | Normal desktop; Hide, or an inline reason it cannot run |
| Hidden | Blacked out, or removed with a healthy journal; Show |
| Hiding… / Showing… / Busy | Operation in progress; no cancel, queue or automatic retry |
| Blacked out | Automation's cover, not a Hide; Restore controls it |
| Asleep / Unavailable | Wake or reconnect the display |
| Mirrored | Mirrored by macOS outside PanelCtl; fix in System Settings → Displays |
| Needs recovery | Read the reason and recovery details; Show only when checks permit it |

Removal state comes from observations and the journal, not the saved switch.
A journaled target remains visible as a tile even when disconnected. Reconnect
the same hardware, then **Check Again**; PanelCtl does not rebind recovery to a
different monitor. If macOS restores the captured layout itself, PanelCtl
verifies it and resolves the journal without mirroring again.

A healthy removed display has recovery details on its selected tile, not an
error banner. Problems appear on the affected tile, or above the tiles if no
target can represent them. **Automation** and **General** show a recovery banner
with **Review…**. The menu offers **Review Display Recovery…**; reopening the app
from Finder focuses recovery even when the menu icon is hidden. Login launch
only reports it. Custom CLI journals are not scanned: use
`panelctl recovery restore --journal <path>` and the [recovery guide](display-recovery.md).

## Inline results and failures

The selected display's state reports the desktop result. Warnings, input
outcomes and a copyable undo-input command appear below it, without a completion
dialog. Monitor input and desktop success are independent:

| Case | Desktop | Monitor input |
| --- | --- | --- |
| Input verified, hide succeeds | Hidden | Switched |
| Input unverified | Hidden | Check monitor; no retry |
| DDC unavailable | Hidden | Skipped; use monitor buttons |
| Input write fails | Not hidden; journal kept | Failed, with undo command when available |
| Input switched, mirror fails | Failed; recovery offered | Undo command shown; no automatic rollback |
| Show: topology fails | Not restored; no input write | — |
| Show: input fails | Restored | Failed; repeated scripted Show is a no-op, not another write |

The result and undo-input command are session-only. After a crash PanelCtl does
not reconstruct or guess an input rollback from missing outcome evidence.

## Scripting

**Displays → Scripts** provides a copyable command using the CLI bundled in the
app. Use it in Stream Deck or Shortcuts with an action that runs a shell command:

```sh
/Applications/PanelCtl.app/Contents/Helpers/panelctl app toggle-hide --display DISPLAY_UUID --json
```

Use `hide` or `show` instead of `toggle-hide` to request a particular state.
These commands require the app to be running; they never launch it, open a
confirmation dialog or bypass configuration/identity/recovery checks. Already
in the requested state is a `no-op` and does not repeat an input switch. Requests
are not queued or resent. After a lost response, inspect `app status --json`
before deciding what to do. See [exit codes and status fields](usage.md#scripted-hide-and-show).

## Automation cleanup

If brightness restoration cannot be confirmed, **Retry Automation Cleanup** is
available in the menu and in both **Displays** and **Automation**, even with
automation off and no desktop hidden. It only restores saved luminance-journal
values; it never hides/shows a display, switches inputs or starts blackout.
Automation resumes with a fresh countdown only if enabled and no other recovery
block remains.

A failed retry retains its reason and removal block across relaunch. Reconnect
unavailable monitors first. A locked, unreadable or nonempty luminance journal
is not successful cleanup. After a helper exits, its windows are gone; an empty
journal checked under the luminance lock proves brightness cleanup, even if the
helper omitted its final status report.

## Automation while hidden

While a display is removed, automation pauses except for a source-only overlay:
if the source is selected in Automation and automation is enabled and not
snoozed, it may be blacked out. The removed target also looks black on the Mac's
input; it is never itself an overlay target. Manual Hide can independently
black out a verified PanelCtl source when another display remains visible. That
session-only Hide owns the cover instead of Automation; its overlay is stopped
while the source is hidden and cannot show or double-cover it. Showing the source
removes only Hide's cover; any eligible source overlay can resume separately.

| Event | Behavior |
| --- | --- |
| Remove while automation is active | Stop treatment and restore brightness first; refuse on cleanup failure |
| Idle / Black Out Now while removed | Source-only overlay with verified journal/topology; no DDC dimming, empty-display blackout or follow-up sleep |
| Restore interval while removed | Overlay-only timeout, capped at 24 hours (also for until activity); no sleep or Show |
| Activity / Escape / Restore | Remove only automation's overlay; display stays removed |
| Show removed display | Remove the overlay first, restore layout, then restart normal automation with a fresh countdown |
| Wake / hotplug | Re-verify; never re-mirror or retry input; changed identity keeps recovery |
| Crash / relaunch | Journal survives; inspect it, never capture over it |

Under the operation and journal locks, the overlay requires a journal in
`mirrored` state, the exact target mirrored onto the exact identity-matched
source, and Show still possible. Otherwise it is removed. Standalone
`panelctl blackout` still refuses mirrored displays.

### Supervised source Black out check (2026-10-05)

On Mac17,14 / macOS build 26A434, app commit `a3fa961` was checked with
S2721DGF (`09084682-3c42-4455-aab8-126a7431125b`) removed onto main
AW3423DW (`1fc57e99-de7c-4daf-b896-3b512cee064f`). Each Hide/Show was
separately approved. K272HUL and AW3425DW remained usable throughout.

The initial removal used the installed app and verified the configured HDMI 1
input switch (`0x11`). An initial source Hide reached that older app and was
refused without covering anything. After explicitly quitting it without Show,
the exact worktree executable was launched and its process path verified; it
recognized the existing removal journal.

In the new build, source Black out returned `done` / `Hidden.` for AW3423DW,
with both source and target reported `hidden-by-panelctl` and automation
suspended. The user confirmed the source was black and the independent screens
usable. Show of S2721DGF returned `done`, verified DisplayPort 1 (`0x0F`), and
restored its desktop while the user confirmed AW3423DW stayed black. Source
Show then returned `done`; the user confirmed all four displays usable again.
Journal `E9181195-A9AE-4181-A992-C74CE9E7A5E4` ended `restored` (`unmirror`).
The test app was quit without changing saved preferences or the installed app.

This qualifies that source-cover and target-then-source Show sequence only.
Source-first Show, lifecycle cases and last-visible refusals have fake-backed
coverage, not additional live trials. The target was on HDMI during the cover,
so copying the cover onto a target still on the Mac input was not visually
checked. No private setter, monitor-power write or disruptive recovery was used.

## Keyboard and accessibility

Cmd-comma opens Settings; Cmd-1, Cmd-2 and Cmd-3 select Displays, Automation and
General. Native controls expose display names and states to accessibility.
Tab/Shift-Tab, Space and arrow keys navigate controls according to macOS keyboard
navigation settings. There is no global Hide hotkey. Disabled actions have a
visible explanation, not only a tooltip or color; errors and recovery commands
are selectable text. Results stay on the selected display rather than opening
a modal completion dialog.
