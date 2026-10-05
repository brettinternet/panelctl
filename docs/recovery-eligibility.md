# Physical eligibility and lifecycle preflight (TASK-6)

Offline policy and fake-writer coverage only; no private setter, public display
restoration, DDC write or live helper was run. TASK-12 adds read-only
CoreGraphics/IOKit identity, screen and lifecycle observations under the
[bounded identity contract](recovery-identity-policy.md). A UUID, online count,
`builtin=false`, HPD alone or cached CoreDisplay metadata does **not** prove
physical usability. The current native-only driver inventory remains unknown,
so private selection still refuses. TASK-9 requires separate scoped human
approval; tests do not qualify hardware.

## Selection and transaction checks

`RecoveryEligibilityPolicy` combines the existing `RecoveryIdentityPolicy` with
fresh `RecoveryEligibilityEnvironment` observations. It requires Apple Silicon,
known native-only driver state, known non-mirrored topology, one retained non-main
external physical target, and another active, awake physical screen with a usable
mode. Virtual, headless and DisplayLink screens cannot be survivors. A built-in
screen with a closed or unknown lid cannot count. Unknown classification anywhere
refuses selection. Missing/inconsistent observations refuse rather than inheriting
old evidence. The decision returns diagnostics and the usable survivor IDs.

The environment is process-local, not Codable and not journal authority.
TASK-12's production provider labels an external screen `physical` only with one
matching IOKit transport reporting high HPD and active state; built-in screens
use the CG builtin observation, and unknown transport/mode states refuse. It
recognizes known disallowed drivers, but does not infer `.nativeOnly` from the
absence of their names: without a complete allowlist the live driver state is
`.unknown` and private selection refuses. `DisplayInventory.records()` alone is
insufficient. Do not serialize synthetic provider authority into a journal or
expose a bypass.

`RecoveryEligibilitySelection` captures the eligible snapshot, environment and
lifecycle revision. Its `validate` method belongs in the existing
`RecoveryDisable.preflight` closure. Each call must use fresh snapshot, identity,
physical/driver/lid observations and monotonic time. The existing disable path
calls it before intent persistence, before begin, before setter, and before
completion. Snapshot/eligibility changes or a notification revision invalidate
selection, even if topology changed away and back. The helper must cancel an
uncompleted transaction rather than refresh selection automatically. A new
selection requires a new explicit user action.

## Lifecycle contract for TASK-7

`RecoveryLifecycle` follows Blackout's matching-suspension approach but has no
connection to blackout automation. It is a pure state machine: no action can
request a disable. Runtime wiring must:

1. Establish current console/system and every online screen's awake state with
   fresh observations before constructing `initiallyAwake: true`. Awake state is
   separate from active/physical eligibility: an inactive but awake mirror
   destination does not mean the system is asleep. The default is unknown/refused;
   a wake notification cannot authorize an initially unknown state.
2. Deliver workspace system sleep/wake, screens sleep/wake, session active/inactive,
   and application screen-parameter notifications through `event(for:)` and
   `receive`. Also send `topologyChanged` for lower-level CG reconfiguration or
   eligibility changes. Serialize delivery, observations and transaction checks;
   do not rely on queued main-run-loop notifications alone during a synchronous
   transaction. Refresh current state at every boundary to cover delayed events.
3. Gate **both disable and recovery writers**, including public restoration,
   with `writeGate`. Suspension reasons clear only on matching resumes. While
   `writeGate` is deferred, return defer before sampling awake state; retain the
   prior readiness until matching resume, then refresh after settling. Writes
   defer until one second after the last transition event with no outstanding
   suspension. Each transition has a fixed five-second budget; repeated events
   cannot extend it. At exhaustion, preserve the journal and report attention,
   never force a write through sleep or reset the controller to bypass refusal.
   Timers must use monotonic time and cannot promise execution while macOS sleeps.
4. After durable disable staging/commit evidence, call `didDisable` for the
   journaled target. On startup, reconstruct only from qualifying unresolved
   journal evidence (same rules as `RecoveryEngine`), not from disappearance.
   During the bounded lease, feed fresh baseline/current/identity/environment
   observations to `observe`, including after notification delivery and settle
   timers. An observation/collection error must revoke disable authority and
   request the same guarded recovery/attention path, not be ignored.
5. Route `requestGuardedRecovery` to the existing journal-driven engine under
   its existing locks and identity checks. This is a **request**, not permission
   to bypass strict identity or remaining-topology checks. In particular loss
   of an additional screen may make recovery refuse; retain the journal and
   surface manual attention instead of guessing. No second disable is issued.
