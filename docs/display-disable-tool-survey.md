# Display disable: surveyed-tool mechanisms and safety patterns

Survey of how existing macOS tools implement per-monitor "disable" features,
distilled into mechanism facts and safety patterns we can act on. Tools are
deliberately unnamed; identification is not needed for the takeaways. Sources
were public source code, public issue trackers, and offline static analysis of
distributed binaries (strings, symbols, disassembly). No surveyed tool was
installed or executed, and no display state was changed during this survey.

This complements [undocumented-display-control.md](undocumented-display-control.md)
(candidate API landscape) and [display-recovery.md](display-recovery.md)
(our recovery groundwork).

## Consensus mechanism

Three of the four surveyed tools converge on the same private call as their
primary disable mechanism:

- `CGSConfigureDisplayEnabled(config, displayID, enabled)` invoked inside a
  `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` transaction.
  Disable passes `enabled = false`; re-enable passes `true` with the same
  retained `CGDirectDisplayID`. The display is removed from the desktop
  topology: it disappears from active-display enumeration and from System
  Settings, and the monitor loses signal (normal standby / input-fallback
  behavior). The re-enable path does **not** require the display to be
  enumerable — it addresses the retained ID directly.
- The call lives in the private SkyLight framework. Two resolution strategies
  were observed: (a) load the symbol from CoreGraphics (which re-exports a
  subset on some OS versions), falling back to SkyLight, and fail closed with
  an explicit "unavailable on this OS" state; (b) link SkyLight directly at
  build time. One open-source implementation binds it at compile time with
  `@_silgen_name` and treats any nonzero return as an error, cancelling the
  transaction.
- One tool (adaptive-brightness app) advertises a "hidden disconnect API" on
  Apple Silicon / macOS 13+ with matching behavior, but its implementation is
  in an encrypted payload with a stripped binary: no disconnect-capable private
  symbol is statically importable or dlsym-referenced. Its exact call is
  unverified; treat its behavior description as marketing-level evidence of
  feasibility, not implementation evidence.

None of the surveyed tools uses `IOAVServiceStopLink`/`StartLink` for disable.
No surveyed tool implements disable via DDC power commands or
`DisplayServicesSetPowerMode` (the latter is used only for display sleep /
brightness-adjacent control, and DDC is used for brightness/contrast/input).

## Commit-scope choice is the core safety decision

`CGCompleteDisplayConfiguration` accepts an option; the surveyed tools differ
conclusively here, and their failure reports show the consequences.

| Scope | Used by | Persistence | Consequence observed |
| --- | --- | --- | --- |
| App-only (`kCGConfigureForAppOnly = 0`) | Open-source menubar utility (disable, re-enable, and mirror fallback) | Survives the owning process's death; reverts at logout/reboot | A force-quit stranded the display as disabled; the app could no longer list it (offline displays vanish from `CGGetActiveDisplayList`), so in-app re-enable was impossible. Unplug/replug on the same port did not fix it; a different port did; reboot fixed it. |
| Session (`kCGConfigureForSession = 1`) | Mode-switching utility (all transactions) | Same as app-only for our purposes; reverts at logout/reboot | Same stranding risk; the tool compensates by re-enabling every display on app quit and at startup. |
| Permanent (`kCGConfigurePermanently = 2`) | Full display manager (every one of its ~20 config-commit sites) | Persists across reboot | Stranded-disconnect states survive restart; the tool compensates with a persistent "soft-disconnected" state and startup recovery that reconnects displays detected as stranded after crash/force-quit. |

Takeaways:

- A non-permanent scope keeps **logout/reboot as a guaranteed global restore**,
  and keeps the public `CGRestorePermanentDisplayConfiguration()` usable as a
  full-revert lever that does not need to know display IDs. The open-source
  utility's panic reset is exactly: re-enable everything it knows, then
  `CGDisplayRestoreColorSyncSettings()` + `CGRestorePermanentDisplayConfiguration()`.
- No scope auto-reverts when the process dies. "Disable" is a login-session-wide
  WindowServer state. Recovery must therefore be designed to work from a
  different process (helper) and after app restart, and must not depend on
  hotplug events: one report shows the same-port replug keeps the display
  disabled while a different port recovers it.
- Avoid permanent scope for our feature. It converts a bad session into a bad
  boot state, and it forfeits the logout/reboot guarantee.

## Fallback methods when the private call is unavailable or unsafe

All surveyed tools have a no-private-API fallback, and none of them is DDC
power:

