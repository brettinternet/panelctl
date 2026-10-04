# Display disable: implementation recommendation and gated plan

Status: recommended to proceed, gated. This records the decision, the remaining
gaps, the implementation contract, and the live-trial protocol. Inputs:
[undocumented-display-control.md](undocumented-display-control.md)
(candidate API landscape and qualification gates),
[display-disable-tool-survey.md](display-disable-tool-survey.md)
(surveyed-tool mechanisms, scopes, and failure evidence),
[display-recovery.md](display-recovery.md) and the recovery work on the
`recovery-enable` branch (journal/helper/rehearsal groundwork).

## Recommendation

Build the feature now — a guarded, app-only-scope soft disconnect using
`CGSConfigureDisplayEnabled` inside a `CGBegin/CompleteDisplayConfiguration`
transaction — with re-enable strictly by retained display ID. Two bounded gaps
are closed offline before the feature is complete. One set of questions
(driver acceptance of re-enable while a display is offline on this host, and
the monitor's input-switch behavior) can only be answered by a supervised live
trial, which requires explicit human approval first.

The mechanism, the scope decision, the guard set, and the recovery tooling are
sufficiently established. What is missing does not justify further research
before implementation; it is embedded as gates in the build itself.

## Established — no longer open

- **Mechanism.** Three surveyed tools converge on the same private call and
  transaction shape; two independent public implementations agree on the ABI
  `(configRef, displayID, bool) -> CGError`. No surveyed tool uses link-stop,
  DDC power, or power-mode APIs for disable.
- **Scope.** App-only (`kCGConfigureForAppOnly = 0`), never permanent. The
  disable is login-session state: it survives process death but reverts at
  logout/reboot, and the public `CGRestorePermanentDisplayConfiguration()` is
  a full-revert panic lever that needs no display IDs. Permanent scope converts
  a bad session into a bad boot state and is rejected.
- **Core re-enable contract.** Re-enable by the retained `CGDirectDisplayID`
  does not require the display to be enumerable. This is the ecosystem's
  proven contract, not the deeper offline-identity contract.
- **Fallback tier.** The existing blackout overlay remains the no-private-API
  fallback; mirror+gamma is optional and not planned.

## Gaps to close offline before the feature is complete

1. **ABI verification on this host.** Cross-tool agreement is evidence, not a
   macOS 27 guarantee. Disassemble the actual SkyLight shared-cache export
   locally (the `xcrun dyld_info`/`ipsw` tooling already used for the identity
   traces) and confirm the argument/return shape. Implement the resolver
   dynamically: CoreGraphics first, SkyLight fallback, fail closed with an
   explicit "unavailable on this OS" state.
2. **Identity refusal contract.** The recovery-identity research concluded
   that no candidate identity source proves fresh-sink identity for offline
   displays. Per the survey, shipped tools do not solve that problem; they
   re-enable by retained ID and refuse when evidence is ambiguous. Adopt that:
   record supplementary identity evidence at capture time (IOKit transport
   state, vendor/product/serial, framebuffer location), and on re-enable either
   confirm the retained ID against that evidence or **refuse and surface the
   display for manual action** — never blind-enable. This converts the
   research blocker into a bounded refusal path; the deep identity work
   remains as later hardening for multi-identical-display setups.

Deliberately *not* required before the first implementation: the full offline
identity contract, permanent-scope anything, and DDC power (excluded).

## Implementation contract

- Journal captured before any mutation (reuse the `recovery-enable` recovery
  tooling: capture/status/verify plus the timed helper; do not duplicate it).
- Explicit-consent flag for disable; no automatic startup behavior.
- Guards, from the surveyed-tool consensus:
  - refuse to disable the last eligible physical display; eligibility
    excludes virtual/headless displays (an online headless virtual display
    does not count);
  - auto-revert if eligibility collapses;
  - re-enable all disabled-by-us displays on quit and at startup
    (stranded-disable recovery), driven by the journal;
  - defer disable/re-enable during sleep/wake transitions;
  - defer to the armed auto-revert helper as the independent watchdog.
- Panic restore command: re-enable everything journaled, then
  `CGRestorePermanentDisplayConfiguration()` (plus
  `CGDisplayRestoreColorSyncSettings()` if gamma is ever in play).
- Nonzero private-call returns cancel the transaction and surface the error;
  no partial commits.

## Live trial protocol — explicit approval required

The trial is the only way to answer the remaining unknowns. Preconditions: the
target is a non-main external display (e.g. the multi-input DELL), at least
one other physical display verified usable, journal captured and helper armed
with a short deadline, user present.

1. Disable by consent. Observe: call success; monitor loses signal and
   auto-switches to the other computer's input (the feature's actual goal).
2. Re-enable by retained ID while the display is offline. Observe: driver
   acceptance on this host/OS; DP signal returns; monitor returns to the DP
   input or stays parked on HDMI (determines whether a DDC `0x60` input-select
   follow-up is needed).
3. Failure ladder, honest and in order: journal re-enable → panic restore →
   logout/reboot → physical replug or different port. The survey shows
   same-port replug may stay disabled; the journal must key on more than the
   port, and UI copy must not promise replug as a fix.

## Sequence

1. ABI verification (offline, bounded).
2. Coordinate with the `recovery-enable` branch: its journal/helper tooling is
   the foundation; build the disable feature on it rather than beside it, and
   reconcile before merge.
3. Implement the contract above behind the consent flag (offline).
4. Live trial (approval gate) and iterate on the observed behavior.
5. DDC `0x60` input-select as a separately qualified follow-up tier for
   reclaiming monitor focus after re-enable.

## Open questions only the trial can answer

- Does this host's driver accept re-enable while the display is offline, and
  does the retained ID survive the disable on macOS 27 / M5 Max?
- Does the target monitor auto-switch inputs on signal loss, and back on
  signal restore, or does it stay parked on its last input?
- Is any DDC `0x60` follow-up needed, and does the display's DDC channel
  remain addressable while it is disconnected from our topology?
