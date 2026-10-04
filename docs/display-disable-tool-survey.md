# Display disable: surveyed-tool mechanisms and safety patterns

Survey of how four existing macOS tools implement per-monitor "disable",
reduced to mechanism facts and safety patterns we can act on. Tools are
deliberately unnamed and referred to by role: an open-source menu-bar utility,
a mode-switching utility, a full display manager, and an adaptive-brightness
app. Sources were public source code, issue trackers, release notes, and
offline static analysis of distributed binaries (imports, strings,
disassembly). No surveyed tool was installed or executed, and no display state
was changed. Vendor help text is reported as a claim, not observed behavior.

This complements [undocumented-display-control.md](undocumented-display-control.md)
(candidate API landscape) and [display-recovery.md](display-recovery.md)
(our recovery groundwork).

## Consensus mechanism

All four tools disable a display with the same private setter,
`CGSConfigureDisplayEnabled(config, displayID, enabled)`, staged inside a public
`CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` transaction.
SkyLight exports it as `SLSConfigureDisplayEnabled`; CoreGraphics re-exports the
`CGS` name, including on this host's macOS 27.0.1.

- Disable passes `false`. Re-enable passes `true` with the CG display ID
  retained from before the disable; the display does not need to be enumerable.
- The display leaves the desktop layout, System Settings, and the public online
  and active display lists, and windows move off it. The monitor normally loses
  signal and enters standby, but one vendor warns that some monitors do not turn
  off or do not stay off.
- To keep seeing disabled displays, two tools import the private display list
  (`CGSGetDisplayList` / `SLSGetDisplayList`). One correlates IOKit port services
  with a cache (below). The open-source utility only remembers them in memory.

Symbol binding differs, and so does the failure mode when Apple changes it:

| Binding | Seen in | If the symbol disappears or changes |
| --- | --- | --- |
| `dlopen` CoreGraphics, `dlsym`, fall back to SkyLight; explicit "unavailable on this macOS" state | Mode-switching utility | Feature disabled; app keeps working |
| Static import of the CoreGraphics `CGS` name | Full display manager | App fails to launch (strong import) |
| Static import of the SkyLight `SLS` name | Adaptive-brightness app | App fails to launch (strong import) |
| `@_silgen_name` Swift declaration | Open-source utility | Same launch failure. It also declares an `Int` return for a 32-bit `CGError` and calls a C function with the Swift calling convention; this works on arm64 by convention, not contract |

The adaptive-brightness app's public source omits its disconnect code, but its
shipped binary imports the `SLS` setter and display list and calls the setter
with `false`/`true` from closures run by its shared transaction helper.

No tool uses `IOAVServiceStopLink`/`StartLink`. One imports
`DisplayServicesSetPowerMode`, with no evidence that it is used for per-display
disable. DDC power-off exists only as a separate, explicitly caveated action
(see fallbacks).

## Commit scope is the core safety decision

`CGCompleteDisplayConfiguration` takes a scope. The tools differ, and their
failure reports and compensations follow from that choice.

| Scope | Used by | Observed or claimed behavior |
| --- | --- | --- |
| App-only (`0`) | Open-source utility (disable, re-enable, mirror fallback); adaptive-brightness app's legacy mirror blackout | After a force-quit, the display stayed disabled and the relaunched app could not list it. Same-port replug did not help; another port did. The maintainer says a restart restores it. |
| Session (`1`) | Mode-switching utility (all 5 commit sites) | Re-enables every display on quit and on `SIGTERM`/`SIGINT`. Crash and `SIGKILL` cannot run these handlers. |
| Permanent (`2`) | Full display manager (all 20 commit sites); adaptive-brightness app's shared helper, which wraps its disconnect | Whether the private flag survives reboot is unverified; the full display manager's help treats restart as a recovery step. It also persists its own disconnect state and offers reconnect-all at startup and quit. |

The SDK header adds two relevant rules. App-termination reverts go back to the
session or permanent configuration, which evidently did not re-enable the
force-quit display above. A permanent change that the macOS UI cannot represent
lasts only for the login session. System Settings has no disable control, which
may explain why a permanent-scope vendor still treats restart as recovery.

Takeaways:

- No scope undoes the private flag when the process dies. Recovery must work
  from another process and after app restart, without relying on hotplug.
