# Hide and Show

This is the current app contract. **Settings → Displays** shows display tiles
in arrangement order. Select a tile to see its state, Hide/Show action, setup,
inline result and Scripts command. The menu's **Hide _display_** / **Show
_display_** actions and [scripts](#scripting) use the same per-display behavior.
**Automations** configures named idle protection rules; **General** holds app
preferences and the Experimental features gate.

## Hide styles

| Style | What happens | Configuration |
| --- | --- | --- |
| **Black out** (default) | An opaque app-owned window covers the display; its desktop stays put | Leave Remove from desktop off |
| **Remove from desktop** | The display is [mirrored](display-mirroring.md) onto another, so windows move off it; optionally switch the monitor to another computer's input | Enable Experimental features, then the display's Remove from desktop switch |

Neither style removes the Mac's signal, puts the monitor in standby, or
guarantees OLED maintenance. Hide is independent of the displays selected for
Automations. There is no separate Hide-style picker.

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

## Automation rules

The Automations tab keeps its master switch and global snooze. Each named rule
has its own stable identity, enabled state, display selection, inactivity delay,
optional empty-display add-on, blackout/dimming settings and Afterward behavior. The
migrated **Display protection** rule appears without changing its saved
settings. **Add Rule…** and **Edit…** open a draft sheet: **Save** applies the
changes, while **Cancel** discards them. The rule list states the actual effect,
targets and Afterward behavior; conflicts are refused inline, and missing saved
targets remain visible as unavailable. When any rule sleeps displays, the global
PanelCtl display-sleep timer setting appears separately from rule settings.

Pause/Resume, the master switch and Restore stay global. The menu keeps no rule
list; **Black Out Now** reflects the effects of enabled rules. These shipped
rules perform automatic display protection only. Scheduled triggers and
arbitrary action chains are deferred. Named manual Actions are separate,
explicitly invoked operations; they are never rule actions or rule triggers.
Unattended Hide/Show, topology changes, monitor-input writes, power writes and
private disconnect remain unavailable as rule actions.

Each enabled, runnable rule uses its own existing blackout helper and brightness
journal. Two enabled rules may not overlap by display UUID (UUID comparison is
case-insensitive), and an **All displays** rule conflicts with every other
enabled rule. There is no priority or winner: persisted conflicts block every
involved rule and identify the other rule. Disabled rules may overlap.

For conservative all-display checks, displays selected by sibling enabled rules
count as already covered. If enabled rules together cover every usable display,
each rule must use **Restore** or **Sleep** afterward. The helper rechecks this
against the current display inventory when it treats a rule, so hotplug or
missing displays cannot bypass the safety limit. A sibling rule is not a Hide:
empty-display pointer safety still uncovers its cover when the pointer moves.

Restore, timeout, Escape, disable, deletion and pausing stop only automation
covers; they never show a manually hidden or removed display or switch monitor
inputs. **Sleep** is a global follow-up: the first rule to reach its deadline
sleeps displays once, while other helpers suspend for display sleep and require
fresh input after wake. Cleanup checks cover the legacy brightness journal,
each rule journal and journals of deleted rules. An unresolved journal blocks
all rules until verified cleanup succeeds.

### Named manual actions

**Settings → Automations → Actions** stores named, one-display commands with a
stable ID. Choose exactly **Black out**, **Remove from desktop** or **Show**,
then deliberately select **Run** or invoke the action's copied
`panelctl app run-action --action UUID` command. Rename keeps the ID. Deleting an
Action does not change the target's state or discard its recovery evidence.

The selected effect is fixed for each run. A blocked Remove Action is refused,
never converted to Black out. Remove requires Experimental features and records
the target's current Remove switch, mirror source and away input when saved. A
change to any reviewed field marks the Action **Needs review**; save the Action
after inspecting the current Displays setup. Dynamic return-input detection is
not a reviewed field. Each run rechecks the target's full stable identity,
current setup, safety readiness, recovery state and automation cleanup before
using the existing Hide/Show implementation.

Show uses the existing recorded recovery for exactly its selected target and
remains available after setup changes or Experimental features are turned off.
Deleting an Action does not remove the ordinary tile/menu Show or recovery path.
Actions run only on an explicit Run or exact command. Startup, login, wake,
reconnection and Automation never run them. Automation Pause, Restore, timeout,
Escape and activity affect only automation covers; they do not trigger an
Action or show an Action-hidden display.

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
rewritten. Multiple eligible targets can be removed in one session, in any
order and onto shared or distinct sources. A removed target cannot be another
removal's source, and a display already serving as a source cannot itself be
removed until those targets are shown. When macOS moves the main display or
rearranges origins, PanelCtl records each pre-operation topology and preserves
the original pre-first-Hide baseline. Setup for other displays stays editable;
only the removed target or the display whose Hide/Show is in progress is frozen.
A recovery-needed entry blocks new removals until recovery is resolved.

When mirroring the main display, macOS decides where the menu bar, Dock, windows
and Spaces go; the main display may stay, move to the source or move elsewhere.
Observe the result rather than assuming which display becomes main. One
[main-target CLI cycle](display-mirroring.md#observed-main-target-cycle-2026-10-05)
qualified AW3423DW onto AW3425DW and exact restoration; it does not qualify
multi-display sessions. New combinations, app/script multi-removal and source
arrangements remain unqualified until separately approved live trials.

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

### Full disconnect

The separate **Full disconnect · Experimental** section in Displays does
not change either Hide style. It appears for every selected display while
Experimental features are on, or while a disconnect journal exists. Runtime
checks permit eligible non-main external physical displays without a monitor
allowlist; main/built-in displays show a refusal. Strict identity, native-driver,
survivor and verified ABI requirements remain. Each operation warns that this
monitor may not recover automatically, requires fresh consent, and holds a fixed
15-second watchdog lease. General experimental consent is insufficient. Turn
off automation and show hidden displays first. Journal-driven reconnect stays
available without an enumerable target or the experimental gate. No script,
idle, startup or wake path disconnects a display. See
[qualification and recovery limits](display-disable.md#app-controls).

## Coexistence and safety boundaries

- Healthy removals can coexist in one atomically saved session; each target has
  its own write-ahead topology, tile/menu/script action and status. Show acts on
  only the selected target; other removals remain hidden. While others stay
  removed, macOS may place the returning display near, not at, its saved
  position; Show verifies its mode and main role, the other visible displays
  and the remaining removals instead. Final Show verifies the immutable
  pre-first-Hide arrangement, modes and main display exactly.
  A recovery-needed entry blocks new Hides; entries are never discarded or
  replayed to restore another target.
- In every order, Hide requires another visible desktop to remain. Removed or
  blacked-out displays never count as visible. A removed target cannot be used
  as another target's source; a display serving as a source cannot be removed
  until its dependent removals are shown; and removal onto a removed or
  blacked-out source is refused. Black out applies the same survivor guard.
- Independent displays can still use Black out. A verified PanelCtl source can
  be blacked out only while another visible display remains; its cover also
  covers the corresponding removed desktop on the Mac's input. Displays
  mirrored outside PanelCtl still refuse Black out. Showing a removed target
  leaves its source's manual cover in place; showing the source removes only
  its manual cover and leaves other removals intact.
- Only an explicit person or script action starts Hide. Idle, startup, login,
  wake and reconnection never initiate a new removal or input switch. Re-covering
  a Black out Hide within the same session preserves an existing explicit Hide.
- **Restore** only removes automation blackout/dimming; it never shows a hidden
  display or switches inputs. **Show** acts on the selected hidden display.
- Several removed desktops can survive quitting. **Show and Quit** shows each
  restorable target in turn and quits only after the last Show verifies; a
  blocked or failed entry keeps the app open for recovery instead of reporting
  success.
- External CLI watchers and other display apps are not coordinated; stop them
  before topology work. No automatic logout, reboot or guessed identity is a
  recovery strategy.

**Partial-Show placement:** on the recorded four-display layout, Showing
S2721DGF while AW3425DW remains removed places it at y=0 instead of its saved
y=-4; two hardware trials reproduced this. Such a Show succeeds and returns
the input; the last Show restores the exact original arrangement, which both
trials verified. A third trial qualified the same-order CLI round trip with
input switching; other combinations and app/menu-driven multi-removal remain
unqualified. See [trial evidence](display-multi-removal-trial.md).

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
Every journaled target remains visible as its own tile even when disconnected.
Reconnect that exact hardware, then **Check Again**; PanelCtl does not rebind
recovery to another monitor. If macOS restores one display itself, PanelCtl
resolves only the entry whose topology matches; other entries remain intact.

A healthy removed display has its own recovery details on its selected tile,
not an error banner. Problems appear on the affected tile, or above the tiles if
no target can represent them. **Automations** and **General** show a recovery
banner with **Review…**. The menu offers **Review Display Recovery…**; reopening
the app from Finder focuses the affected recovery tile even when the menu icon
is hidden. Login launch only reports recovery. Custom CLI journals are not
scanned: use `panelctl recovery status --journal <path>` and an explicit
`panelctl recovery restore --display <UUID> --journal <path>` selector; see the
[recovery guide](display-recovery.md).

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
available in the menu and in both **Displays** and **Automations**, even with
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

While any display is removed, normal automation pauses. A bounded source-only
overlay is allowed only when every currently visible journaled mirror source is
selected in Automation or already covered by a manual Hide; an incomplete source
selection does not partially cover the session. Shared sources receive one
overlay, and distinct sources each receive one. Removed targets are never
overlay targets. Manual Hide can independently black out a verified PanelCtl
source when another display remains visible. That session-only Hide owns its
cover instead of Automation; its overlay is stopped while that source is hidden
and cannot show or double-cover it. Showing a source removes only its manual
cover; eligible overlays for remaining sources can resume while other removals
remain.

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

Cmd-comma opens Settings; Cmd-1, Cmd-2 and Cmd-3 select Displays, Automations
and General. The rule switches are labelled with their rule name. In an editor
sheet, Return saves and Escape cancels; Tab/Shift-Tab and arrow keys navigate
native controls according to macOS keyboard navigation settings. There is no
global Hide hotkey. Disabled actions have a visible explanation, not only a
tooltip or color; errors and recovery commands are selectable text. Results stay
on the selected display rather than opening a modal completion dialog.