1. **Mirror + zero-gamma blackout** (open-source utility's secondary mode; the
   brightness app's Intel path also uses it). Switch the target display to
   mirror another display (windows migrate to the mirror target), then set the
   target's gamma table to all zeroes via the public
   `CGGet/SetDisplayTransferByTable`. The display stays enumerated and driven;
   the OS never sees it "off". Known drawbacks, stated by the tool's own author:
   nondeterministic re-enables (toggling a different display can re-enable a
   mirrored-blackout display), and the restore path must undo gamma, unmirror
   (public `CGConfigureDisplayMirrorOfDisplay` with
   `kCGNullDirectDisplay`), and restore the cached arrangement. Gamma blackout
   needs periodic re-application (one tool re-applies 5× at 1s intervals) because
   the system can reset gamma.
2. **Brightness-floor + gamma-zero + mirror** (brightness app on Intel; no
   disconnect API exists there). Adds native brightness 0 and keeps state
   enforced even when the system force-re-enables the display.
3. **Overlay/window blackout** (our current implementation class; also used for
   virtual displays that support neither gamma nor disconnect). Safest, no
   private APIs, but the display stays in the topology: no GPU savings, no
   input-fallback on the monitor, windows do not move.

DDC power (VCP `0xD6`) appears only as an explicit, discouraged option in one
tool's caveats: a monitor powered off over DDC stops accepting DDC commands and
cannot be woken by software. Do not build disable on DDC power. This matches
the exclusion already recorded in undocumented-display-control.md.

## Identity and recovery architecture in the wild

The mode-switching and full-display-manager tools both built substantial
identity machinery around the same core problem — a disabled display leaves
online enumeration, so "re-enable" needs retained knowledge:

- **Retain the pre-disable `CGDirectDisplayID`** and re-enable by that ID.
  Both tools persist a display-ID cache across the disable and across app
  restarts.
- **IOKit offline correlation**: one tool matches
  `IOPortTransportStateDisplayPort` services (reading `ManufacturerName`,
  `HPD_StateDescription`, `TransportDescription`, plus
  `IORegistryEntryGetRegistryEntryID`) to map still-physically-connected-but-
  disabled displays back to cached CG display IDs. It also has a bounded
  fallback ("sequential ID") for unknown displays, which it logs loudly.
- **"Soft-disconnected" state model** (full display manager): disabled displays
  remain in an internal display list with remembered framebuffer identity and
  configuration; the state persists across app restart; a startup pass
  reconnects displays found stranded (explicitly to cover crash/force-quit).
  Ambiguity between multiple offline displays with identical identifiers is
  resolved by remembered framebuffer location; if it cannot be resolved, the
  tool schedules a recovery pass rather than guessing.
- **Sleep/wake handling**: snapshot desired mode before sleep; after wake,
  restore with a bounded retry budget (fixed max attempts + delay), with an
  internal-only fallback if no external display reappears. Lid state is read
  from `IOPMrootDomain` (`AppleClamshellState`) and recovery is deferred during
  sleep/wake transitions.
- **Re-enable on quit** (mode-switcher: "re-enabling all displays") and
  **reconnect stranded displays at startup**.

## Guard rails the surveyed tools converged on

- **Never disable the last usable display.** The mode-switcher auto-enables the
  builtin when no usable external remains; the full display manager defines an
  "eligible display" check that explicitly excludes virtual/headless displays
  (a headless virtual display still counts as online — a real recovery-failure
  class reported in its issue tracker) and auto-reconnects everything when no
  eligible display remains. The open-source utility has no such guard, and a
  user who disabled all monitors had to recover via VNC. An "allow disabling
  all" escape hatch exists in one tool as a deliberate, warned override.
- **Builtin-display special-casing**: emergency re-enable of the builtin
  (and make-it-primary) when externals are unusable; explicit warning that
  disconnecting the builtin on some laptops (base M3 and desktop iMac class)
  may not reconnect until restart; skip builtin disconnect when an external is
  connected (its auto-disconnect feature is opt-in).
- **Kill switch / safe mode**: one tool force-disables its blackout on 8×
  consecutive Command presses; another offers Shift-on-launch safe mode that
  skips auto-apply. Physical-replug and lid-close/open are the documented
  last-resort manual recoveries in their support text.
- **Third-party interaction guards**: the disconnect API is disabled while
  display-link/virtual-display drivers are running; auto-disconnect is
  suspended during transitions.
- **UI state**: disconnected displays stay listed in the UI with a reconnect
  affordance (plus keep-disconnected persistence across standby/wake and lid
  cycles). The toggle is reversible by retained ID, not by selection.

## Failure evidence worth carrying into our gates

- Force-quit/kill -9 leaves the disable in place (login-session state); the
  disabled display is unlistable, so any UI that only offers re-enable for
  enumerable displays is a trap. Re-enable must come from a persisted journal.
- Same-port replug can remain disabled; a different port recovers. Recovery
  must not assume hotplug resets the disabled state, and the persisted journal
  must be keyed on more than the port.
- A past bug disabled *all* displays at once (mode-switcher, fixed) — guard
  against batch operations racing the eligibility check.
- The base-M3-second-monitor caveat: software-disconnecting the builtin does
  not free the internal display coprocessor the way lid-close does, so "free
  GPU resources" claims do not generalize to enabling extra externals.
- Even mature tools tell users, for stuck cases: replug the cable physically,
  or restart the computer. Our restore design should treat those as the honest
  bottom rung of the ladder, below which we should not go.

## Relevance to the multi-input monitor use case

The motivating use case is a monitor fed by two computers (e.g. DisplayPort
from this Mac, HDMI from another machine) that should follow whichever machine
is active:

- A soft disconnect (`enabled = false`) removes this Mac's signal, so the
  monitor's normal no-signal auto-input-search switches it to the other
  computer's input — the desired KVM-like behavior without any monitor-firmware
  power command. Re-enabling restores this Mac's signal.
- The switch back is not guaranteed: depending on the monitor's input-priority
  settings, it may stay parked on the other input. Both commercial-grade tools
  surveyed ship DDC/CI VCP `0x60` (input source select) — via the private
  `IOAVServiceReadI2C`/`WriteI2C` on Apple Silicon — as a complement to force
  the input back. That is a useful, lower-risk follow-up command after
  re-enabling (and possibly after disabling), and it is also a complete
  standalone alternative path for input switching that never removes the
  display from macOS. DDC I2C is already in-scope research (see
  undocumented-display-control.md), but its own reliability limits (adapter/
  hub flakiness, monitor DDC firmware bugs) apply.
- DDC power off remains excluded: a monitor powered off via DDC cannot be
  re-woken via DDC, and physical-control failure reports exist.

## Recommendations for our implementation

1. Use `CGSConfigureDisplayEnabled` in a begin/complete transaction as the
   first candidate, exactly as already proposed in
   undocumented-display-control.md; resolve the symbol dynamically
   (CoreGraphics → SkyLight), fail closed, and treat nonzero returns as
   transaction-cancel errors.
2. Commit with app-only (or session) scope — never permanent. Rely on
   logout/reboot as the global guarantee; expose `CGRestorePermanentDisplay
   Configuration()` (plus `CGDisplayRestoreColorSyncSettings()` if we ever
   touch gamma) as the explicit panic restore.
3. Because the state outlives our process: persist the pre-disable journal
   (ID, UUID, identity evidence, geometry) *before* the disable, keep it across
   restarts, and re-enable strictly by retained ID. A separate watchdog/helper
   and a startup stranded-disable recovery pass are both proven-in-the-wild
   patterns; our existing recovery journal design fits this directly.
4. Guard rails first: refuse to disable the last eligible physical display
   (exclude virtual/headless displays from eligibility, not just "online"
   counting); auto-revert if eligibility collapses; defer during sleep/wake
   transitions; re-enable all on quit and at startup.
5. Keep the existing blackout overlay as the fallback tier (it is the safest of
   the surveyed methods and already implemented), with mirror+gamma as an
   optional middle tier only if window-migration behavior is acceptable.
6. After a successful re-enable in the multi-input scenario, consider a DDC
   input-source select (`0x60`) follow-up to reclaim monitor focus, as a
   separately qualified, separately skippable step.

## Open questions

- The encrypted-implementation tool's exact disconnect call is unidentified;
  its observable behavior (display leaves System Settings, Apple Silicon +
  macOS 13+ only) is consistent with the consensus mechanism but unverified.
- Whether app-only vs session scope differs observably at all on current OS
  versions (the empirical failure evidence above came from app-only; the
  mode-switcher uses session, with the same compensating behavior).
- Whether a disabled display's DDC channel stays functional from this Mac
  (relevant for the `0x60` follow-up): surveys suggest the monitor's OSD is
  still responsive to its physical buttons on other inputs, but DDC addressing
  of a display removed from our topology is untested.
