# Display hide/show interaction contract (TASK-16)

Status: approved by the user in TASK-16 on 2026-10-04. This is an offline
interaction specification, not shipped UI or permission for hardware writes.
TASK-17 may implement this contract using fake/no-write validation. TASK-17 delivers hide/show without input
switching; TASK-18 adds optional inputs; TASK-19 adds explicit app scripting.
Private disconnect remains parked behind TASK-20, TASK-12 and TASK-9.

## Meaning and scope

Use one action pair: **Hide… / Show…**, qualified by display name. No separate
Away/Handoff controls. CLI `away` without an input is exactly mirror hide;
`back` can restore either kind of journal. Reuse those backends and locks.

User-facing explanation:

> Blackout keeps your desktop and covers it; working dimming keeps it usable.
> Hide removes a display’s separate desktop by mirroring another display. The
> Mac still sends a signal and the monitor may show the mirrored picture.
> Resolution, refresh rate and HDR may change. Show restores the saved public
> display layout and modes, not HDR, color profiles, rotation, windows or Spaces.
> Optional input switching needs working DDC; otherwise use the monitor’s input
> button. Hiding does not cause automatic input switching or guarantee OLED
> maintenance, standby or signal loss.

Keep **Experimental · mirror hide** visible in configuration, menu section and
confirmation. Qualification is limited to the observed S2721DGF cycles in
[mirroring](display-mirroring.md) and [handoff](display-handoff.md), not general
monitor/OS support or crash recovery. Do not label a compatible display “tested”.

First slice supports one hidden target at a time using the shared default
recovery journal. Configurations may be saved per display, but an unresolved
journal blocks every new Hide. Target must be an eligible non-main external
screen; source must be explicitly chosen, distinct, online, active and awake.
Reuse backend refusal for existing mirrors, identity ambiguity, stale topology,
missing modes and unresolved recovery. Never pick a source or input implicitly.

## Use-case matrix

| Need | Entry point | Configuration | Visible result | Return / recovery |
| --- | --- | --- | --- | --- |
| OLED blackout / working dimming | Existing protection menu and Automation page | Existing display selection, treatment and timers | Desktop remains; overlay or optional brightness treatment | Existing Restore, activity and timer behavior |
| Temporarily remove an external desktop | Menu Hide… or Displays card Hide… | Target, explicit mirror source, experimental opt-in | Separate desktop removed, signal remains; mirrored picture possible | Show… restores journaled topology |
| Hand monitor to another computer with DDC | Same Hide… | Optional “Other computer input” and “Mac input”, independently optional | Input selection attempted before hide; desktop and input outcomes separate | Show… restores topology before optional Mac input selection |
| Switch manually without DDC | Same Hide… | Inputs left off; no DDC requests | Desktop hidden; user selects other input using monitor buttons | Show… then select Mac input manually |
| Interrupted operation or app relaunch | Menu recovery row or persistent Settings banner | Existing journal, not current settings | Observed state plus retained intent/error; no assumed success | Review Show/recovery, fix refused prerequisite, explicitly retry; keep journal |

## Displays page and menu

Retain Automation / Displays / Startup navigation. On Displays, retain the
existing protection selection under **OLED protection displays**. Add a separate
**Hide a desktop · Experimental** section below it. Protection checkboxes never
configure hide and hidden-state indicators never change those checkboxes.

Annotated card (one per configured or journal-owned display, including absent):

```text
S2721DGF · <stable identity detail>           Desktop: Separate
OLED protection: Selected                  [independent existing selection]
Hide a desktop · Experimental
[ ] Enable experimental hide for this display
Mirror source: [Choose a display…]          [no default selection]
Input switching: Off                       [TASK-18 only]
[Hide…]                                    [enabled only after validation]
```

TASK-18 expands input configuration to independently optional **Other computer
input (on Hide)** and **Mac input (on Show)**, using existing `ddc-input` names
and numeric codes. “Off — use monitor buttons” is the default. Saving/loading
performs neither topology nor DDC writes, nor automatic DDC capability queries.
An explicit **Check DDC availability** action may query; unknown/unavailable/
failed states explain manual switching. Availability is not proof of write
support. Invalid codes block saving that input, not a hide-only configuration.

Show full stable identity in accessible details; names alone are not unique.
Missing displays retain their last name and identity with “Unavailable”, never
rebind to another display. Editing/removing configuration cannot remove journal
recovery. During unresolved recovery freeze operation-related configuration;
show the captured target/source separately from saved preferences.

