# Display disable: implementation recommendation and gated plan

Status: recommended to proceed with offline implementation, gated. This is the
canonical direction for future display-disable work; Backlog.md in `backlog/`
tracks execution and dependencies. Historical research is evidence, not a second
implementation plan or permission for a live experiment. Inputs:
[undocumented-display-control.md](undocumented-display-control.md)
(candidate API landscape and qualification gates),
[display-disable-tool-survey.md](display-disable-tool-survey.md)
(surveyed-tool mechanisms, scopes, and failure evidence),
[display-recovery.md](display-recovery.md) and the recovery work on the
`recovery-enable` branch (journal/helper/rehearsal groundwork plus unmerged, gated re-enable work).

## Delivery boundary and source reconciliation

The goal is to release this Mac's DisplayPort signal so a multi-input monitor can
switch to another computer, then restore the Mac's display safely. Start with an
experimental CLI, not automatic blackout policy or app startup disable. The
first supported operation is one explicitly selected non-main external display,
no mirroring, Apple Silicon, with another verified usable physical screen.
Overlay blackout remains the existing safe alternative, not equivalent success.

Main already contains `DisplayRecovery.swift`, `RecoveryJournal.swift`, and
`RecoveryWatchdog.swift`. The unmerged `recovery-enable` branch (inspected at
`418fa33`) adds true-only private re-enable groundwork, identity research,
ICC comparison fixes, and other changes. Its production identity provider remains
blocked. Inspect and reconcile that work before extending it; do not rebuild it
or blindly merge unrelated blackout changes. Its worktree is not owned by the
next agent merely because this document names it.

The newer bounded refusal contract below replaces the requirement to solve
universal offline identity before *offline development*. It does not make cached
metadata fresh or authorize a write to an unproven target. A refusal is valid
safe behavior, but cannot count as successful reconnection or hardware
qualification. If the first target cannot pass identity preflight, live work
stays blocked; report the exact missing evidence rather than weakening checks.
Keep old journals and the strict public restoration path safe.

Routine implementation and tests must use fake writers. Live private calls,
including enable of an already-online display, require separate explicit human
approval. Rehearsal, symbol resolution, ABI evidence, and green tests do not grant
that approval. No DDC power, link-stop/start, permanent writes, blind ID sweeps,
automatic re-disconnect, or automatic escalation to logout/reboot is in scope.

## Recommendation

Build the feature now — a guarded, session-scope soft disconnect using
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

- **Mechanism.** All four surveyed tools disable with the same private setter,
  `CGSConfigureDisplayEnabled` (SkyLight exports `SLSConfigureDisplayEnabled`;
  CoreGraphics re-exports the `CGS` name on this host), inside the public
  begin/complete transaction. Binding style determines the failure mode when
  Apple changes the symbol: static imports break app launch, while `dlsym`
  resolution merely disables the feature. No tool uses link-stop for disable;
  DDC power-off exists only as a separate, caveated action.
- **Scope.** Session (`kCGConfigureForSession = 1`, matching the existing
  recovery groundwork) or app-only; never permanent. No scope undoes the
  private flag when the process dies. `CGRestorePermanentDisplayConfiguration()`
  and logout/reboot are the *expected* global restores but are **unverified for
  the private flag** — the survey records them as trial questions, so the
  design must not depend on them. Permanent scope converts a bad session into
  a bad boot state and is rejected.
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
   explicit "unavailable on this OS" state. TASK-1's
   [local ABI evidence](display-enable-abi.md) establishes the canonical C binding
   on build `26A434`; it is not a guarantee for other builds or live-call approval.
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
  - re-enable all disabled-by-us displays on quit, `SIGTERM`/`SIGINT`, and at
    startup (stranded-disable recovery), driven by the journal; the
    independent helper covers crash and `SIGKILL`;
  - defer disable/re-enable during sleep/wake transitions;
  - defer to the armed auto-revert helper as the independent watchdog;
  - refuse while DisplayLink/virtual-display drivers run; Apple Silicon only
    (surveyed Intel behavior is caveat-laden, and one tool ships arm64 only);
  - accept system-initiated re-enables (e.g. after wake) rather than fighting
    them; re-disconnection stays an explicit user action.