6. A reappeared target with ambiguous identity, unusable state or unqualified
   global/peer observations requests guarded recovery without retiring intent.
   On `reconcileSystemReenable`, local intent is retired immediately and cannot
   be replayed. Reconcile durable intent through `RecoveryEngine.finish` with
   `verifyOnly: true` so accepting a system re-enable cannot fight system layout
   changes. Successful full-baseline verification closes private authority;
   nonconvergence retains `needsAttention` and the original evidence. Never
   clear/delete a journal merely because the ID reappeared. The controller's
   consumed-disable latch remains set even if the display later disappears.
7. Integrate with the helper's existing lease, signal/EOF/deadline and one-shot
   writer rules. A deferral must not extend the disable lease or replay a setter;
   a failed/expired recovery stays unresolved. TASK-6 does not change the helper's
   existing public recovery behavior; these integration steps are TASK-7 work.

## TASK-7 runtime integration

`RecoveryPrivateSession` now connects this policy to the existing helper: serialized
workspace/application notifications, fresh selection checks, periodic lease
observations, bounded sleep deferral, guarded survivor-loss recovery and verify-only
system-reenable reconciliation. Recovery writers also consult the lifecycle gate.
The CLI exposes consent/timeout/selector parsing and journal-only enable/panic;
see [display recovery](display-recovery.md).

TASK-12 now obtains initial awake/lid/console observations read-only from
IOPMrootDomain, the current console session and CoreGraphics online-screen asleep
state; awake readiness does not require every screen's `active` flag (inactive
mirror destinations are handled separately by configuration/eligibility policy).
Missing state stays unknown/refused; notifications cannot upgrade it. During a
bounded suspend, lifecycle checks defer without sampling until matching resume
and settling. The runtime synchronously refreshes lifecycle plus applicable
identity and environment at disable, private enable and public-restoration writer
boundaries; public restoration requires every online screen to be freshly awake,
but does not inherit private physical/driver/active restrictions.
Production driver inventory remains unknown, and cached metadata does not prove
fresh sink acquisition or detect every same-port replacement/ID-reuse case.
Synthetic evidence still authorizes only fake-writer tests.

## TASK-12 no-write provider rehearsal

On the current host (`Mac17,14`, arm64, build `26A434`), the read-only rehearsal
reported lifecycle awake `true`, lid `unknown`, and identity `eligible` with a
complete capture/current match. IOKit/CG reported DELL S2721DGF (ID 1,
`Port-USB-C@3/DisplayPort` transport location), K272HUL (ID 3,
`Port-USB-C@1/DisplayPort`), and AW3425DW (ID 2,
`Port-HDMI@1/DisplayPort`) as online, active external physical candidates with
usable modes, High HPD and active IOKit transport. Dell AW3423DW (ID 5,
`Port-USB-C@2/DisplayPort`) was an online, active, High-HPD physical survivor
candidate. These are separate IOKit transport locations; persisted connector
semantics remain CoreDisplay `IODisplayLocation` (id 1 was observed at an
`IOService:/.../IOMobileFramebufferShim` location). No target was selected. Every candidate was refused with
`DisplayLink, virtual or unknown driver state` because the IOKit service scan
does not constitute a complete native-only allowlist. No writer was constructed
and no display configuration changed. These are observations, not
hardware-write qualification.

## Offline verification

`swift test --disable-sandbox --filter RecoveryEligibilityTests` covers positive
and negative physical/identity fixtures, driver/architecture/mirror/lid guards,
selection invalidation and cancellation at actual `RecoveryDisable` transaction
boundaries with fake setters, matching notification resumes, bounded transition
budgets, survivor loss and system-reenable intent retirement. No test in this
class queries or changes real displays.

Fresh validation on 2026-10-04:

- The focused filter passed all seven tests, including regression cases for
  unsafe/ambiguous target reappearance preserving intent and requesting recovery.
- `swift test --disable-sandbox` reproduced the three existing compositor-bounds
  assertion failures in
  `BlackoutGeometryTests.testWindowPlacementOnConnectedExternalScreens` (also
  recorded by TASK-5). No other test failed.
- After the review corrections,
  `swift test --disable-sandbox --skip BlackoutGeometryTests.testWindowPlacementOnConnectedExternalScreens`
  passed; the opt-in live symbol-resolution test remained skipped.
- `swift build --product panelctl`, `swift build --product PanelCtlApp`,
  `scripts/test-release-version.sh` and `git diff --check` passed.
- Language-server reports were mixed clean/unknown; compiler and test results,
  not absent diagnostics, supply verification.
- One independent read-only safety review found the two reappearance defects
  above. Both were corrected and regression-tested. The initial Claude CLI
  review could not authenticate and a Pi/Anthropic attempt timed out; the
  completed review used Pi/OpenRouter GPT-5.4. No second general review was run.

Residual limits: notification delivery and hardware mutation are not atomic;
other processes can change topology after the final check. The helper cannot
survive its own SIGKILL, guarantee timers during sleep, or qualify offline sink
identity. Policy readiness is not consent, journal ownership, lease liveness,
driver acceptance, monitor signal loss or successful restoration.