Menu additions, separated from the existing protection section:

```text
OLED Protection: Enabled
Disable Protection
Blackout Now / Restore                     [existing contextual commands]
Sleep All Now / Snooze…                    [existing semantics]
────────────────────
Hide a desktop · Experimental
Hide S2721DGF…                              [or Configure in Displays…]
────────────────────
Settings…
```

When hidden, replace Hide with **Show S2721DGF…** and a non-action status row
“Desktop hidden · input verified/skipped/unverified/failed” when applicable.
When recovery is needed, show **Review display recovery…** instead. It opens
Displays with the journal card focused; its primary action is **Show…** if the
backend can restore, otherwise an explained disabled action plus Refresh and
recovery details. Do not render an absent journal target only in the active
screen list. Busy replaces the action with “Hiding…” / “Showing…”; no second
submission, toggle, cancel-after-commit or automatic retry.

**Restore remains protection-only.** Tooltip/help: “Removes PanelCtl blackout
or dimming; does not show hidden desktops or switch inputs. Use Show for that.”
No global topology reset, implicit Show-all or private recovery is added.

## First use, repeat use and consent

1. Open Displays, opt in per display, choose source, optionally configure inputs.
   Explain the experimental limitations above. Saving opt-in is not execution
   consent and does not change protection selection or startup behavior.
2. Hide… opens a confirmation on a usable screen. Show target/source names and
   identities, actual journal path, intended input change or “No input change”,
   mode/HDR limitations, and physical/manual fallback. State that protection
   will pause while hidden/recovery is unresolved (see coexistence below), and
   name the consequence plainly: “While hidden, PanelCtl cannot black out
   <source> or any other display. An OLED source stays lit until you Show or
   macOS display sleep turns it off.”
3. Require acknowledgement “I have another usable display and can use the
   monitor buttons or macOS Displays settings if needed.” Default button is
   Cancel; explicit **Hide desktop** authorizes only this operation.
4. Revalidate under the existing operation/journal locks. Capture durably before
   any input/topology write. Publish desktop and input outcomes separately.
5. Show… confirms the **journaled** target and captured layout, optional Mac
   input and the fact that restoring layout may affect other captured screens.
   Default Cancel; **Show desktop** is explicit consent for this return only.

Repeat use has the same scoped confirmation; no “Don’t ask again”. Experimental
opt-in persists, consent does not. Revisit this repeat-use friction, including
the Show acknowledgement, only after more supervised cycles widen qualification;
any lighter model needs its own user-approved contract change. Changed identity/configuration invalidates
any open confirmation. Show/recovery never requires experimental opt-in to
remain enabled or protection to be enabled. Headless app actions in TASK-19
must return confirmation-required unless an explicit request-scoped consent
mechanism meets this same contract; never display a hanging hidden dialog.

## Observed states and reachable recovery

| State | Visible copy | Actions and boundary |
| --- | --- | --- |
| Normal | Separate desktop | Hide… if configured and eligible; otherwise configure/reason |
| Busy | Hiding… / Showing… | Block conflicting UI/CLI submissions with shared locks; report busy |
| Hidden by PanelCtl | Desktop hidden by PanelCtl | Show… from journal, regardless of protection/snooze |
| Disconnected, no journal | Unavailable | Retain configuration; Refresh; no Hide or guessed target |
| Disconnected, journal-owned | Recovery needed — target unavailable | Keep recovery entry; Show disabled with exact refusal; reconnect matching hardware then Refresh; no absent-display reconnect promise |
| Externally mirrored | Mirrored outside PanelCtl | No Hide/Show ownership claim; explain manual macOS Displays correction |
| Unsupported | Cannot hide: <backend reason> | Explain main/built-in target, missing source/identity or other refusal; no private fallback |
| Recovery needed | Recovery needed: <error> | Preserve journal, expose path/status and exact journal-specific recovery command; explicit Show only when checks pass |

State is based on current observations plus journal evidence, never saved
“enabled” configuration alone. A stale/unknown observation is recovery-needed,
not hidden or restored. System restoration is accepted: verify against the
snapshot before resolving the journal; do not mirror again. Partial restoration
or changed identity keeps unresolved evidence and the reason.