- Panic restore is an explicit, separately warned action: attempt eligible
  disabled-by-us journal entries using the same identity checks, report refusals,
  then offer `CGRestorePermanentDisplayConfiguration()` as an unproven global
  fallback. It must not bypass identity checks or silently run after refusal.
  Gamma is out of scope; no ColorSync reset is needed in the initial feature.
- Nonzero setter returns cancel the uncompleted transaction and surface the
  error; no partial commits. Completion consumes the transaction even on error:
  never cancel after `CGCompleteDisplayConfiguration` has been called.

## Live trial protocol — explicit approval required

The trial is the only way to answer the remaining unknowns. Preconditions: the
target is a non-main external display (e.g. the multi-input DELL), at least
one other physical display verified usable, journal captured and helper armed
with a short deadline, user present.

1. Disable by consent. Observe: call success; monitor loses signal and
   auto-switches to the other computer's input (the feature's actual goal).
   The S2721DGF's framebuffer reports `SupportsSuspend = No` and
   `SupportsActiveOff = No`, so also observe what signal loss actually does
   (standby vs. no-signal message vs. input auto-select) and whether HPD
   stays high while the display is disabled.
2. Re-enable by retained ID while the display is offline. Observe: driver
   acceptance on this host/OS; DP signal returns; monitor returns to the DP
   input or stays parked on HDMI (determines whether a DDC `0x60` input-select
   follow-up is needed).
3. Restore-lever verification, only with separate approval for each disruptive
   step: after a second disable, test
   `CGRestorePermanentDisplayConfiguration()` alone. Test logout and reboot
   separately, recording which was actually observed. Until each is tested,
   treat it as *unproven* in the failure ladder. Never execute these automatically.
4. Failure ladder, honest and in order: journal re-enable → panic restore →
   logout/reboot → physical replug or different port. The survey shows
   same-port replug may stay disabled; the journal must key on more than the
   port, and UI copy must not promise replug as a fix.

## Sequence

1. ABI verification (offline, bounded).
2. Reconcile relevant `recovery-enable` work with main without importing its
   historical blanket research stop as the current development plan.
3. Deliver the bounded identity/refusal policy and exact-ABI transaction backend.
4. Extend the existing journal/helper protocol and physical-display preflight,
   then expose consent-gated disable, journal-driven enable/status, and explicit
   panic recovery. Keep recovery active through the short bounded disable lease;
   indefinite disconnect is not part of the first trial.
5. Complete offline failure/race tests and an independent safety review.
6. Live trial only after its explicit approval and technical gates pass. Record
   negative results as such; do not repeatedly toggle an unexplained failure.
7. DDC `0x60` input-select is a separate, conditional follow-up for reclaiming
   monitor focus after re-enable, not a prerequisite or implicit firmware write.

Use `mise exec -- backlog task list --plain` for current task IDs, dependencies,
and state. Start with TASK-1 (bounded offline ABI verification). TASK-2 reconciles
the existing branch; TASK-3 through TASK-8 deliver and check the offline feature;
TASK-9 is the human-gated trial; TASK-10 is conditional DDC input selection.
Deeper fresh-sink identity research and multi-identical-display support remain
later hardening, not an invitation to resume open-ended research now.

## Open questions only the trial can answer

- Does this host's driver accept re-enable while the display is offline, and
  does the retained ID survive the disable on macOS 27 / M5 Max?
- Does the private flag survive logout or reboot under session scope, and does
  `CGRestorePermanentDisplayConfiguration()` alone re-enable a privately
  disabled display?
- Does the target monitor auto-switch inputs on signal loss, and back on
  signal restore, or does it stay parked on its last input?
- Is any DDC `0x60` follow-up needed, and does the display's DDC channel
  remain addressable while it is disconnected from our topology?
