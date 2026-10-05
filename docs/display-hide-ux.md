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
Other computer input (on Hide): [Off — use monitor buttons]
Mac input (on Show):          [Off — use monitor buttons]
[Hide…]                                    [enabled only after validation]
```

TASK-18 expands input configuration to independently optional **Other computer
input (on Hide)** and **Mac input (on Show)**, using existing `ddc-input` names
and numeric codes: `dp1`=0x0F, `dp2`=0x10, `hdmi1`=0x11, `hdmi2`=0x12,
or any decimal/`0x` value from 1 through 255. “Off — use monitor buttons” is
the default. These controls appear after opting in for that display. Invalid
text is not persisted and leaves the input off, so hide-only remains available.
Saving/loading performs neither topology writes nor DDC queries/writes. The
explicit **Check DDC availability** action performs only the existing input
read; unknown/unavailable/failed states explain manual switching, and a readable
input is not proof of write support.

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
   mode/HDR limitations, and physical/manual fallback. Explain the approved
   coexistence behavior: when the shared journal and current topology verify
   Hidden by PanelCtl, app protection may cover only the selected mirror source
   with an overlay. The mirrored target is never an overlay target, but it also
   appears black on the Mac input. Brightness dimming and automatic follow-up
   Sleep stay suspended. If the source is not selected, protection is disabled
   or snoozed, or verification is busy/stale/unknown, protection remains paused.
3. Require acknowledgement “I have another usable display and can use the
   monitor buttons or macOS Displays settings if needed.” Default button is
   Cancel; explicit **Hide desktop** authorizes only this operation.
4. Revalidate under the existing operation/journal locks. Capture durably before
   any input/topology write. Hide selects the optional other-computer input
   before topology mirroring; Show restores/verifies topology before optional
   Mac input selection. Publish desktop and input outcomes separately. DDC
   target identity changes are refused without guessing or retrying.
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

Approved coexistence contract (TASK-21): while the shared default journal and
current topology verify **Hidden by PanelCtl**, app protection may install an
opaque desktop overlay on the captured mirror source only, and only when that
exact source is selected for enabled, unsnoozed protection. The mirrored target
is never selected as an overlay target; because it mirrors the source, it also
shows black on the Mac input. This is expected on a handed-off input and visible
black on a plain Hide. Never add the target to a blackout selection to achieve
this effect.

The exception is overlay-only. It makes no topology, DDC input, or brightness
writes and installs no display-awake assertion. Hardware brightness dimming,
empty-display treatment, and automatic follow-up Sleep remain suspended while
the journal is unresolved. A configured Restore/Sleep interval becomes a
Restore-only overlay timeout; **until activity** uses a 24-hour timeout. The
timeout is capped at 24 hours, so persistent blackout retains a finite safety
bound even if the mirror source is the only drawable screen. At timeout the
overlay is removed and the watcher waits for fresh input before a new idle
countdown; it does not Sleep or Show. Existing activity policy may remove the
overlay or reset its timeout. Escape and protection Restore only remove the
overlay; neither invokes Show, changes input, or changes topology.

Show and recovery remain reachable from the menu and Displays settings over an
active overlay. Show stops and verifies overlay cleanup before capturing or
verifying the layout. A cleanup refusal means no Show topology or input action.
The menu/status text distinguishes overlay-only source protection from paused
protection; confirmation states the target-black effect and that DDC/brightness/
topology are not touched by this overlay behavior.

Authorization is not an app/UI boolean: blackout core resolves the current
source identity and re-inspects the shared journal/current topology under the
existing operation and journal locks when resolving targets and again when
revalidating after topology changes. The journal must be the unresolved public
mirror journal in `mirrored` state, the exact target must be observed mirrored
to the exact source, the source must remain separate and identity-matched, and
Show preflight must still be available. A mirrored target, external mirror,
recovery-needed journal, busy lock, or stale/unknown identity/topology refuses
and removes/does not install the overlay. The scoped helper argument never
grants blanket mirror permission; ordinary `panelctl blackout` continues to
refuse mirrored displays. Existing all-screen safety validation is retained;
the finite Restore timeout is the bound, not a global exemption.

This is runtime policy, not a saved preference change or snooze. External CLI
watchers and other display apps are not controlled: instruct users to stop
those before proceeding; advisory locks do not make those combinations safe.
The new coexistence behavior has fake-core and native-fixture validation only.
Hardware qualification is **unperformed**; there has been no live mirrored
blackout, monitor trial, DDC write, or topology write as part of TASK-21.

| Event / action | Contract |
| --- | --- |
| Hide while protection active | Stop/quiesce app treatment and finish brightness cleanup before capture; refuse on cleanup failure. Revalidate afterward. After verified Hide, start the restricted source-only overlay watcher only if the exact source is selected, protection is enabled and not snoozed, and the journal remains healthy. Leave saved preferences unchanged. |
| Idle / empty-display triggers while hidden or recovery unresolved | Only an eligible verified mirror source may receive an overlay. No hardware dimming, empty-display overlay, display-awake assertion, or automatic follow-up Sleep. Unknown/external/busy/recovery state keeps protection paused. |
| Activity / Escape / protection Restore | Activity follows the configured overlay activity policy; Escape and Restore remove only the overlay. None invokes Show or DDC input selection. The hidden desktop remains hidden. |
| Enable/disable protection, snooze/resume | Update existing protection preference/snooze state, not topology. While hidden, enabled/unsnoozed protection may run only the verified source overlay; Show remains available. |
| Blackout Now during hidden/recovery state | Permit only a source-only overlay when the current shared journal/topology verify Hidden by PanelCtl and the exact source is selected. Otherwise refuse actionably. Never black out the target or surviving display. |
| Show succeeds / verified external restoration | Quiesce/verify overlay cleanup before Show capture; release restricted treatment after verified resolution. If enabled and not snoozed, restart normal protection with a fresh idle countdown. Never immediately replay an old empty/idle decision. |
| Hide refused before capture | Restore normal protection according to current preferences, using a fresh countdown; no hidden state. |
| Partial failure after capture | Keep journal and recovery status; only a still-verified healthy Hidden state may use the bounded source overlay. Recovery-needed, busy, or unknown state keeps it off. Do not auto-rollback or repeat DDC. |
| DDC failure after verified Show | Desktop restored, input needs manual attention. Topology journal may already be resolved by backend; do not falsely call it unresolved or replay Show just to retry DDC. Release topology suspension, retain visible input warning. |
| Sleep All Now / system sleep | Existing explicit all-display sleep remains available; does not Show or switch input. No automatic follow-up sleep while hidden. No new hide/show during asleep or transition/unknown state. |
| Wake / hotplug | Refresh and verify; accept system restoration, never re-hide or retry input. Missing/changed identity refuses Show and retains recovery entry. Overlay stops/revalidates through the same transitions. |
| Quit | Stop existing protection as today. If unresolved, warn “Hidden desktop/recovery remains after quitting”; offer Cancel, Show… or Quit Without Showing. No automatic topology or input writes. |
| Crash / force quit | No public-mirror watchdog guarantee. Journal survives; relaunch inspects, offers explicit recovery and never captures over unresolved evidence. Overlay restarts only after fresh journal/topology verification. |
| Launch at login / app relaunch | Existing protection defaults unchanged for no journal; unresolved mirror journal is inspected. Only a verified healthy hidden mirror source may receive the bounded overlay; otherwise protection pauses. No startup hide, Show or input switching. |

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
  hide may still succeed. No retry or inferred input code. App operation notices
  keep **Desktop** and **Monitor input** outcomes distinct.
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