Settings has a persistent journal banner above all three pages, linking to the
Displays recovery card. Reopening PanelCtl from Finder/Spotlight already opens
Settings; with unresolved recovery it focuses that card, even when the menu icon
is hidden. Explicit relaunch does the same. Login/background launch inspects and
surfaces status but performs no topology/input write and does not force a modal
confirmation. Menu recovery works with Settings closed. CLI `recovery status`
and the actual-path recovery command remain available independently of the app.

Recognize default-journal `mirror` and `away` operations alike. Do not scan for
arbitrary custom journals or claim to restore them: a CLI custom journal must be
recovered using its recorded path. Private/unknown journal kinds remain visible
as unsupported recovery with CLI guidance, never routed to mirror Show.

## Coexistence and lifecycle

The deliberately conservative first slice pauses app-managed protection while
its shared mirror journal is unresolved, including an app-discovered CLI hide.
Blackout already refuses every display in a mirror set
(`CGDisplayIsInMirrorSet`), including the mirror source, so the source could not
be protected anyway. The cost is real: in the recorded setup the source is the
OLED AW3423DW, which stays unprotected for the whole hide or handoff while the
Mac may sit idle. Overlay-only blackout of a mirror-set source is a separate
gated follow-up (TASK-21), not part of TASK-17.
This is runtime suspension, not a saved preference change or a snooze. It keeps
the survivor usable and avoids overlay/brightness/input/topology races. External
CLI watchers and other display apps are not controlled: instruct users to stop
those before proceeding; advisory locks do not make those combinations safe.

| Event / action | Contract |
| --- | --- |
| Hide while protection active | Stop/quiesce app treatment and finish brightness cleanup before capture; refuse on cleanup failure. Revalidate afterward. Leave saved protection selection/timers unchanged. |
| Idle / empty-display triggers while hidden or recovery unresolved | Suspended app-wide, including hardware dimming and protection follow-up sleep. Display “Protection paused for hidden desktop/recovery”. No empty-display feedback loop. |
| Activity / Escape / protection Restore | Existing overlay cleanup only; never Show or DDC input selection. Cannot silently undo manual hide. |
| Enable/disable protection, snooze/resume | Update existing protection preference/snooze state, not topology. Suspension wins while journal unresolved; Show remains available. |
| Blackout Now during suspension | Refuse actionably: Show/resolve recovery first. No blackout of the surviving screen. |
| Show succeeds / verified external restoration | Release suspension; if enabled and not snoozed, restart normal protection with a fresh idle countdown. Never immediately replay an old empty/idle decision. |
| Hide refused before capture | Restore normal protection according to current preferences, using a fresh countdown; no hidden state. |
| Partial failure after capture | Keep journal and recovery status; protection stays suspended until topology is verified restored. Do not auto-rollback or repeat DDC. |
| DDC failure after verified Show | Desktop restored, input needs manual attention. Topology journal may already be resolved by backend; do not falsely call it unresolved or replay Show just to retry DDC. Release topology suspension, retain visible input warning. |
| Sleep All Now / system sleep | Existing explicit all-display sleep remains available; does not Show or switch input. No new hide/show during asleep or transition/unknown state. |
| Wake / hotplug | Refresh and verify; accept system restoration, never re-hide or retry input. Missing/changed identity refuses Show and retains recovery entry. |
| Quit | Stop existing protection as today. If unresolved, warn “Hidden desktop/recovery remains after quitting”; offer Cancel, Show… or Quit Without Showing. No automatic topology or input writes. |
| Crash / force quit | No public-mirror watchdog guarantee. Journal survives; relaunch inspects, offers explicit recovery and never captures over unresolved evidence. |
| Launch at login / app relaunch | Existing protection defaults unchanged for no journal; unresolved mirror journal suspends treatment and surfaces recovery. No startup hide, Show or input switching. |

Automation adds explanation only: “Idle and empty-display rules control
blackout/dimming, not Hide or monitor inputs.” No hide treatment choice. Startup
adds “Launch does not hide or show desktops. Reopen PanelCtl for display recovery
when the menu icon is hidden.” Do not add unattended hide, wake re-hide, DDC
power, private setters, automatic logout/reboot or global reset.

## Failure presentation

Always show two results when input switching was requested: **Desktop** and
**Monitor input**. With no inputs configured, make no DDC requests at all.

- Away order: capture → optional input selection → topology revalidation → hide.
  Failed DDC write/readback mismatch stops before hide; retain journal/evidence
  and offer explicit recovery. An unverified write can precede successful hide;
  say “Input change unverified — check monitor”, not “Switched”.