- Use session (our recovery groundwork's choice) or app-only; never permanent. A
  temporary feature gains nothing from permanence and risks persisting a bad
  state.
- Logout/reboot is the expected global restore for non-permanent scopes, but
  this is unverified for the private flag.
- The open-source utility's panic reset re-enables every ID it remembers, then
  calls `CGDisplayRestoreColorSyncSettings()` and
  `CGRestorePermanentDisplayConfiguration()`. Whether the last call alone
  re-enables a privately disabled display is unverified.
- Completion invalidates the transaction even on failure. One tool cancels after
  a failed complete; do not copy that.

## Fallback methods

1. **Mirror + zero gamma** (open-source utility's secondary mode). Mirror the
   target to another display (windows migrate), then zero its gamma with
   `CGSetDisplayTransferByTable`, re-applied 5 times at 1-second intervals. The
   display stays enumerated and driven. Its author warns that re-enables are
   nondeterministic: disabling another display can re-enable it. Restore must
   restore gamma, unmirror with `CGConfigureDisplayMirrorOfDisplay(...,
   kCGNullDirectDisplay)`, and restore the cached arrangement.
2. **Mirror + brightness 0** (adaptive-brightness app's legacy mode, still
   offered when disconnect misbehaves), with an enforcer that re-applies it.
3. **Overlay** (our current class). The adaptive-brightness app uses a dark
   overlay for virtual, Sidecar, and AirPlay displays, which support neither
   gamma nor DDC. It is the safest, but the display stays in the layout: no
   standby, no input fallback, and windows do not move.

Gamma has its own stranding risk. The adaptive-brightness app warns that a macOS
gamma bug can leave a screen blank. It detects all-zero tables and reverts to the
last non-zero ones; its manual advice is to change the color profile, log out,
or restart. A gamma blackout therefore needs a journal, startup detection of
zeroed tables, and `CGDisplayRestoreColorSyncSettings()`.

Two tools offer DDC power-off (VCP `0xD6`) as an explicit action with caveats:
it cannot power the monitor back on, a monitor in standby ignores DDC, and the
user must press the power button. This matches the exclusion in
undocumented-display-control.md.

## Identity and recovery architecture

A disabled display leaves public enumeration, so re-enable needs retained
knowledge.

- **Retained ID.** Every tool re-enables by the CG ID captured before disable.
- **Physical presence from IOKit** (mode-switching utility). It reads
  `IOPortTransportStateDisplayPort` services (`ManufacturerName`,
  `HPD_StateDescription`, `TransportDescription`, registry entry ID) to map
  attached-but-disabled displays to cached CG IDs. For displays missing from its
  cache, it assigns a sequential ID, the numeric guessing our identity rules
  forbid. On this host, the class has four services, all with HPD `High`; the
  S2721DGF is `Port-USB-C@3/DisplayPort`. Whether HPD stays high while the
  display is disabled and the monitor is in standby is untested.
- **Intent separate from observation** (full display manager). It records
  app-initiated disconnect intent separately from observed state. It keeps a
  display soft-disconnected only when intent exists and physical presence is
  confirmed (framebuffer identity still at the remembered location). It accepts
  a disconnect without app intent as system state. Unconfirmed presence, or
  identical displays that the remembered location cannot disambiguate, schedule
  a recovery pass instead of a guess. The state persists across app restart.
- **Sleep/wake** (mode-switching utility). It snapshots the desired mode before
  sleep, restores after wake with a fixed attempt budget and delay, falls back
  to internal-only if no external returns, reads lid state from `IOPMrootDomain`
  (`AppleClamshellState`), and defers recovery during transitions.
- **System re-enable.** The full display manager says macOS may reconnect
  displays after wake to ensure GUI access. It offers optional re-disconnect
  after wake, and a disconnect-on-detection mode that it warns can loop. We
  should accept system re-enables rather than fight them.

## Guard rails the tools converged on

- **Never leave zero usable displays.** The full display manager counts only
  eligible displays (virtual displays, including some virtual external-display
  products, do not count) and reconnects all when none remain. The
  mode-switching utility re-enables the built-in display and makes it main when
  no usable external remains. The open-source utility has no guard: a user who
  disabled every display needed VNC, and laptop users who unplug the only
  enabled external with the built-in disabled get a black screen. The
  mode-switching utility's changelog fixes the same black-screen class. "Allow
  disabling all" exists only as a warned override.
- **Built-in display rules.** Refuse built-in-only mode while the lid is closed,
  and skip forced built-in reconnection in clamshell mode. Built-in disconnect
  on some models needs a warned override: certain M3 Macs may not reconnect
  until restart, and iMacs have no cable or lid to force reconnection.
  Auto-disconnecting the built-in on external connect is opt-in and suspended
  after the user manually reconnects it.
- **Escape hatches.** A keyboard kill switch (repeated presses of one modifier
  key) force-reconnects all displays. Holding a modifier at launch enters a safe
  mode that skips auto-apply. CLI and automation intents expose reconnect-all.
- **Non-native displays.** One tool disables the disconnect API while DisplayLink
  runs. Another notes that disconnecting a non-native or virtual display only
  removes it from the layout.
- **Intel.** A vendor states that on Intel Macs soft disconnect does not fully
  sleep the display, and that turning it off or unplugging it while
  disconnected can leave the Mac without a display until restart. The
  mode-switching utility ships arm64 only.
- **UI state.** Disabled displays stay listed with a reconnect control, and
  reconnect uses the retained ID, not the current selection.

## Failure evidence

- A force-quit left a display disabled and unlistable. UI that offers re-enable
  only for enumerable displays is a trap; re-enable must come from a persisted
  journal.
- Hotplug recovery is setup-dependent. One report (USB-C, M1 Max, macOS 15.2)
  found that same-port replug stayed disabled while another port recovered; a
  vendor says power-cycling or replugging the monitor reconnects it. A display
  that returns through another port may get a new ID, so identity checks must
  treat it as new rather than as the journaled display.
- Unplugging the last enabled external with the built-in disabled leaves a black
  screen. Reported recoveries are reconnecting the monitor or a forced restart.
- Every tool's last-resort advice is physical replug, lid close/open, or restart.

## Relevance to the multi-input monitor use case

The motivating case is a monitor fed by this Mac over DisplayPort and by another
computer over HDMI.

- Disabling should remove this Mac's signal so the monitor's input auto-select
  switches to HDMI. This is expected, not observed on the S2721DGF, and one
  vendor warns that some monitors do not turn off. The S2721DGF reports
  `SupportsSuspend = No` and `SupportsActiveOff = No` in its framebuffer
  `DisplayAttributes` (the AW3425DW reports both `Yes`). What those flags mean
  for soft disconnect is unknown.
- Re-enabling restores the signal, but the monitor may stay on HDMI while that
  source is active. Both tools with DDC support ship VCP `0x60` (input select)
  through `IOAVServiceReadI2C`/`WriteI2C` on Apple Silicon. That is a lower-risk
  follow-up after re-enable, and a standalone alternative that never removes the
  display from macOS. DDC reliability limits still apply.
- DDC power-off remains excluded.

## Recommendations

1. Resolve the setter with `dlsym` (CoreGraphics, then SkyLight) into a
   `@convention(c)` pointer with exact C types (`CGError` return,
   `CGDisplayConfigRef`, `CGDirectDisplayID`, C `bool`); fail closed. Cancel on
   setter errors before completion; never cancel after completion.
2. Commit with session (or app-only) scope, never permanent.
3. Persist the journal before disabling: ID, UUID, hardware identity, connector
   and transport, HPD state, geometry, and the disable intent. Re-enable strictly
   by the retained ID. Re-enable on quit and on `SIGTERM`/`SIGINT`; cover crash
   and `SIGKILL` with the independent helper and a startup recovery pass.
4. Allow only one explicitly selected, non-main external display, on Apple
   Silicon. Require another eligible physical display (exclude virtual,
   headless, and DisplayLink displays). Revert if eligibility collapses, defer
   during sleep/wake, refuse while DisplayLink runs, and accept system
   re-enables.
5. Keep the overlay as the fallback tier. Add mirror + gamma only with journaling
   and zeroed-gamma detection, and only if window migration is acceptable.
6. For the multi-input case, consider a DDC `0x60` input select after re-enable
   as a separately qualified, skippable step.

## Open questions

- Does the private flag survive logout or reboot under each scope?
- Does `CGRestorePermanentDisplayConfiguration()` alone re-enable a privately
  disabled display?
- On the S2721DGF, does disabling produce no-signal and HDMI auto-select, does
  HPD stay high, and does input return on re-enable?
- Does DDC still reach a disabled display (needed for the `0x60` follow-up)?
- How do same-port and different-port reconnects behave on this host?