- Unavailable DDC/pre-read: explain skipped input and monitor-button fallback;
  hide may still succeed. No retry or inferred input code.
- Input changed, then hide failed: report the partial outcome, preserve the exact
  input recovery command returned by the backend in visible operation details,
  and offer journal-specific topology recovery. Never claim automatic rollback.
- Show order: restore and verify topology → optional Mac input. Failed/skipped
  DDC cannot prevent topology restoration. On topology refusal do not attempt
  input selection. After a completed Show, repeating it is a reported no-op,
  not another DDC write.
- Input recovery is not persisted in the topology journal. After crash/relaunch
  do not invent the previous input; explain using monitor buttons. Saved Mac
  input is configuration, not evidence of which input was selected.

## Offline walkthrough and accessibility acceptance

These are specification walkthroughs against current backend constraints, not
executed native UI tests or hardware qualification. TASK-17/18 must implement
and verify the native flows with synthetic states before claiming UI acceptance.

| Scenario | Walkthrough and expected endpoint |
| --- | --- |
| Single display | Open Displays → opt-in cannot produce an eligible target/source pair → explained disabled Hide; protection remains unchanged; no write. |
| Multiple displays | Choose non-main external target and explicit source → confirm → protection quiesces → shared journal capture → hide → Show confirmation → captured topology verification → fresh protection countdown. Only one hide journal at a time. |
| Target absent | Relaunch with unresolved journal and icon hidden → open app → focused recovery card retains target identity → Show refuses with reason → reconnect exact target, Refresh and explicitly confirm; never bind a similarly named screen. |
| No DDC | Leave inputs off → confirmation says no input change → hide makes zero DDC calls → use monitor buttons → Show restores topology, manually select Mac input. |
| Input succeeds, hide fails | Observe desktop error plus input outcome/recovery command → retain journal → explicit checked recovery, no retry loop or false “hidden” state. |
| Show succeeds, DDC fails | Desktop reports restored; input reports failed and manual fallback → repeated Show is no-op; no topology rewrite to retry input. |
| External mirror / changed source | Hide refuses before mutation; show observed external state or exact journal recovery refusal; settings are not recaptured over evidence. |
| Wake restored topology / lost response | Refresh verifies journal snapshot rather than replaying Hide/Show; resolves only on exact backend verification and reports no-op on duplicate completed requests. |

Keyboard/VoiceOver contract: use native menu items, toggles, labelled popups and
buttons in reading order (identity → observed state → configuration → action).
Tab/Shift-Tab traverses enabled controls; Space activates toggles/buttons; arrow
keys navigate menu/source/input choices. Cmd-comma opens Settings; Escape
cancels the confirmation without writing. No global Hide hotkey. Cancel is the
safe default; destructive topology confirmation must not run just from opening
or dismissing a sheet. On completion return focus to the invoking action; on
error focus the recovery summary, never an absent screen.

VoiceOver labels include action and unique target, source choices expose name
and identity, state changes announce busy/result without repeated chatter, and
errors are selectable text with keyboard-accessible recovery details. Disabled
actions have adjacent readable explanations, not hover-only tooltips or color
alone. Long names, UUIDs and errors wrap without hiding primary recovery actions.
Native fixture checks must include menu navigation, hidden icon/reopen, absent
target card, confirmations, progress and both partial-failure results.

## Review / approval record

Backend anchors: `SettingsView.swift` (existing navigation/selection),
`AppDelegate.swift` (Restore, menu, reopen, quit), `AppModel.swift` and
`ProtectionService.swift` (managed watcher), `DisplayHandoff.swift` and
`DisplayMirroring.swift` (ordering, locks and journal restoration), plus the
linked mirroring/handoff evidence. Paths are under `Sources/PanelCtlApp/` or
`Sources/PanelCtlCore/` respectively.

TASK-16 records the offline review and user decision. The user selected
“Approve contract” after reviewing the key decisions: one Hide/Show pair,
per-operation confirmation, protection-only Restore and runtime protection
suspension during hide/recovery. Approval accepts this interaction design only,
not a live operation or new hardware qualification.

Amendment, 2026-10-04 (user-approved): the Hide confirmation must name the loss
of blackout on the OLED source while hidden; the coexistence section records the
existing mirror-set refusal and TASK-21 follow-up; per-operation confirmation is
kept and revisited only after wider qualification. Decisions are unchanged.
